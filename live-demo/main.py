"""Day 04 即時驗證軌：極簡 Live Demo 電商站（Flask，部署於 Cloud Run 單一服務）。

流程：商品列表 → 前往結帳（伺服器計算金額）→ 綠界測試環境付款 → 回到感謝頁觸發 GA4 purchase。
所有 GA4 事件只在設定 GA_MEASUREMENT_ID 後才會送出；未設定時網站仍可正常操作。
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
from datetime import datetime

from flask import Flask, abort, render_template, request, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

import catalog as catalog_mod
import ecpay

GA_ID_PATTERN = re.compile(r"^G-[A-Z0-9]{4,}$")
GA_CLIENT_ID_PATTERN = re.compile(r"^\d{1,20}\.\d{1,20}$")

logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(message)s")
logger = logging.getLogger("live-demo")


def _log(event: str, **fields: object) -> None:
    """輸出一行 JSON，Cloud Run 會自動收進 Cloud Logging 的 jsonPayload。"""
    logger.info(json.dumps({"severity": "INFO", "event": event, **fields}, ensure_ascii=False))


def create_app() -> Flask:
    app = Flask(__name__)
    # Cloud Run 前面有 Google Front End，需信任一層代理的 X-Forwarded-Proto 才能產生正確的 https 網址。
    # 只信任 proto，不信任 host，避免使用者自帶 X-Forwarded-Host 竄改回呼網址。
    app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1)

    shop = catalog_mod.load_catalog()
    ga_id = os.environ.get("GA_MEASUREMENT_ID", "").strip()
    ga_id = ga_id if GA_ID_PATTERN.match(ga_id) else ""
    payment_mode = os.environ.get("PAYMENT_MODE", "ecpay").strip().lower()
    if payment_mode not in {"ecpay", "simulate"}:
        payment_mode = "ecpay"
    stage = ecpay.stage_config()
    config = ecpay.EcpayConfig(
        merchant_id=os.environ.get("ECPAY_MERCHANT_ID", stage.merchant_id),
        hash_key=os.environ.get("ECPAY_HASH_KEY", stage.hash_key),
        hash_iv=os.environ.get("ECPAY_HASH_IV", stage.hash_iv),
        # 本系列只示範測試環境，刻意不開放切換到正式收款網址
        action_url=ecpay.STAGE_ACTION_URL,
    )

    @app.context_processor
    def inject_globals() -> dict[str, object]:
        return {"shop": shop, "ga_id": ga_id, "payment_mode": payment_mode,
                "max_quantity": catalog_mod.MAX_QUANTITY}

    @app.after_request
    def security_headers(response):
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        return response

    @app.get("/")
    def index():
        return render_template("index.html")

    # 注意：Cloud Run 保留部分以 z 結尾的路徑，常見的 /healthz 會被攔截回 404，所以用 /health
    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/checkout/<product_id>")
    def checkout(product_id: str):
        product = shop.get(product_id)
        if product is None:
            abort(404)
        qty = catalog_mod.parse_quantity(request.args.get("qty"))
        cid = request.args.get("cid", "")
        cid = cid if GA_CLIENT_ID_PATTERN.match(cid) else ""
        amount = product.price * qty  # 金額只在伺服器端計算，前端傳什麼都不採信
        trade_no = ecpay.new_merchant_trade_no()

        if payment_mode == "simulate":
            _log("simulated_checkout", merchant_trade_no=trade_no, product_id=product.id,
                 qty=qty, amount=amount, ga_client_id=cid)
            return render_template(
                "thanks.html", success=True, simulated=True, trade_no=trade_no,
                amount=amount, product=product, qty=qty,
            )

        params = ecpay.build_order_params(
            config=config,
            merchant_trade_no=trade_no,
            total_amount=amount,
            item_name=f"{product.name} x {qty}",
            return_url=url_for("ecpay_return", _external=True),
            order_result_url=url_for("ecpay_result", _external=True),
            client_back_url=url_for("index", _external=True),
            custom_fields=(product.id, str(qty), cid),
        )
        _log("ecpay_order_created", merchant_trade_no=trade_no, product_id=product.id,
             qty=qty, amount=amount, ga_client_id=cid)
        return render_template("checkout_redirect.html", action_url=config.action_url,
                               params=params, product=product, qty=qty, amount=amount)

    @app.post("/ecpay/return")
    def ecpay_return():
        """綠界伺服器對伺服器的付款結果通知（ReturnURL），必須回應 1|OK。"""
        data = request.form.to_dict()
        verified = ecpay.verify_check_mac_value(data, config.hash_key, config.hash_iv)
        _log(
            "ecpay_payment_notify",
            verified=verified,
            merchant_trade_no=data.get("MerchantTradeNo", ""),
            trade_no=data.get("TradeNo", ""),
            rtn_code=data.get("RtnCode", ""),
            trade_amt=data.get("TradeAmt", ""),
            payment_date=data.get("PaymentDate", ""),
            simulate_paid=data.get("SimulatePaid", ""),
            product_id=data.get("CustomField1", ""),
            qty=data.get("CustomField2", ""),
            ga_client_id=data.get("CustomField3", ""),
            received_at=datetime.now(ecpay.TAIPEI).isoformat(),
        )
        if not verified:
            return "0|CheckMacValue Error", 400, {"Content-Type": "text/plain; charset=utf-8"}
        return "1|OK", 200, {"Content-Type": "text/plain; charset=utf-8"}

    @app.post("/ecpay/result")
    def ecpay_result():
        """付款完成後，綠界把消費者瀏覽器導回這裡（OrderResultURL）。"""
        data = request.form.to_dict()
        verified = ecpay.verify_check_mac_value(data, config.hash_key, config.hash_iv)
        trade_no = data.get("MerchantTradeNo", "")
        product = shop.get(data.get("CustomField1", ""))
        qty = catalog_mod.parse_quantity(data.get("CustomField2"))
        try:
            amount = int(data.get("TradeAmt", "0"))
        except ValueError:
            amount = 0
        # 注意：公開測試特店的 HashKey / HashIV 人人可得，驗章在這裡只能確認演算法與資料完整，
        # 無法防止有人自己算簽章偽造。所以再加上「訂單編號格式與時間」與「金額必須等於目錄價 × 數量」兩道檢查。
        amount_match = product is not None and amount == product.price * qty
        trade_no_recent = ecpay.trade_no_is_recent(trade_no)
        success = verified and data.get("RtnCode") == "1" and amount_match and trade_no_recent
        _log("ecpay_result_page", verified=verified, success=success, amount_match=amount_match,
             trade_no_recent=trade_no_recent, merchant_trade_no=trade_no, rtn_code=data.get("RtnCode", ""))
        return render_template(
            "thanks.html", success=success, simulated=False,
            trade_no=trade_no, amount=amount, product=product, qty=qty,
            rtn_msg=data.get("RtnMsg", ""),
        )

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), debug=False)
