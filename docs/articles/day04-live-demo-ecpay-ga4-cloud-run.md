Day 04 | 即時驗證軌：極簡 Live Demo 站與事件追蹤埋設 —— Cloud Run 單一服務、綠界測試金流與 GA4 電子商務事件一次到位

# 1. 前言：沒有真實點擊，歸因分析只是紙上談兵

Day 01 提過本系列採用「雙軌資料架構」：軌道 B 用合成器灌入 50 萬筆歷史日誌撐起分析規模，軌道 A 則要證明「資料流是真的通的」。很多 MarTech 教學一開始就拿現成的 CSV 做歸因，但實務上最常出問題的，往往不是模型，而是更前面的三件事：

- **事件根本沒送出去**：按鈕改版後埋碼失效、廣告攔截器擋掉追蹤程式，報表上的轉換數默默變少，卻沒有人發現。
- **金額與訂單對不起來**：前端送出的購買金額被竄改或重複計算，GA4 的營收和金流後台永遠差一截。
- **結帳流程卡在追蹤程式**：為了等追蹤事件送完，使用者按下結帳後要多等好幾秒，甚至因為 GA 被擋而卡住。

所以在第 4 天，我們先搭一個「真的可以點、可以結帳」的極簡電商展示站，把事件追蹤與金流串起來，讓後面每一天的分析都有一條真實資料可以對照。

今日核心交付目標：

1. 以 **Cloud Run 單一服務** 部署一個有品牌故事、商品詳情頁與活動著陸頁的紡織小店 Live Demo（襪子、毛巾、浴巾共 5 款）。
2. 串接 **綠界 ECPay 測試環境**，由伺服器計算金額與 CheckMacValue，並驗證付款回呼。
3. 埋設 **GA4 電子商務四大事件**：`view_item_list`、`view_item`、`begin_checkout`、`purchase`，並規劃每日匯出到 BigQuery。

> **關於 Stripe 與 Firebase 的說明**：Day 01 與 Day 03 原本規劃「Firebase Hosting / Cloud Functions ＋ Stripe Test Mode」。實作時發現兩件事：
>
> - Stripe 目前的官方支援國家清單沒有台灣，台灣團隊要用 Stripe 必須另外走申請流程，目前還在進行中。為了讓讀者今天就能完整跑完結帳，本篇改用台灣讀者更熟悉、且提供公開測試特店的綠界 ECPay 測試環境。若 30 天賽期內 Stripe 流程通過，會再另文補充 Stripe 版本。
> - 頁面、結帳簽章與付款通知其實只需要一個小小的 Python 服務，用 Cloud Run 單一服務就能全部處理，也和系列後段的 Cloud Run AI 助理共用同一套部署方式，所以本篇不另外拆 Hosting 與 Functions。

> **Live Demo 網址**：https://martech-live-demo-enki4czjsa-de.a.run.app
> 本站為技術展示，品牌「織日常」與商品皆為示範用途，使用綠界測試環境，不會實際扣款，商品也不會出貨。

---

# 2. 系統架構全景與設計理念

![Day 04 Live Demo 站部署架構圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day04-live-demo-architecture.svg)

💡 **核心工程理念**：

1. **一個容器搞定前後台**：Cloud Run 上只跑一個 Flask 服務，同時負責商品頁、結帳簽章、付款通知與感謝頁。不需要另外架資料庫或 Functions，部署、權限與成本都只有一份。
2. **金額只相信伺服器**：價格寫在伺服器端的 `products.json`，前端只能傳「商品 ID」與「數量」，金額與簽章都在後台計算，使用者改網址也改不了價錢。
3. **事件與金流分工**：瀏覽器上的 `gtag` 事件直送 GA4，負責行為分析；綠界的付款通知打到伺服器，寫進 Cloud Logging，負責「真的有付款」的紀錄。兩邊用同一個訂單編號對帳。
4. **沒人造訪就不收費**：Cloud Run 最少 0 個執行個體、請求制計費，展示站閒置時費用為零；最多 2 個執行個體，避免被灌流量時燒錢。

**為什麼不做成一頁式的陽春頁面？** 因為後面幾天的分析都要靠它產生資料：Day 07 的多觸點歸因需要「從廣告進站 → 逛商品 → 結帳」這種有層次的瀏覽路徑，Day 18 要拿廣告素材和落地頁做一致性比對，就得真的有一張落地頁。所以站台長這樣：

| 路徑 | 頁面 | 這一頁在後面幾天的用途 |
| --- | --- | --- |
| `/` | 首頁：品牌故事、三大工藝主張、商品列表 | 列表曝光與商品點擊 |
| `/product/<商品 ID>` | 商品詳情：多圖、材質規格、洗滌方式 | 商品檢視、Day 14 素材特徵抽取 |
| `/about` | 品牌與織造介紹 | 瀏覽深度、跳出率對照 |
| `/lp/<活動代號>` | 活動著陸頁 | Day 18 落地頁與廣告素材一致性 |
| `/checkout/<商品 ID>` | 產生綠界簽章表單 | 結帳事件 |
| `/ecpay/return`、`/ecpay/result` | 付款通知與感謝頁 | 購買事件與付款紀錄 |

程式碼全部放在儲存庫的 `live-demo/` 目錄：

```text
live-demo/
├── main.py              # Flask 路由：首頁、商品頁、活動頁、結帳、綠界回呼
├── ecpay.py             # 綠界參數組裝與 CheckMacValue（純函式，好測試）
├── catalog.py           # 讀取 products.json：商品、工藝主張、活動
├── products.json        # 品牌文案、5 款商品、2 檔活動
├── templates/           # base 版型、首頁、商品頁、品牌頁、活動頁、感謝頁
├── static/analytics.js  # GA4 電子商務事件埋設
├── static/img/          # 商品與情境插圖（SVG，無外部資源）
├── tests/               # pytest：官方範例驗章、路由與防竄改測試
└── Dockerfile           # python:3.12-slim + gunicorn
```

---

# 3. 核心技術深度拆解

## 3.1 商品目錄與伺服器端定價

`products.json` 一次定義品牌文案、三大工藝主張、5 款商品與 2 檔活動。商品欄位除了價格，也包含材質、尺寸、洗滌方式這些會出現在詳情頁的資料：

```json
{
  "id": "sock-towel-training",
  "name": "厚底毛巾訓練襪",
  "subtitle": "毛圈底 × 足弓支撐",
  "category": "襪子",
  "price": 260,
  "image": "img/sock-towel.svg",
  "gallery": ["img/sock-towel.svg", "img/sock-towel-detail.svg"],
  "material": "精梳棉 72%、尼龍 25%、彈性纖維 3%",
  "size": "適合足長 24–28 cm",
  "care": "30°C 以下溫水機洗，翻面洗滌以保護毛圈，陰乾",
  "made_in": "彰化社頭"
}
```

`catalog.py` 載入時會檢查商品 ID 不可重複、活動代號不可重複、活動指到的商品必須存在、價格必須為正整數；數量只接受 1 到 5，其他任何輸入（空白、負數、小數、文字）一律視為 1。這些檢查放在啟動時，設定寫錯會讓容器直接起不來，而不是等到使用者結帳才出錯。之後 Day 05 的合成器也會沿用同一份商品 ID，讓真實事件與模擬日誌可以直接 JOIN。

## 3.2 綠界測試金流：伺服器簽章與雙重回呼

![綠界 ECPay 測試金流與 CheckMacValue 驗章流程圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day04-ecpay-checkmac-flow.svg)

綠界「全方位金流（AIO）」的串接方式很單純：由我們的網站產生一張帶有簽章的表單，讓瀏覽器 POST 到綠界的付款頁。整個流程如下：

1. 使用者按下「前往結帳」，瀏覽器呼叫 `GET /checkout/<商品 ID>?qty=2`。
2. 伺服器查價格、算總額、產生 20 碼內不重複的訂單編號（例如 `DM20260918093015A1B2`），組好參數並計算 `CheckMacValue`。
3. 伺服器回傳一個隱藏表單頁面。
4. 表單自動 POST 到綠界測試環境 `https://payment-stage.ecpay.com.tw/Cashier/AioCheckOut/V5`。
5. 在綠界頁面用測試卡付款。
6. 綠界伺服器 POST 付款結果到我們的 `ReturnURL`（`/ecpay/return`），我們驗章後回應 `1|OK`。
7. 綠界把使用者瀏覽器導回 `OrderResultURL`（`/ecpay/result`），同樣帶著付款結果與簽章。
8. 伺服器驗章、確認 `RtnCode` 為 `1`、金額等於目錄價 × 數量、訂單編號格式與時間合理，全部通過才在感謝頁輸出購買資料，觸發 GA4 `purchase`。

組參數的核心程式碼如下（`ecpay.py`）：

```python
params = {
    "MerchantID": config.merchant_id,
    "MerchantTradeNo": merchant_trade_no,
    "MerchantTradeDate": f"{now:%Y/%m/%d %H:%M:%S}",  # 台北時間
    "PaymentType": "aio",
    "TotalAmount": str(int(total_amount)),            # 新台幣整數
    "TradeDesc": "iThome ironman live demo",
    "ItemName": item_name[:400],
    "ReturnURL": return_url,              # 伺服器對伺服器通知
    "OrderResultURL": order_result_url,   # 付款完成導回瀏覽器
    "ClientBackURL": client_back_url,
    "ChoosePayment": "Credit",
    "EncryptType": "1",                   # SHA256
    "CustomField1": product_id,           # 自訂欄位：商品 ID
    "CustomField2": qty,                  # 自訂欄位：數量
    "CustomField3": ga_client_id,         # 自訂欄位：GA client_id
    "CustomField4": traffic_source,       # 自訂欄位：utm 來源|媒介|活動
}
params["CheckMacValue"] = check_mac_value(params, config.hash_key, config.hash_iv)
```

特別說明兩個自訂欄位。`CustomField3` 放 GA4 的 `client_id`，付款通知回來時就能在日誌中知道「這筆付款是哪個 GA 訪客」；`CustomField4` 放進站時記下的 `utm_source|utm_medium|utm_campaign`。後面做歸因分析時，這兩個欄位就是把金流紀錄、行為事件與廣告來源串起來的鑰匙。

來源是在瀏覽器端記的：訪客第一次帶著 `utm_` 參數進站時，`analytics.js` 會把來源寫進 `sessionStorage`，結帳時再塞進表單的隱藏欄位送回伺服器。伺服器只接受 `[A-Za-z0-9_.|-]` 且長度 50 以內的字串，其餘一律視為空值，避免有人塞奇怪的內容進金流參數。

## 3.3 CheckMacValue：讓雙方確認資料沒被竄改

`CheckMacValue` 是綠界的簽章機制，我們送出訂單時要算，綠界回呼時也要驗。演算法固定為 6 步：

1. 移除 `CheckMacValue` 本身，其餘參數依名稱 A 到 Z 排序，組成 `key=value&key=value`。
2. 前面加上 `HashKey=...&`，後面加上 `&HashIV=...`。
3. 依 .NET 規則做 URL encode（`-`、`_`、`.`、`!`、`*`、`(`、`)` 不編碼，空白變成 `+`，`~` 要編成 `%7E`）。
4. 全部轉成小寫。
5. SHA256 雜湊。
6. 轉成大寫。

```python
_DOTNET_SAFE_CHARS = "-_.!*()"

def check_mac_value(params, hash_key, hash_iv):
    fields = {k: str(v) for k, v in params.items() if k != "CheckMacValue"}
    ordered = "&".join(f"{k}={fields[k]}" for k in sorted(fields, key=str.lower))
    raw = f"HashKey={hash_key}&{ordered}&HashIV={hash_iv}"
    # Python 不會編碼「~」，綠界會，這裡補上
    encoded = urllib.parse.quote_plus(raw, safe=_DOTNET_SAFE_CHARS).replace("~", "%7E").lower()
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest().upper()

def verify_check_mac_value(params, hash_key, hash_iv):
    received = params.get("CheckMacValue", "")
    if not received:
        return False
    expected = check_mac_value(params, hash_key, hash_iv)
    return hmac.compare_digest(expected, received.upper())
```

驗章時用 `hmac.compare_digest` 做固定時間比對，避免被用回應時間猜出簽章。單元測試直接拿綠界官方文件的範例參數，確認輸出和官方公布的檢查碼一字不差；另外也測試「竄改金額後驗章必須失敗」。

⚠️ **公開測試金鑰的限制**：本篇使用綠界官方公開的測試特店，HashKey / HashIV 人人都查得到，任何人都能自己算出正確的簽章。所以在這個展示站上，驗章只能確認「演算法正確、資料沒有傳壞」，**擋不住刻意偽造**。為了盡量減少假的購買事件污染之後要分析的 GA4 資料，感謝頁另外加了兩道伺服器端檢查（能擋掉隨手捏造、竄改金額與過期重送的資料，但懂規則的人仍然可以偽造）：

- **金額必須等於目錄價 × 數量**：`TradeAmt` 與 `products.json` 對不上就不送 `purchase`。
- **訂單編號必須是本站格式且時間合理**：`MerchantTradeNo` 必須是 `DM` 加 14 碼時間與 4 碼隨機碼，且建立時間在 24 小時內。

正式上線時換成自己特店的 HashKey / HashIV，驗章才真正具備防偽效果；若要做到滴水不漏，還應該把建立過的訂單寫進資料庫，回呼時逐筆比對。

`ReturnURL` 的處理原則是：**驗章失敗就不當作付款**。

```python
@app.post("/ecpay/return")
def ecpay_return():
    data = request.form.to_dict()
    verified = ecpay.verify_check_mac_value(data, config.hash_key, config.hash_iv)
    _log("ecpay_payment_notify", verified=verified,
         merchant_trade_no=data.get("MerchantTradeNo", ""),
         rtn_code=data.get("RtnCode", ""), trade_amt=data.get("TradeAmt", ""),
         ga_client_id=data.get("CustomField3", ""))
    if not verified:
        return "0|CheckMacValue Error", 400
    return "1|OK", 200
```

`_log` 會輸出一行 JSON 到標準輸出，Cloud Run 自動收進 Cloud Logging，並解析成可以查詢的 `jsonPayload` 欄位。本篇先不建資料庫，付款紀錄就放在日誌裡，之後的章節再決定要不要匯入 BigQuery。

🔒 **金鑰安全**：程式預設使用綠界**官方公開**的測試特店（MerchantID `3002607`），這組 HashKey / HashIV 寫在綠界文件中，任何人都能用，也只能連到測試環境。程式也刻意把付款網址固定為測試環境。若日後改接正式特店，HashKey / HashIV 必須放進 Secret Manager，絕對不能寫進程式碼或推上 GitHub。

## 3.4 GA4 電子商務事件埋設

![GA4 電子商務事件漏斗與五個埋設點](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day04-ga4-ecommerce-event-flow.svg)

事件名稱與參數依 GA4 建議的電子商務事件規格，全部寫在 `static/analytics.js`：

| 事件 | 觸發時機 | 關鍵參數 |
| --- | --- | --- |
| `view_item_list` | 任何有商品列表的頁面載入（首頁、活動頁、相關商品） | `item_list_id`、`item_list_name`、`items` |
| `select_item` | 點擊商品卡片 | `item_list_id`、`items` |
| `view_item` | 商品詳情頁載入 | `currency`、`value`、`items` |
| `view_promotion` / `select_promotion` | 活動著陸頁載入 / 點擊活動按鈕 | `promotion_id`、`promotion_name`、`creative_name`、`creative_slot` |
| `begin_checkout` | 按下「前往結帳」 | `value` = 單價 × 數量、`items[].quantity` |
| `purchase` | 驗章成功的感謝頁 | `transaction_id`、`value`、`currency`、`items` |

`item_list_id` 會隨著列表位置變化（`home_all`、`lp_autumn-cotton`、`related_<商品 ID>`），之後就能回答「從活動頁點進去的人，最後買了什麼」這種問題。`view_promotion` 與 `creative_name` 則是 Day 18 比對「廣告素材」與「落地頁」的接點。

最需要小心的是 `begin_checkout`，因為它發生在「離開網站前的最後一刻」：

```javascript
form.addEventListener("submit", function (event) {
  event.preventDefault();
  var submitted = false;
  function go() { if (!submitted) { submitted = true; form.submit(); } }

  window.gtag("get", config.gaId, "client_id", function (clientId) {
    form.querySelector("input[name=cid]").value = clientId || "";
    window.gtag("event", "begin_checkout", {
      currency: config.currency,
      value: item.price * qty,
      items: [checkoutItem],
      event_callback: go          // 事件送出後才跳轉
    });
  });
  window.setTimeout(go, 1200);    // GA 被擋掉時，最多等 1.2 秒也要讓使用者結帳
});
```

- 先用 `gtag('get', ..., 'client_id')` 取得訪客 ID，帶到伺服器寫進綠界的 `CustomField3`。
- 用 `event_callback` 等事件送出後再跳轉，避免頁面離開時事件遺失。
- 加上 1.2 秒的保底計時器，就算廣告攔截器擋掉 GA，結帳也不會卡住。**追蹤是為了生意服務，不能反過來擋住生意。**

`purchase` 則完全由伺服器決定是否輸出。只有驗章成功、`RtnCode` 為 `1` 的感謝頁，才會在頁面中放入購買資料：

```html
<script id="purchase-data" type="application/json">
  {"transaction_id": "DM20260918093015A1B2", "value": 520, "currency": "TWD", "items": [...]}
</script>
```

`transaction_id` 使用綠界訂單編號。同一位使用者重複送出相同交易 ID 的 `purchase`（例如重新整理感謝頁），GA4 報表會去除重複；但這個去重只作用在 GA4 報表，BigQuery 匯出的原始事件仍可能出現重複，之後寫 SQL 時要以 `transaction_id` 自行去重。另外，模擬結帳模式每次重新整理都會產生新的訂單編號，無法去重，只適合用來看畫面。資料用 `type="application/json"` 搭配 Jinja 的 `tojson` 輸出，不把變數直接拼進 JavaScript，避免跨站腳本（XSS）風險。

另外，GA4 評估 ID 透過環境變數 `GA_MEASUREMENT_ID` 設定，而且必須符合 `G-` 開頭的格式才會載入 gtag。還沒申請 GA4 也沒關係，網站照樣能完整操作，事件只會印在瀏覽器 Console，方便先驗證埋設邏輯。

## 3.5 GA4 每日匯出到 BigQuery

在匯出之前，還有一個對歸因分析非常關鍵的設定：付款完成後，瀏覽器是從綠界的網域被導回感謝頁，GA4 預設會把這次造訪當成「從 `payment-stage.ecpay.com.tw` 推薦過來」，開一個新的工作階段，結果購買就被歸功給綠界，而不是原本帶來訂單的廣告。解法是到 GA4「管理 → 資料串流 → 網站 → 點選你的串流 → 進行代碼設定 → 在「設定」區塊點「全部顯示」→ 列出不適用的參照連結網址」，新增一個條件，網域填入 `ecpay.com.tw` 後儲存（比對類型依介面選項選擇「包含」）。

GA4 收到的事件，可以透過官方「BigQuery 連結」每天匯出一次到 BigQuery：

- 匯出位置選 **美國（US）**，和 Day 03 建立的 `martech_dw` 資料集位置一致，之後才能在同一個查詢中 JOIN。
- 系統會自動建立資料集 `analytics_<資源 ID>`，每天產生一張 `events_YYYYMMDD` 事件表。
- **只勾選「每日」匯出**：每日匯出不收匯出費（標準版資源每天上限 100 萬個事件，展示站遠遠用不到）；「串流」匯出需另外付費，本系列不需要。
- 建立連結需要兩個權限：GA4 資源的「編輯者」以上，以及 Google Cloud 專案的「擁有者」。
- 「使用者資料」的每日匯出本篇用不到，可以先不開。

💡 **建議今天就把連結建好**：BigQuery 匯出只從建立連結的那天開始累積，**不會回溯**過去的事件。越早接上，Day 05 之後的歸因分析就有越多真實資料可以用。剛建立連結時在 BigQuery 看不到 `analytics_<資源 ID>` 資料集是正常的，要等網站開始送事件、隔天左右才會出現；想立即確認埋設是否成功，請看 GA4 的即時報表，不要等 BigQuery。

匯出後的資料會在 Day 05 起與合成日誌對齊欄位，並在歸因分析篇章正式派上用場。

---

# 4. FinOps 成本防護實踐：三道防線體系

1. **第一道防線：善用 Google Cloud 每月免費額度**：Cloud Run 請求制計費每月有 18 萬 vCPU 秒、36 萬 GiB 秒與 200 萬次請求免費額度（以帳單帳戶彙總計算；asia-east1 屬第 1 級定價區域，超出免費額度後單價也較低）；`--source` 部署會用到 Cloud Build（每月 2,500 建置分鐘免費）與 Artifact Registry（每月 0.5 GB 儲存免費）。GA4 標準版與每日匯出不收費，綠界測試環境也不收費。
2. **第二道防線：架構層被動成本防護**：最少 0 個執行個體，沒人造訪就不計費；最多 2 個執行個體，擋住異常流量；部署腳本自動設定 Artifact Registry 清理政策，只保留最新 2 版映像檔，其餘超過 1 天的由背景作業定期刪除（不是立即生效），避免每次部署都累積儲存費。
3. **第三道防線：Cloud Billing 預算警報**：沿用 Day 03 設定的預算警報（新台幣帳戶 NT$ 300／美元帳戶 US$ 10：50% 早期預警、80% 警戒通知、100% 超支警告）。要注意，預算警報只會寄通知，不會自動停止服務。

💡 **小插曲：為什麼 Firebase 用不了免費的 Spark 方案？** 如果你和作者一樣，透過 Firebase 建立 GA4 資源，把 Firebase 加進 Day 03 的專案時會發現沒有 Spark 可選。原因是這個專案早就為了 BigQuery、Vertex AI 與 Cloud Run 連結了帳單帳戶，Firebase 會直接套用 Blaze（隨用隨付）方案；想用 Spark 就得解除帳單連結，Day 01–03 建好的資源也會跟著停擺。不過不必擔心：Blaze 方案的大部分產品仍享有與 Spark 相同的免費用量；而且依 Firebase 官方規定，要部署 Cloud Functions 本來就必須使用 Blaze。真正的成本防護從來不是方案名稱，而是「免費額度＋架構設計＋預算警報」這三道防線。本篇的 Live Demo 跑在 Cloud Run，沒有用到 Firebase Hosting 或 Cloud Functions，所以不需要安裝 Firebase CLI。

---

# 5. Cloud Shell 實戰演練：5 分鐘部署 Live Demo

## 5.1 事前準備

- **已完成 Day 03**：專案已連結帳單帳戶，且 `run.googleapis.com`、`cloudbuild.googleapis.com` 已啟用（沒做 Day 03 也可以，部署腳本會自動啟用必要 API）。
- **帳號權限**：建議使用專案「擁有者」帳號操作。部署腳本會為 Cloud Build 使用的預設服務帳號加上 `roles/run.builder`，這是 Cloud Run 原始碼部署的官方要求。
- **GA4 評估 ID（選填）**：到 GA4「管理 → 資料串流 → 網站」建立串流後，可以看到 `G-` 開頭的評估 ID；若是在 Firebase 註冊網頁應用程式，Firebase 會自動建立網站串流，評估 ID 在 Firebase「專案設定 → 一般 → 你的應用程式」也看得到。沒有也能先部署，之後再補。本文範例一律寫成 `G-XXXXXXXXXX`，請換成你自己的 ID。
- **GA4 參照連結排除**：建立網頁串流後，記得依 3.5 節把 `ecpay.com.tw` 加入「列出不適用的參照連結網址」。

## 5.2 路線 A｜懶人包：一行指令完成部署

在 Cloud Shell 先指定專案：

```bash
gcloud config set project YOUR_PROJECT_ID
```

接著貼上這一行：

```bash
cd ~ && if [ -d ai-driven-martech-pipeline/.git ]; then git -C ai-driven-martech-pipeline pull --ff-only; else git clone https://github.com/gminc/ai-driven-martech-pipeline.git; fi && bash ai-driven-martech-pipeline/scripts/deploy_live_demo.sh
```

已經有 GA4 評估 ID 的話，在指令最前面加上環境變數即可：

```bash
cd ~/ai-driven-martech-pipeline && GA_MEASUREMENT_ID=G-XXXXXXXXXX bash scripts/deploy_live_demo.sh
```

`deploy_live_demo.sh` 會自動完成：

- **啟用 API**：Cloud Run、Cloud Build、Artifact Registry。
- **補齊建置權限**：檢查預設服務帳號是否已有 `roles/run.builder`，沒有才授予。
- **原始碼部署**：`gcloud run deploy --source live-demo`，Cloud Build 依 `Dockerfile` 建置映像檔後部署到 `asia-east1`。
- **清理政策**：為 `cloud-run-source-deploy` 儲存庫設定映像檔自動清理。
- **輸出網址**：部署完成後印出服務網址與查詢付款日誌的指令。

看到「✅ Live Demo 已上線」就完成了。

## 5.3 路線 B｜逐步教學：理解每一個指令

### 步驟 1：在 Cloud Shell 本機跑測試

```bash
cd ~/ai-driven-martech-pipeline/live-demo
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest -q tests
```

- ✅ **成功的樣子**：看到 `20 passed`。其中包含以綠界官方範例驗證 CheckMacValue、竄改金額必須驗章失敗、`ReturnURL` 只有簽章正確才回 `1|OK`、自行算出簽章但金額不符也不送 `purchase`、活動頁帶出正確的 `promotion_id` 等測試。

### 步驟 2：用模擬結帳先看畫面

```bash
PAYMENT_MODE=simulate python main.py
```

點 Cloud Shell 右上角的「網頁預覽 → 透過通訊埠 8080 預覽」，就能看到商品頁。這裡使用模擬結帳，因為 Cloud Shell 的預覽網址需要登入，綠界伺服器無法把付款通知送進來。看完按 `Ctrl + C` 停止。

### 步驟 3：啟用 API 與建置權限

```bash
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
PROJECT_NUMBER="$(gcloud projects describe "$(gcloud config get-value project)" --format='value(projectNumber)')"
gcloud projects add-iam-policy-binding "$(gcloud config get-value project)" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/run.builder" --condition=None
```

Cloud Run 原始碼部署預設由 Compute Engine 預設服務帳號執行 Cloud Build，需要「Cloud Run Builder」角色才能建置與推送映像檔。

### 步驟 4：部署到 Cloud Run

```bash
gcloud run deploy martech-live-demo \
  --source ~/ai-driven-martech-pipeline/live-demo \
  --region asia-east1 \
  --allow-unauthenticated \
  --min-instances 0 --max-instances 2 \
  --cpu 1 --memory 512Mi \
  --update-env-vars PAYMENT_MODE=ecpay
```

- `--source`：直接上傳原始碼，由 Cloud Build 依 `Dockerfile` 建置，不必自己裝 Docker。第一次執行會詢問是否建立 `cloud-run-source-deploy` 儲存庫，輸入 `Y` 即可。
- `--allow-unauthenticated`：展示站需要公開瀏覽，綠界也必須能呼叫 `ReturnURL`。
- `--min-instances 0 --max-instances 2`：閒置不計費、流量有上限。

- ✅ **成功的樣子**：最後出現 `Service URL: https://martech-live-demo-專案編號.asia-east1.run.app`

Cloud Run 會同時給服務兩個網址：含專案編號、可預測的 `*.run.app` 網址，以及含隨機碼的 `*.a.run.app` 網址，兩個都能用。若不想在公開文章中露出專案編號，可以分享 `*.a.run.app` 那個（`deploy_live_demo.sh` 預設就是印出這個）。

## 5.4 驗證部署成果

### 健康檢查

```bash
SERVICE_URL="$(gcloud run services describe martech-live-demo --region asia-east1 --format='value(status.url)')"
curl -s "${SERVICE_URL}/health"
```

- ✅ **成功的樣子**：回傳 `{"status":"ok"}`

### 跑一次完整的測試結帳

1. 打開服務網址，挑一款商品按「前往結帳」。
2. 在綠界測試付款頁輸入測試卡號 `4311-9522-2222-2222`，有效期限填任一未來月份，CVV 任意三碼。
3. 3D 驗證頁面輸入 `1234`。
4. 看到網站的「謝謝你的訂購」頁面，就代表 `OrderResultURL` 驗章成功。

### 確認付款通知有進 Cloud Logging

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND jsonPayload.event="ecpay_payment_notify"' --limit 5 --format json
```

- ✅ **成功的樣子**：看到 `"verified": true`、`"rtn_code": "1"`，以及剛才的訂單編號與金額。

### 確認 GA4 事件

設定了 `GA_MEASUREMENT_ID` 的話，打開 GA4「報表 → 即時總覽」，從首頁點進商品頁再結帳，應該能依序看到 `view_item_list`、`select_item`、`view_item`、`begin_checkout`、`purchase`；帶著 `?utm_source=demo&utm_medium=test&utm_campaign=day04` 進站，還能順便驗證來源有沒有被記到綠界的 `CustomField4`。想逐筆檢查參數可以用 GA4 的 DebugView，但一般瀏覽不會出現在 DebugView，需要先安裝 Google Analytics Debugger 擴充功能，或在 gtag 設定中加上 `debug_mode: true`。BigQuery 每日匯出的第一張事件表，通常要到隔天才會出現。

## 5.5 不用了？指令全部清除

```bash
gcloud run services delete martech-live-demo --region asia-east1 --quiet
gcloud artifacts repositories delete cloud-run-source-deploy --location asia-east1 --quiet
gcloud storage ls | grep run-sources
```

前兩行刪除服務與映像檔儲存庫；第三行列出原始碼部署時自動建立、名稱以 `run-sources-` 開頭的 Cloud Storage 儲存庫（bucket），確認後可用 `gcloud storage rm -r gs://儲存庫名稱` 一併刪除。GA4 資源與 BigQuery 連結則到 GA4 管理介面中移除。

## 5.6 常用指令速查

- `gcloud run services list`：列出所有 Cloud Run 服務
- `gcloud run services describe 服務名稱 --region asia-east1`：查看服務設定與網址
- `gcloud run services logs read 服務名稱 --region asia-east1`：查看最近的服務日誌
- `gcloud run services update 服務名稱 --region asia-east1 --update-env-vars GA_MEASUREMENT_ID=G-XXXXXXXXXX`：只更新環境變數，不重新建置（注意：`--set-env-vars` 會整組覆蓋，沒列到的變數會被清掉；`deploy_live_demo.sh` 因此使用 `--update-env-vars`）
- `gcloud artifacts docker images list asia-east1-docker.pkg.dev/專案ID/cloud-run-source-deploy`：查看儲存庫中的映像檔

---

# 6. 工程實務避坑指南（Gotchas & Best Practices）

1. **Cloud Run 後面的網址是 http 還是 https？** Cloud Run 前面有 Google Front End 代理，Flask 直接用 `url_for(..., _external=True)` 可能產生 `http://` 開頭的回呼網址。本專案用 Werkzeug 的 `ProxyFix(x_proto=1)` 只信任代理送來的協定標頭，確保送給綠界的 `ReturnURL` 是 `https://`；刻意不信任 `X-Forwarded-Host`，避免有人自帶標頭把回呼網址改成別的網域。
2. **時區一定要寫死台北**：Cloud Run 容器預設是 UTC，直接用 `datetime.now()` 產生的 `MerchantTradeDate` 會差 8 小時。程式一律使用 `UTC+8` 的時區物件。
3. **ReturnURL 必須公開且回應 `1|OK`**：綠界伺服器沒收到 `1|OK` 會視為通知失敗並重送。所以 Cloud Shell 網頁預覽、需要登入的網址都收不到付款通知，本機測試請改用 `PAYMENT_MODE=simulate`。
4. **訂單編號不能重複**：同一個 `MerchantTradeNo` 在綠界不能重送，而且大家共用同一組公開測試特店。本專案用「時間到秒＋4 碼隨機碼」產生，降低撞號機率。
5. **`OrderResultURL` 與 `ClientBackURL` 同時設定時以 `OrderResultURL` 為主**：付款完成後綠界會直接把結果 POST 回我們的感謝頁，因此感謝頁一定要驗章，不能只看網址就判定付款成功。
6. **剛授予的 IAM 角色不會馬上生效**：第一次部署時，腳本才剛幫預設服務帳號加上 `roles/run.builder`，若立刻建置，可能出現 `PERMISSION_DENIED: Build failed because the default service account is missing required IAM permissions`。作者實測就遇到這個錯誤，所以腳本在授權後會先等 90 秒；手動操作時，稍等一兩分鐘再重新執行部署即可。
7. **健康檢查路徑不要用 `/healthz`**：Kubernetes 慣用的 `/healthz` 在 Cloud Run 上會被平台攔截，直接回 Google 的 404，根本到不了你的程式。官方文件說明部分以 `z` 結尾的路徑是保留路徑，建議避開所有以 `z` 結尾的路徑。作者第一次部署時健康檢查就是這樣失敗的，後來改成 `/health`。
8. **GA4 事件不能卡住結帳**：`event_callback` 在 GA 被攔截時永遠不會被呼叫，一定要搭配保底計時器。
9. **金流網域要排除參照連結**：沒有把 `ecpay.com.tw` 加入 GA4「列出不適用的參照連結網址」，所有購買都會被歸給綠界，歸因分析直接失真。
10. **公開測試金鑰不防偽**：驗章只證明資料完整，金額與訂單編號仍要在伺服器端重新檢查。

---

# 7. 總結與明日預告

今天我們用一個 Cloud Run 服務，把「商品瀏覽 → 開始結帳 → 綠界測試付款 → 驗章 → 購買事件」整條即時資料流打通了。前端事件進 GA4、付款紀錄進 Cloud Logging，兩邊用同一個訂單編號與 GA `client_id` 對帳，軌道 A 的即時驗證正式上線。

**明日預告**：Day 05《雙軌資料工程：電商大數據合成器》，我們將用 Python 模擬 90 天、符合真實電商統計分佈的跨通路日誌，並沿用今天的商品 ID 與事件欄位，讓合成資料與 Live Demo 的真實事件能無縫對齊！
