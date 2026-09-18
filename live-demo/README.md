# 織日常 Live Demo

2026 iThome 鐵人賽 Day 04 的即時驗證軌：一個 Flask 服務，同時負責商品瀏覽、結帳簽章、綠界付款結果通知與 GA4 電子商務事件追蹤，部署在 Cloud Run 單一服務上。

文章只保留「為什麼這樣做」，實作細節放這裡。

## 本機執行

```shell
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest -q tests          # 26 passed
PAYMENT_MODE=simulate python main.py
```

`PAYMENT_MODE=simulate` 會跳過綠界直接顯示感謝頁，適合沒有公開網址的環境（Cloud Shell 網頁預覽、本機）。綠界伺服器必須能連到 `ReturnURL` 才收得到付款結果通知。

| 環境變數 | 預設值 | 說明 |
| --- | --- | --- |
| `GA_MEASUREMENT_ID` | 空 | 需符合 `^G-[A-Z0-9]{4,}$`，不合法視為未設定，網站照常運作但不送事件 |
| `PAYMENT_MODE` | `ecpay` | `ecpay` 或 `simulate`，其他值一律當成 `ecpay` |
| `ECPAY_MERCHANT_ID` | `3002607` | 綠界公開測試特店 |
| `ECPAY_HASH_KEY` | 公開測試值 | 正式環境請改用 Secret Manager |
| `ECPAY_HASH_IV` | 公開測試值 | 同上 |
| `PORT` | `8080` | Cloud Run 會自動注入 |

付款網址寫死為測試環境 `STAGE_ACTION_URL`，程式沒有開放切換到正式收款網址。

## CheckMacValue 演算法

綠界用這個欄位確認參數在傳輸途中沒有被改動。`ecpay.py` 的實作分六步：

1. 取出除 `CheckMacValue` 以外的所有參數
2. 參數名稱按英文字母排序，大小寫不分（`sorted(fields, key=str.lower)`）
3. 串成 `key1=value1&key2=value2...`
4. 前面接 `HashKey=<HashKey>&`，後面接 `&HashIV=<HashIV>`
5. 做 .NET 風格的 URL 編碼後全部轉小寫
6. 取 SHA256，轉成大寫十六進位

第 5 步是最容易出錯的地方。綠界後端是 .NET，`HttpUtility.UrlEncode` 的規則與 Python 的 `quote_plus` 有三個差異：

| 項目 | .NET | Python 預設 | 本專案作法 |
| --- | --- | --- | --- |
| 空白 | `+` | `+` | 相同 |
| `-_.!*()` | 不編碼 | 只有 `-_.` 不編碼 | `quote_plus(raw, safe="-_.!*()")` |
| `~` | 編成 `%7E` | 不編碼 | 編碼後再 `.replace("~", "%7E")` |

```python
def dotnet_urlencode(raw: str) -> str:
    return urllib.parse.quote_plus(raw, safe="-_.!*()").replace("~", "%7E").lower()
```

`tests/test_ecpay.py` 用綠界官方文件的範例參數驗證整段演算法，期望雜湊值是硬編碼的外部值，不是拿實作再算一次。另外有一組手寫的編碼期望值驗證上表三條規則。

驗章用 `hmac.compare_digest` 比對，收到的簽章為空值時直接回 `False`。

## 綠界訂單參數

`build_order_params()` 產生的完整欄位：

| 參數 | 值 | 備註 |
| --- | --- | --- |
| `MerchantID` | 特店編號 | |
| `MerchantTradeNo` | `DM` + 14 碼時間 + 4 碼隨機十六進位 | 共 20 碼，綠界上限即 20 |
| `MerchantTradeDate` | `%Y/%m/%d %H:%M:%S` | 台北時間，容器預設 UTC 會差 8 小時 |
| `PaymentType` | `aio` | 固定值 |
| `TotalAmount` | 定價 × 數量 | 伺服器計算，金額小於等於 0 直接丟 `ValueError` |
| `TradeDesc` | 固定字串 | |
| `ItemName` | 品名 + 尺寸 + 數量 | 先把 `#` 與 `^` 換成空白再截到 400 字 |
| `ReturnURL` | `/ecpay/return` | 伺服器對伺服器的付款結果通知 |
| `OrderResultURL` | `/ecpay/result` | 付款完成後瀏覽器導回 |
| `ClientBackURL` | 首頁 | 與 `OrderResultURL` 並存時以後者為主 |
| `ChoosePayment` | `Credit` | |
| `EncryptType` | `1` | SHA256 |
| `CustomField1` | 商品 ID | |
| `CustomField2` | `數量` + `\|` + `尺寸索引` | 只放 ASCII，理由見下 |
| `CustomField3` | GA4 `client_id` | |
| `CustomField4` | `utm_source\|utm_medium\|utm_campaign` | |

四個自訂欄位在組參數前逐一檢查長度，**超過綠界的 50 字上限直接丟 `ValueError`，不做靜默截斷**。截斷過的欄位在回程還原不回來，錯誤會延後到付款完成那一刻才爆開。

### 為什麼自訂欄位只放 ASCII

自訂欄位的原字串會被納入 `CheckMacValue`，而驗章是拿綠界回傳的字面值重算。只要金流端在任何環節對中文或半形空白做過正規化（去尾端空白、空白轉 `+`、回傳 percent-encoded 值），簽章就對不起來，整筆付款會在感謝頁被判定失敗，而且失敗時沒有任何錯誤訊息。純 ASCII 數字沒有這個風險。

尺寸的還原策略與入口端刻意相反：

- `Product.resolve_size(raw)`：結帳入口用，不合法退回預設尺寸，目的是不讓前端塞任意字串進金流參數
- `Product.size_by_index(raw)`：回程還原用，不合法回空字串，**絕不猜預設值**，猜錯的後果是 GA4 把某個變體的營收算到另一個變體頭上，而且沒有告警

## 感謝頁的三道檢查

公開測試特店的 HashKey 與 HashIV 人人可得，任何人都能自己算出「正確」的簽章。所以 `/ecpay/result` 除了驗章還要再確認兩件事，三道全過才輸出購買資料：

1. `verify_check_mac_value()` 通過，且 `RtnCode == "1"`
2. `TradeAmt` 等於商品定價 × 數量（數量取自 `CustomField2`）
3. `trade_no_is_recent()`：訂單編號符合 `^DM(\d{14})[0-9A-F]{4}$`，且產生時間落在 −5 分鐘到 24 小時之間

`/ecpay/return` 只做驗章，通過回 `1|OK`，失敗回 `0|CheckMacValue Error` 與 HTTP 400。綠界沒收到 `1|OK` 會重送。

## 其他防護

- `ProxyFix(x_proto=1)`：只信任 Google Front End 送來的協定標頭，刻意不信任 `X-Forwarded-Host`，避免有人自帶標頭把回程網址改到別的網域
- `MAX_CONTENT_LENGTH = 64 KB`：`/ecpay/return` 是公開端點，限制 body 大小避免被拿來灌 Cloud Logging
- 兩個綠界端點寫進日誌的自訂欄位都截到 60 字
- `/health` 不用 `/healthz`：Cloud Run 保留部分以 `z` 結尾的路徑，會攔截後直接回 Google 的 404

## 商品目錄

`products.json` 的啟動期驗證（`catalog.py`）：商品 ID 不可重複、活動代號不可重複、活動指到的商品必須存在、價格必須為正整數、每個商品至少要有一個且不重複的尺寸選項。任何一項不過，容器會在啟動時就失敗，而不是等到使用者結帳才出錯。

數量只接受 1 到 5，其餘輸入一律視為 1。

## 測試

`tests/` 共 26 項，重點包含：

- 以綠界官方範例驗證 `CheckMacValue`，以及手寫期望值驗證 .NET 編碼規則
- 竄改金額後驗章必須失敗
- `ReturnURL` 只有簽章正確才回 `1|OK`
- 自行算出正確簽章但金額不符、或訂單編號過舊，都不輸出購買資料
- 尺寸只接受目錄內的值，回程還原不出尺寸時不帶 `item_variant`
- `products.json`、樣板與 CSS 引用的圖片檔都確實存在，且商品圖不再有 SVG
