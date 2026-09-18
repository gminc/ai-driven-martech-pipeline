"""綠界 ECPay 全方位金流（AIO）工具函式：訂單參數組裝與 CheckMacValue 檢查碼。

只負責純運算，不依賴 Flask，方便單元測試。
官方文件：https://developers.ecpay.com.tw/2902/（檢查碼）、https://developers.ecpay.com.tw/?p=2862（產生訂單）
"""

from __future__ import annotations

import hashlib
import hmac
import re
import secrets
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

STAGE_ACTION_URL = "https://payment-stage.ecpay.com.tw/Cashier/AioCheckOut/V5"
PROD_ACTION_URL = "https://payment.ecpay.com.tw/Cashier/AioCheckOut/V5"

# 綠界官方公開的「測試特店」資料，任何人都能使用，只能連到測試環境，不會真的扣款。
STAGE_MERCHANT_ID = "3002607"
STAGE_HASH_KEY = "pwFHCqoQZGmho4w6"
STAGE_HASH_IV = "EkRm7iFT261dpevs"

TAIPEI = timezone(timedelta(hours=8))

# 綠界採 .NET 的 URL encode 規則：這幾個字元不編碼
_DOTNET_SAFE_CHARS = "-_.!*()"


@dataclass(frozen=True)
class EcpayConfig:
    merchant_id: str
    hash_key: str
    hash_iv: str
    action_url: str


def stage_config() -> EcpayConfig:
    return EcpayConfig(STAGE_MERCHANT_ID, STAGE_HASH_KEY, STAGE_HASH_IV, STAGE_ACTION_URL)


def check_mac_value(params: dict[str, str], hash_key: str, hash_iv: str) -> str:
    """依綠界規則計算 CheckMacValue（SHA256，大寫十六進位）。"""
    fields = {k: str(v) for k, v in params.items() if k != "CheckMacValue"}
    ordered = "&".join(f"{k}={fields[k]}" for k in sorted(fields, key=str.lower))
    raw = f"HashKey={hash_key}&{ordered}&HashIV={hash_iv}"
    # Python 不編碼「~」，但綠界（.NET / PHP）會編成 %7E，這裡補齊以免含「~」的參數驗章失敗
    encoded = urllib.parse.quote_plus(raw, safe=_DOTNET_SAFE_CHARS).replace("~", "%7E").lower()
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest().upper()


def verify_check_mac_value(params: dict[str, str], hash_key: str, hash_iv: str) -> bool:
    """驗證綠界回傳資料的 CheckMacValue，避免偽造的付款通知。"""
    received = params.get("CheckMacValue", "")
    if not received:
        return False
    expected = check_mac_value(params, hash_key, hash_iv)
    return hmac.compare_digest(expected, received.upper())


TRADE_NO_PATTERN = re.compile(r"^DM(\d{14})[0-9A-F]{4}$")


def trade_no_is_recent(trade_no: str, now: datetime | None = None, max_age: timedelta = timedelta(hours=24)) -> bool:
    """確認訂單編號是本站格式，且建立時間在合理範圍內（擋掉隨手捏造或過期的編號）。"""
    match = TRADE_NO_PATTERN.match(trade_no or "")
    if not match:
        return False
    created = datetime.strptime(match.group(1), "%Y%m%d%H%M%S").replace(tzinfo=TAIPEI)
    now = now or datetime.now(TAIPEI)
    return timedelta(minutes=-5) <= now - created <= max_age


def new_merchant_trade_no(now: datetime | None = None) -> str:
    """產生 20 碼內、不重複的特店訂單編號，例如 DM20260918093015A1B2。"""
    now = now or datetime.now(TAIPEI)
    return f"DM{now:%Y%m%d%H%M%S}{secrets.token_hex(2).upper()}"


def build_order_params(
    *,
    config: EcpayConfig,
    merchant_trade_no: str,
    total_amount: int,
    item_name: str,
    return_url: str,
    order_result_url: str,
    client_back_url: str,
    custom_fields: tuple[str, str, str, str] = ("", "", "", ""),
    now: datetime | None = None,
) -> dict[str, str]:
    """組出 AioCheckOut/V5 所需參數（含 CheckMacValue）。金額一律由伺服器決定。"""
    if total_amount <= 0:
        raise ValueError("total_amount 必須為正整數")
    now = now or datetime.now(TAIPEI)
    params = {
        "MerchantID": config.merchant_id,
        "MerchantTradeNo": merchant_trade_no,
        "MerchantTradeDate": f"{now:%Y/%m/%d %H:%M:%S}",
        "PaymentType": "aio",
        "TotalAmount": str(int(total_amount)),
        "TradeDesc": "iThome ironman live demo",
        "ItemName": item_name[:400],
        "ReturnURL": return_url,
        "OrderResultURL": order_result_url,
        "ClientBackURL": client_back_url,
        "ChoosePayment": "Credit",
        "EncryptType": "1",
        "CustomField1": custom_fields[0][:50],
        "CustomField2": custom_fields[1][:50],
        "CustomField3": custom_fields[2][:50],
        "CustomField4": custom_fields[3][:50],
    }
    params["CheckMacValue"] = check_mac_value(params, config.hash_key, config.hash_iv)
    return params
