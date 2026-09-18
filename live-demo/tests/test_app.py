import json
import re
from pathlib import Path

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


def test_every_product_has_sizes_and_resolve_falls_back():
    shop = catalog.load_catalog()
    for product in shop.products:
        assert product.size_options, product.id
        assert len(product.size_options) == len(set(product.size_options))
    socks = shop.get("sock-crew-daily")
    assert socks.resolve_size("L 26-28 cm") == "L 26-28 cm"
    assert socks.resolve_size("  L 26-28 cm  ") == "L 26-28 cm"  # 前後空白會先 strip
    for bad in [None, "", "   ", "XXL", "l 26-28 cm", "標準 34x76 cm", "L 26-28 cm|M 24-26 cm"]:
        assert socks.resolve_size(bad) == socks.size_options[0]


def test_referenced_images_exist_on_disk():
    """products.json 換成實拍圖後，避免任何一條路徑指到已刪掉的 SVG。"""
    shop = catalog.load_catalog()
    static_dir = Path(__file__).resolve().parents[1] / "static"
    paths = set()
    for product in shop.products:
        paths.add(product.image)
        paths.update(product.gallery)
    for campaign in shop.campaigns:
        paths.add(campaign.hero_image)
    # 樣板與 CSS 裡手寫的路徑（banner、織機照、logo）也要一起檢查
    root = static_dir.parent
    sources = list((root / "templates").glob("*.html")) + [static_dir / "styles.css"]
    for source in sources:
        paths.update(re.findall(r"img/[A-Za-z0-9_.-]+\.(?:jpg|jpeg|png|webp|svg)", source.read_text(encoding="utf-8")))
    missing = sorted(p for p in paths if not (static_dir / p).is_file())
    assert not missing, f"缺少圖片：{missing}"
    # 商品圖已全面換成 JPEG，只剩品牌 logo 還是 SVG
    assert {p for p in paths if p.endswith(".svg")} == {"img/logo.svg"}
    assert len(paths) >= 14


def test_index_renders_products_and_gtag(client):
    html = client.get("/").get_data(as_text=True)
    assert "日常中筒襪" in html and "純棉大浴巾" in html
    assert "googletagmanager.com/gtag/js?id=G-TEST1234" in html
    assert "測試環境" in html
    assert 'class="hero-banner"' in html  # 首頁是全幅 banner，品牌敘述留在關於頁
    assert "原質溯源" not in html
    # 主標固定兩行、不帶標點
    assert '<span class="line">擦拭時的純淨蓬鬆</span><span class="line">行走時的溫柔包覆</span>' in html
    assert "擦拭時的純淨蓬鬆，" not in html
    assert 'data-list-id="home_all"' in html


def test_product_page_has_view_item_payload_and_specs(client):
    html = client.get("/product/towel-face-cotton").get_data(as_text=True)
    assert "無撚紗" in html and "34 × 76 cm" in html
    assert '"item_id": "towel-face-cotton"' in html
    assert 'data-list-id="related_towel-face-cotton"' in html
    # 尺寸是可勾選的 radio，預設選第一個
    assert html.count('name="size"') == 2
    assert 'value="標準 34x76 cm" checked' in html
    item = json.loads(re.search(r"data-item='([^']+)'", html).group(1))
    assert item["item_variant"] == "標準 34x76 cm"  # GA4 item_variant 預設帶第一個尺寸
    assert "color-chip" not in html
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
    assert fields["CustomField2"] == "2|0"  # 沒帶 size 時退回預設尺寸（索引 0）
    assert fields["CustomField4"] == "google|cpc|autumn"
    assert fields["ReturnURL"] == "https://demo.example/ecpay/return"
    assert ecpay.verify_check_mac_value(fields, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV)


def test_checkout_rejects_unknown_product_and_bad_cid(client):
    assert client.get("/checkout/nope").status_code == 404
    html = client.get("/checkout/sock-crew-daily?qty=99&cid=<script>&src=<script>").get_data(as_text=True)
    fields = dict(re.findall(r'name="([A-Za-z0-9]+)" value="([^"]*)"', html))
    assert fields["TotalAmount"] == "180" and fields["CustomField3"] == ""
    assert fields["CustomField4"] == ""


def test_checkout_accepts_only_catalog_sizes(client):
    def custom_field2(query):
        html = client.get(f"/checkout/sock-crew-daily?{query}").get_data(as_text=True)
        return dict(re.findall(r'name="([A-Za-z0-9]+)" value="([^"]*)"', html))["CustomField2"]

    assert custom_field2("qty=1&size=L%2026-28%20cm") == "1|2"
    assert custom_field2("qty=1&size=M%2024-26%20cm") == "1|1"
    # 不在目錄內的尺寸一律退回預設值，不讓前端塞任意字串進綠界欄位
    assert custom_field2("qty=1&size=%E8%87%AA%E5%B7%B1%E5%AF%AB%E7%9A%84") == "1|0"
    assert custom_field2("qty=1&size=%E6%A8%99%E6%BA%96%2034x76%20cm") == "1|0"  # 別的商品的尺寸也不行
    # 自訂欄位只會出現 ASCII 數字與分隔符，不受金流端字串正規化影響
    for query in ["qty=1", "qty=5&size=L%2026-28%20cm", "qty=2&size=%7C%7C%7C"]:
        assert re.fullmatch(r"\d\|\d+", custom_field2(query))


def test_split_qty_size_handles_broken_custom_field():
    assert main.split_qty_size("2|1") == (2, "1")
    assert main.split_qty_size("3") == (3, "")
    assert main.split_qty_size(None) == (1, "")
    assert main.split_qty_size("99|2") == (1, "2")


def test_size_by_index_never_guesses_a_default():
    """回呼還原不出尺寸時必須留空，不能拿預設尺寸冒充客人買到的東西。"""
    socks = catalog.load_catalog().get("sock-crew-daily")
    assert socks.size_by_index("0") == "S 22-24 cm"
    assert socks.size_by_index("2") == "L 26-28 cm"
    for bad in ["", None, "3", "99", "-1", "0.0", "abc", "L 26-28 cm", " "]:
        assert socks.size_by_index(bad) == ""
    assert socks.size_index("L 26-28 cm") == 2 and socks.size_index("亂寫") == 0


def test_result_page_omits_variant_when_size_cannot_be_restored(client):
    """索引壞掉時感謝頁不顯示尺寸，purchase 事件也不帶 item_variant。"""
    trade_no = ecpay.new_merchant_trade_no()
    base = {"MerchantID": "3002607", "MerchantTradeNo": trade_no, "RtnMsg": "Succeeded", "RtnCode": "1",
            "TradeAmt": "260", "CustomField1": "sock-towel-training", "CustomField2": "1|GARBAGE"}
    html = client.post("/ecpay/result", data=signed(base)).get_data(as_text=True)
    payload = json.loads(re.search(r'id="purchase-data"[^>]*>(.*?)</script>', html, re.S).group(1))
    assert "item_variant" not in payload["items"][0]
    assert "M 24-26 cm" not in html and "厚底毛巾訓練襪 ×" in html


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
            "TradeAmt": "520", "CustomField1": "sock-towel-training",
            "CustomField2": "2|1", "CustomField3": ""}
    html = client.post("/ecpay/result", data=signed(dict(base, RtnCode="1"))).get_data(as_text=True)
    assert 'id="purchase-data"' in html and trade_no in html
    assert "L 26-28 cm" in html  # 感謝頁與 purchase 事件都帶回買到的尺寸
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
