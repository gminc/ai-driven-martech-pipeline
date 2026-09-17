from datetime import datetime

import pytest

import ecpay

# 綠界官方文件「檢查碼機制」範例（https://developers.ecpay.com.tw/2902/）
OFFICIAL_EXAMPLE = {
    "TradeDesc": "促銷方案",
    "PaymentType": "aio",
    "MerchantTradeDate": "2023/03/12 15:30:23",
    "MerchantTradeNo": "ecpay20230312153023",
    "MerchantID": "3002607",
    "ReturnURL": "https://www.ecpay.com.tw/receive.php",
    "ItemName": "Apple iphone 15",
    "TotalAmount": "30000",
    "ChoosePayment": "ALL",
    "EncryptType": "1",
}
OFFICIAL_EXPECTED = "6C51C9E6888DE861FD62FB1DD17029FC742634498FD813DC43D4243B5685B840"


def test_check_mac_value_matches_official_example():
    assert ecpay.check_mac_value(OFFICIAL_EXAMPLE, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV) == OFFICIAL_EXPECTED


def test_verify_round_trip_and_tamper():
    params = dict(OFFICIAL_EXAMPLE, CheckMacValue=OFFICIAL_EXPECTED)
    assert ecpay.verify_check_mac_value(params, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV)
    tampered = dict(params, TotalAmount="1")
    assert not ecpay.verify_check_mac_value(tampered, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV)
    assert not ecpay.verify_check_mac_value(OFFICIAL_EXAMPLE, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV)


def test_merchant_trade_no_length_and_uniqueness():
    now = datetime(2026, 9, 18, 9, 30, 15, tzinfo=ecpay.TAIPEI)
    numbers = {ecpay.new_merchant_trade_no(now) for _ in range(50)}
    assert all(len(n) <= 20 and n.isalnum() for n in numbers)
    assert len(numbers) > 1


def test_build_order_params_contains_required_fields():
    now = datetime(2026, 9, 18, 9, 30, 15, tzinfo=ecpay.TAIPEI)
    params = ecpay.build_order_params(
        config=ecpay.stage_config(), merchant_trade_no="DM20260918093015ABCD", total_amount=360,
        item_name="日常中筒襪 x 2", return_url="https://example.com/ecpay/return",
        order_result_url="https://example.com/ecpay/result", client_back_url="https://example.com/",
        custom_fields=("sock-crew-daily", "2", "123.456"), now=now,
    )
    for key in ["MerchantID", "MerchantTradeNo", "MerchantTradeDate", "PaymentType", "TotalAmount",
                "TradeDesc", "ItemName", "ReturnURL", "ChoosePayment", "EncryptType", "CheckMacValue"]:
        assert params[key]
    assert params["MerchantTradeDate"] == "2026/09/18 09:30:15"
    assert params["TotalAmount"] == "360"
    assert ecpay.verify_check_mac_value(params, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV)


def test_build_order_params_rejects_non_positive_amount():
    with pytest.raises(ValueError):
        ecpay.build_order_params(
            config=ecpay.stage_config(), merchant_trade_no="X", total_amount=0, item_name="x",
            return_url="u", order_result_url="u", client_back_url="u",
        )


def test_tilde_is_encoded_like_dotnet():
    base = dict(OFFICIAL_EXAMPLE, ItemName="a~b")
    mac = ecpay.check_mac_value(base, ecpay.STAGE_HASH_KEY, ecpay.STAGE_HASH_IV)
    import hashlib, urllib.parse
    fields = sorted(base, key=str.lower)
    raw = "HashKey=%s&%s&HashIV=%s" % (ecpay.STAGE_HASH_KEY, "&".join(f"{k}={base[k]}" for k in fields), ecpay.STAGE_HASH_IV)
    encoded = urllib.parse.quote_plus(raw, safe="-_.!*()").replace("~", "%7E").lower()
    assert "%7e" in encoded
    assert mac == hashlib.sha256(encoded.encode()).hexdigest().upper()


def test_trade_no_is_recent():
    now = datetime(2026, 9, 18, 9, 30, 15, tzinfo=ecpay.TAIPEI)
    assert ecpay.trade_no_is_recent(ecpay.new_merchant_trade_no(now), now=now)
    assert not ecpay.trade_no_is_recent("DM20260916093015ABCD", now=now)
    assert not ecpay.trade_no_is_recent("DM20260918103015ABCD", now=now)
    assert not ecpay.trade_no_is_recent("hello", now=now)
