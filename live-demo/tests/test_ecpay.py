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
    assert all(len(n) == 20 and n.isalnum() and ecpay.TRADE_NO_PATTERN.match(n) for n in numbers)
    # 同一秒的亂數只有 16 bits，50 筆理論上有約 2% 機率撞到一次；展示站流量下可接受
    assert len(numbers) >= 48


def test_build_order_params_contains_required_fields():
    now = datetime(2026, 9, 18, 9, 30, 15, tzinfo=ecpay.TAIPEI)
    params = ecpay.build_order_params(
        config=ecpay.stage_config(), merchant_trade_no="DM20260918093015ABCD", total_amount=360,
        item_name="日常中筒襪 x 2", return_url="https://example.com/ecpay/return",
        order_result_url="https://example.com/ecpay/result", client_back_url="https://example.com/",
        custom_fields=("sock-crew-daily", "2", "123.456", "google|cpc|autumn"), now=now,
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


def test_dotnet_urlencode_matches_ecpay_rule():
    """期望值依綠界文件的 .NET UrlEncode 規則逐字寫死，不是拿實作再算一次。"""
    assert ecpay.dotnet_urlencode("a~b c*d!e(f)g-h_i.j") == "a%7eb+c*d!e(f)g-h_i.j"
    # UTF-8 逐位元組轉小寫百分號編碼：純 = E7 B4 94、棉 = E6 A3 89
    assert ecpay.dotnet_urlencode("純棉 34x76") == "%e7%b4%94%e6%a3%89+34x76"
    assert ecpay.dotnet_urlencode("a/b?c=d&e") == "a%2fb%3fc%3dd%26e"


def test_trade_no_is_recent():
    now = datetime(2026, 9, 18, 9, 30, 15, tzinfo=ecpay.TAIPEI)
    assert ecpay.trade_no_is_recent(ecpay.new_merchant_trade_no(now), now=now)
    assert not ecpay.trade_no_is_recent("DM20260916093015ABCD", now=now)
    assert not ecpay.trade_no_is_recent("DM20260918103015ABCD", now=now)
    assert not ecpay.trade_no_is_recent("hello", now=now)
