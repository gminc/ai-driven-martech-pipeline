import re

import pytest

import catalog
import ecpay
import main


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("GA_MEASUREMENT_ID", "G-TEST1234")
    monkeypatch.delenv("PAYMENT_MODE", raising=False)
    return main.create_app().test_client()


def signed(params):
    return dict(params, CheckMacValue=ecpay.check_mac_value(params, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV))


def test_catalog_loads_and_quantity_is_clamped():
    shop = catalog.load_catalog()
    assert len(shop.products) == 5 and shop.currency == "TWD"
    assert len(shop.campaigns) == 2 and len(shop.pillars) == 3
    assert shop.campaign("autumn-cotton") is not None and shop.campaign("nope") is None
    assert len(shop.related(shop.get("sock-crew-daily"))) == 3
    assert catalog.parse_quantity("3") == 3
    for bad in [None, "", "0", "6", "-1", "abc", "2.5"]:
        assert catalog.parse_quantity(bad) == 1


def test_index_renders_products_and_gtag(client):
    html = client.get("/").get_data(as_text=True)
    assert "日常中筒襪" in html and "純棉大浴巾" in html
    assert "googletagmanager.com/gtag/js?id=G-TEST1234" in html
    assert "測試環境" in html
    assert 'class="hero-banner"' in html  # 首頁是全幅 banner，品牌敘述留在關於頁
    assert "原質溯源" not in html
    assert 'data-list-id="home_all"' in html


def test_product_page_has_view_item_payload_and_specs(client):
    html = client.get("/product/towel-face-cotton").get_data(as_text=True)
    assert "無撚紗" in html and "34 × 76 cm" in html
    assert '"item_id": "towel-face-cotton"' in html
    assert 'data-list-id="related_towel-face-cotton"' in html
    assert client.get("/product/nope").status_code == 404


def test_landing_page_carries_promotion(client):
    html = client.get("/lp/autumn-cotton").get_data(as_text=True)
    assert '"promotion_id": "AUTUMN2026"' in html and "秋日棉織專案" in html
    assert client.get("/lp/nope").status_code == 404


def test_about_page_and_404_template(client):
    assert "慢速織造" in client.get("/about").get_data(as_text=True)
    assert "找不到這個頁面" in client.get("/nope").get_data(as_text=True)


def test_invalid_ga_id_disables_gtag(monkeypatch):
    monkeypatch.setenv("GA_MEASUREMENT_ID", "');alert(1);//")
    html = main.create_app().test_client().get("/").get_data(as_text=True)
    assert "googletagmanager" not in html and "alert(1)" not in html


def test_checkout_builds_signed_form_with_server_side_amount(client):
    html = client.get("/checkout/towel-bath-cotton?qty=2&cid=123.456&src=google%7Ccpc%7Cautumn",
                      base_url="https://demo.example").get_data(as_text=True)
    fields = dict(re.findall(r'name="([A-Za-z0-9]+)" value="([^"]*)"', html))
    assert ecpay.STAGE_ACTION_URL in html
    assert fields["TotalAmount"] == "1380"
    assert fields["CustomField1"] == "towel-bath-cotton" and fields["CustomField3"] == "123.456"
    assert fields["CustomField4"] == "google|cpc|autumn"
    assert fields["ReturnURL"] == "https://demo.example/ecpay/return"
    assert ecpay.verify_check_mac_value(fields, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV)


def test_checkout_rejects_unknown_product_and_bad_cid(client):
    assert client.get("/checkout/nope").status_code == 404
    html = client.get("/checkout/sock-crew-daily?qty=99&cid=<script>&src=<script>").get_data(as_text=True)
    fields = dict(re.findall(r'name="([A-Za-z0-9]+)" value="([^"]*)"', html))
    assert fields["TotalAmount"] == "180" and fields["CustomField3"] == ""
    assert fields["CustomField4"] == ""


def test_return_url_acknowledges_only_valid_signature(client):
    payload = signed({"MerchantID": "3002607", "MerchantTradeNo": "DM1", "RtnCode": "1", "RtnMsg": "Succeeded",
                      "TradeAmt": "180", "CustomField1": "sock-crew-daily", "CustomField2": "1"})
    ok = client.post("/ecpay/return", data=payload)
    assert ok.status_code == 200 and ok.get_data(as_text=True) == "1|OK"
    bad = client.post("/ecpay/return", data=dict(payload, TradeAmt="1"))
    assert bad.status_code == 400 and bad.get_data(as_text=True) != "1|OK"


def test_result_page_fires_purchase_only_when_verified_and_paid(client):
    trade_no = ecpay.new_merchant_trade_no()
    base = {"MerchantID": "3002607", "MerchantTradeNo": trade_no, "RtnMsg": "Succeeded",
            "TradeAmt": "520", "CustomField1": "sock-towel-training", "CustomField2": "2", "CustomField3": ""}
    html = client.post("/ecpay/result", data=signed(dict(base, RtnCode="1"))).get_data(as_text=True)
    assert 'id="purchase-data"' in html and trade_no in html
    failed = client.post("/ecpay/result", data=signed(dict(base, RtnCode="10100058"))).get_data(as_text=True)
    assert 'id="purchase-data"' not in failed
    forged = client.post("/ecpay/result", data=dict(base, RtnCode="1", CheckMacValue="0" * 64)).get_data(as_text=True)
    assert 'id="purchase-data"' not in forged
    # 就算用公開金鑰自己算出正確簽章，金額或訂單編號不合理也不送 purchase
    wrong_amount = client.post("/ecpay/result", data=signed(dict(base, RtnCode="1", TradeAmt="1"))).get_data(as_text=True)
    assert 'id="purchase-data"' not in wrong_amount
    old_trade = client.post("/ecpay/result", data=signed(dict(base, RtnCode="1", MerchantTradeNo="DM20200101000000ABCD"))).get_data(as_text=True)
    assert 'id="purchase-data"' not in old_trade


def test_proxy_fix_ignores_forwarded_host(client):
    html = client.get("/checkout/sock-crew-daily", base_url="https://demo.example",
                      headers={"X-Forwarded-Host": "evil.example", "X-Forwarded-Proto": "https"}).get_data(as_text=True)
    assert "evil.example" not in html and "https://demo.example/ecpay/return" in html


def test_simulate_mode_skips_ecpay(monkeypatch):
    monkeypatch.setenv("PAYMENT_MODE", "simulate")
    html = main.create_app().test_client().get("/checkout/set-starter?qty=1").get_data(as_text=True)
    assert "模擬結帳" in html and 'id="purchase-data"' in html and ecpay.STAGE_ACTION_URL not in html


def test_health(client):
    assert client.get("/health").get_json() == {"status": "ok"}
