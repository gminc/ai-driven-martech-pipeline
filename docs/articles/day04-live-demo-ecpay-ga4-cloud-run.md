# 1. 前言：沒有真實點擊，歸因分析只是紙上談兵

Day 01 提過本系列採用「雙軌資料架構」：軌道 B 用合成器灌入 50 萬筆歷史日誌撐起分析規模，軌道 A 則要證明資料流是真的通，Day 03 已經用 Terraform 把 GCP 環境與 BigQuery 資料倉儲建好，但那座倉儲目前是空的，今天要做的就是替它接上第一條真實的資料來源。

很多 MarTech 教學一開始就拿現成的 CSV 做歸因，但實務上最常出問題的往往不是模型而是更前面的三件事：

- 事件根本沒送出去：按鈕改版後追蹤碼失效、廣告攔截器擋掉追蹤程式，報表上的轉換數默默變少卻沒有人發現
- 金額與訂單對不起來：前端送出的購買金額被竄改或重複計算，GA4 的營收和金流後台永遠差一截
- 結帳流程卡在追蹤程式：為了等追蹤事件送完使用者按下結帳後要多等好幾秒，甚至因為 GA 被擋而卡住

這三件事有個共同點，就是它們都不會報錯，報表照樣有數字但是數字是錯的，所以第 4 天先搭一個真的可以點擊、可以結帳的極簡電商網站，把事件追蹤與金流串起來，讓後面每一天的分析都有一條真實資料可以對照。

今日核心目標：

1. 以 Cloud Run 單一服務部署一個有品牌故事、商品詳情頁與活動頁的紡織品小店 Live Demo（襪子、毛巾、浴巾與一組入門組合，共 5 款）
2. 串接綠界 ECPay 測試環境，由伺服器計算金額與 CheckMacValue，並驗證付款結果
3. 完成 GA4 電子商務事件追蹤：`view_item_list`、`view_item`、`begin_checkout`、`purchase`，並設定每日匯出到 BigQuery

今天產生的事件不是做完就結束，Day 05 的合成器會沿用同一組商品 ID 與事件欄位，讓合成資料與真實事件對得起來；Day 07 的多觸點歸因則直接拿今天匯出到 BigQuery 的事件表當輸入，今天等於是在替後面兩週的分析鋪第一段軌道。

> **關於 Stripe 與 Firebase 的說明**：Day 01 與 Day 03 原本規劃「Firebase Hosting / Cloud Functions ＋ Stripe Test Mode」。實作時發現兩件事：
>
> - Stripe 目前的支援清單沒有台灣，台灣團隊要用 Stripe 必須另外走申請流程，目前還在進行中，為了讓讀者今天就能完整跑完結帳，本篇改用台灣讀者更熟悉、且提供公開測試特店的綠界 ECPay 測試環境，若 30 天賽期內 Stripe 流程通過，會再補充 Stripe 版本。
> - 頁面、結帳簽章與付款結果通知其實只需要一個小小的 Python 服務，用 Cloud Run 單一服務就能全部處理，也和系列後段的 Cloud Run AI 助理共用同一套部署方式，所以本篇不另外拆 Hosting 與 Functions。

> **Live Demo 網址**：[織日常](https://martech-live-demo-enki4czjsa-de.a.run.app) 為技術展示，品牌與商品皆為示範用途，使用綠界測試環境，不會實際扣款，商品也不會出貨。

---

# 2. 系統架構全景與設計理念

![Day 04 Live Demo 站部署架構圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day04-live-demo-architecture.svg)

💡 **核心工程理念**：

1. **一個容器搞定前後台**：Cloud Run 上只跑一個 Flask 服務，同時負責商品頁、結帳簽章、付款結果通知與感謝頁，不需要另外架資料庫或 Functions，部署、權限與成本都只有一份
2. **金額只相信伺服器**：價格寫在伺服器端的 `products.json`，前端只能傳商品 ID、數量與尺寸，三者都要通過白名單驗證，金額與簽章一律在後台計算，使用者改網址也改不了價錢
3. **事件與金流分工**：瀏覽器上的 `gtag` 事件直送 GA4 負責行為分析，綠界的付款結果通知打到伺服器寫進 Cloud Logging 負責付款紀錄，兩邊用同一個訂單編號對帳
4. **沒人造訪就不收費**：Cloud Run 最少 0 個執行個體、請求制計費，網站閒置時費用為零；最多 2 個執行個體，避免被灌流量時燒錢

這次搭建的網站具備完整的電商動線，今天先專注在伺服器端的金流驗證與電商事件，其餘頁面則是為了後續實戰預留資料：Day 07 的多觸點歸因需要完整的瀏覽與結帳路徑，Day 18 也需要實際的 Landing Page 來比對廣告素材的一致性。

站台的大致樣貌如下：

| 路徑 | 頁面 | 這一頁在後面幾天的用途 |
| --- | --- | --- |
| `/` | 首頁：全幅主視覺、商品列表、當期專案 | 列表曝光與商品點擊 |
| `/product/<商品 ID>` | 商品詳情：多圖、材質規格、洗滌方式 | 商品檢視、Day 14 素材特徵抽取 |
| `/about` | 品牌故事、三大工藝主張、常見問題 | 瀏覽深度、跳出率對照 |
| `/lp/<活動代號>` | 活動頁面 | Day 18 Landing Page 與廣告素材一致性 |
| `/checkout/<商品 ID>` | 產生綠界簽章表單 | 結帳事件 |
| `/ecpay/return`、`/ecpay/result` | 付款結果通知與感謝頁（僅接受 POST，手動用瀏覽器開會得到 405） | 購買事件與付款紀錄 |
| `/health` | 健康檢查，回 `{"status":"ok"}` | 部署驗證（為什麼不是 `/healthz` 見第 6 章） |

商品圖的部分，這是一個虛構品牌沒有實拍素材可用，所以商品與情境照都是在本機用 [Pollinations.ai](https://pollinations.ai/)（Flux 模型，免金鑰）和 Gemini 生成後壓成 JPEG 放進 `static/img/`，商品與情境照統一 886 × 615、38 到 100 KB，另有兩張全幅主視覺（桌機 1920 × 1072、手機 900 × 502），整個資料夾合計約 1 MB，沒有任何外部圖床，圖片出處標在每一頁最上方的展示站說明列，Day 14 要做素材特徵抽取時，這種同一組提示詞產出的圖變異度偏低，到時候會再補一批風格差異更大的素材。

程式碼全部放在儲存庫的 `live-demo/` 目錄，本篇只挑影響資料正確性的部分說明，完整的參數表、簽章演算法與測試重點放在該目錄的 `README.md`：

```text
live-demo/
├── main.py              # Flask 路由：首頁、商品頁、活動頁、結帳、付款結果
├── ecpay.py             # 綠界參數組裝與 CheckMacValue（純函式）
├── catalog.py           # 讀取 products.json：商品、工藝主張、活動
├── products.json        # 品牌文案、5 款商品、2 檔活動
├── templates/           # base 版型、首頁、商品頁、品牌頁、活動頁、感謝頁
├── static/analytics.js  # GA4 電子商務事件追蹤
├── static/img/          # 商品與情境照片，無外部資源
├── tests/               # pytest：官方範例驗章、路由與防竄改測試
└── Dockerfile           # python:3.12-slim + gunicorn
```

---

# 3. 核心技術深度拆解

## 3.1 商品目錄與伺服器端定價

`products.json` 一次定義品牌文案、三大工藝主張、5 款商品與 2 檔活動。價格、品名與可選尺寸全部寫在這裡，前端只能傳商品 ID、數量與尺寸三個值。

以下為節錄，完整欄位見 `products.json`：

```json
{
  "id": "sock-towel-training",
  "name": "厚底毛巾訓練襪",
  "price": 260,
  "image": "img/sock-towel.jpg",
  "size_options": ["M 24-26 cm", "L 26-28 cm"]
}
```

`size_options` 是詳情頁上唯一可以挑的商品變體。這裡刻意做尺寸而不做顏色，因為顏色一旦可選，圖片就得跟著換，對一個只想驗證資料流的展示站是不必要的成本；尺寸可以共用同一組照片，卻一樣能產生「同商品、不同變體」的事件，剛好對應 GA4 電子商務的 `item_variant` 欄位。

驗證只信伺服器端。`Product.resolve_size()` 只接受清單內的字串，網址上塞任何自己寫的尺寸都會退回預設值，`catalog.py` 在載入時就檢查商品 ID 不可重複、活動代號不可重複、活動指到的商品必須存在、價格必須為正整數、每個商品至少要有一個不重複的尺寸選項；數量只接受 1 到 5，其他任何輸入一律視為 1，這些檢查放在啟動時，設定寫錯會讓容器直接起不來，而不是等到使用者結帳才出錯。

## 3.2 綠界測試金流：付款結果怎麼回到伺服器

![綠界 ECPay 測試金流與驗章流程圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day04-ecpay-checkmac-flow.svg)

綠界的測試環境提供公開測試特店（特店編號 3002607），不用申請就能跑完整個刷卡流程。完整流程如下：

1. 使用者按下「前往結帳」，瀏覽器發送 `GET /checkout/<商品 ID>?qty=2` 請求
2. 伺服器查定價、算總額、產生 20 碼內不重複的訂單編號（例如 `DM20260918093015A1B2`），組好參數並計算 `CheckMacValue`
3. 伺服器回傳一段包含隱藏表單的 HTML，並由前端自動提交
4. 表單自動 POST 到綠界測試環境 `https://payment-stage.ecpay.com.tw/Cashier/AioCheckOut/V5`
5. 在綠界頁面用測試卡付款
6. 綠界伺服器 POST 付款結果到 `ReturnURL`（`/ecpay/return`），我們驗章後回應 `1|OK`
7. 綠界把使用者瀏覽器導回 `OrderResultURL`（`/ecpay/result`），同樣帶著付款結果與簽章

這裡有兩條回程，用途不一樣。`ReturnURL` 是伺服器對伺服器的**付款結果通知**，是可信的帳務來源，收到後寫進 Cloud Logging，`OrderResultURL` 是**付款完成導回**，只是把使用者的瀏覽器帶回感謝頁，而感謝頁是購買事件送出的地方，這個分工決定了一件事：感謝頁絕對不能只看網址就認定付款成功。

`CheckMacValue` 是綠界的簽章欄位，把所有參數按字母排序後接上 HashKey 與 HashIV，做 URL 編碼再取 SHA256，它證明資料在傳輸過程中沒有被改動，但公開測試特店的金鑰人人可得，任何人都能自己算出一個「正確」的簽章來偽造一筆付款成功，所以伺服器端還要再加兩道檢查：金額必須等於商品定價乘以數量、訂單編號的格式與時間必須合理。三道都過才輸出購買資料，演算法細節、參數完整清單與 `.NET` 編碼規則寫在 `live-demo/README.md`，這裡不展開。

自訂欄位是把金流與行為資料接起來的關鍵，綠界給四個欄位，本專案這樣用：

| 欄位 | 內容 | 用途 |
| --- | --- | --- |
| `CustomField1` | 商品 ID | 回程時還原買了什麼 |
| `CustomField2` | 數量與尺寸索引，以直線符號相接，例如 `2\|1` | 還原數量與變體 |
| `CustomField3` | GA4 `client_id` | 把這筆付款對回 GA4 的訪客 |
| `CustomField4` | 進站來源、媒介與活動，例如 `google\|cpc\|autumn` | 把這筆付款對回廣告來源 |

`CustomField3` 與 `CustomField4` 是整篇文章最重要的兩格，有了它們，Cloud Logging 裡的每一筆付款紀錄都能對應到 GA4 的哪一個訪客、來自哪一個廣告活動，Day 07 的多觸點歸因才有辦法把「廣告花費」和「實際成交」接起來。

`CustomField2` 放的是尺寸的索引而不是「加大 80x160 cm」這串中文，因為自訂欄位的字串會被納入 `CheckMacValue`，而驗章是拿回傳的字面值重新計算，只要金流端在任何一個環節對中文或半形空白做過轉換與正規化，簽章就完全對不起來。這會導致整筆付款在感謝頁被判定失敗，而且極不容易被發現。改用純 ASCII 數字不但沒有這個風險，也不可能超過 50 字元的長度上限。

## 3.3 GA4 電子商務事件追蹤

![GA4 電子商務事件漏斗與五個追蹤點](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day04-ga4-ecommerce-event-flow.svg)

GA4 的電子商務事件有一套建議規格，照著送的好處是報表會自動認得，不用另外設定自訂維度。本站送出的事件如下：

| 事件 | 觸發時機 | 關鍵參數 |
| --- | --- | --- |
| `view_item_list` | 任何有商品列表的頁面載入 | `item_list_id`、`item_list_name`、`items` |
| `select_item` | 點擊商品卡片 | `item_list_id`、`item_list_name`、`items` |
| `view_item` | 商品詳情頁載入 | `currency`、`value`、`items` |
| `view_promotion` / `select_promotion` | 活動頁載入 / 點擊活動頁上的按鈕 | `promotion_id`、`promotion_name`、`creative_name`、`creative_slot` |
| `begin_checkout` | 按下「前往結帳」 | `value`＝定價 × 數量、`items[].quantity`、`items[].item_variant` |
| `purchase` | 驗章成功的感謝頁 | `transaction_id`、`value`、`currency`、`items` |

`item_list_id` 會隨列表位置變化，本站有三種取值：首頁的 `home_all`、活動頁的 `lp_<活動代號>`、商品頁下方相關商品的 `related_<商品 ID>`，之後就能回答「從活動頁點進去的人最後買了什麼」這種問題，`view_promotion` 與 `creative_name` 則是 Day 18 比對廣告素材與 Landing Page 的接點。

**變體要跟著實際勾選走：** `begin_checkout` 的 `item_variant` 讀的是使用者當下勾選的尺寸，不是商品頁載入時的預設值；`purchase` 的 `item_variant` 則是從綠界回傳的自訂欄位還原出來的。兩邊對得起來，後面才能做「哪個尺寸賣得好、哪個尺寸退換貨多」這種變體維度的分析。

**購買事件一定要由伺服器決定：** 感謝頁的 `purchase` 不是前端想送就送，而是伺服器驗完章、確認 `RtnCode` 為 1、金額等於定價乘以數量、訂單編號格式與時間合理之後，才把購買資料以 JSON 輸出到頁面上，前端讀到才送。任何一項不過就不輸出，前端自然也送不出去。這道設計擋掉的是最常見的營收汙染：有人直接打開感謝頁網址，或重複整理頁面，讓 GA4 多記好幾筆根本不存在的訂單。

**訪客識別要在跳轉前拿到：** 使用者按下結帳後會離開本站前往綠界，所以 `client_id` 必須在跳轉發生之前取得並寫進表單：

```javascript
window.gtag("get", config.gaId, "client_id", function (clientId) {
  form.querySelector("input[name=cid]").value = clientId || "";
  window.gtag("event", "begin_checkout", {
    currency: config.currency,
    value: buyItem.price * qty,
    items: [checkoutItem],
    event_callback: go          // 事件送出後才跳轉
  });
});
window.setTimeout(go, 1200);    // GA 被擋掉時，最多等 1.2 秒也要讓使用者結帳
```

`event_callback` 確保事件真的送出去才跳轉，但它在 GA 被廣告攔截器擋掉時永遠不會被呼叫，所以一定要搭配保底計時器。**追蹤是為了生意服務，不能反過來擋住生意。** 另外實際程式碼在這段之前還有一道 `if (!enabled)` 判斷：沒有設定 GA4 評估 ID 時 `window.gtag` 根本不存在，少了這道判斷，攔截表單之後的呼叫會直接丟出例外，連保底計時器都來不及註冊，結帳就永遠送不出去。

**廣告來源記在瀏覽器端：** 訪客帶著 `utm_` 參數進站時，`analytics.js` 就把來源寫進 `sessionStorage`，同一個工作階段內以最後一次為準。結帳時再塞進表單的隱藏欄位送回伺服器，伺服器只接受 `[A-Za-z0-9_.|-]` 且長度 50 以內的字串，其餘一律視為空值。

## 3.4 GA4 每日匯出到 BigQuery

GA4 報表介面適合看趨勢，但做歸因需要的是逐筆事件，GA4 標準版提供免費的每日匯出，把原始事件送進 BigQuery，這是軌道 A 與 Day 03 建好的資料倉儲接上的地方。

設定位置在 GA4「管理 → 產品連結 → BigQuery 連結」，建立連結需要兩個權限：GA4 資源的編輯者以上，以及 Google Cloud 專案的擁有者（或官方列出的那組最小權限），設定時有三個選擇會影響後面的成本與資料量：

- **資料位置**：選 `US` 多區域，與 Day 03 建立的 `martech_dw` 對齊，BigQuery 不能跨區域 JOIN，這裡選錯後面每一天都要繞路
- **匯出頻率**：只勾「每日」，串流匯出是另外計費的，本系列不需要即時
- **是否包含廣告 ID**：本系列不需要，維持關閉

匯出後的事件會落在 `analytics_<資源 ID>` 資料集，資料表名稱是 `events_YYYYMMDD`，實際用得到的欄位是這幾個：

| 欄位 | 內容 | 之後怎麼用 |
| --- | --- | --- |
| `event_name` | 事件名稱 | 篩出 `purchase`、`begin_checkout` 等 |
| `event_timestamp` | 微秒級時間戳 | Day 07 排出使用者的接觸順序 |
| `user_pseudo_id` | 對應 GA4 的 `client_id` | 與綠界 `CustomField3` 對帳 |
| `event_params` | 巢狀的參數陣列 | 取出 `item_list_id`、`transaction_id` |
| `items` | 巢狀的商品陣列 | 取出商品 ID、變體與金額 |
| `traffic_source` | 來源、媒介、活動 | 與 `CustomField4` 交叉驗證 |

`event_params` 與 `items` 都是巢狀結構，查詢時要用 `UNNEST`，這是 GA4 匯出資料最容易卡住新手的地方，Day 05 會一併處理。

**有一個設定不做，今天的資料就是錯的：** 付款完成後瀏覽器是從綠界的網域被導回感謝頁，GA4 預設會把這次造訪當成「從 `payment-stage.ecpay.com.tw` 推薦過來」，開一個新的工作階段，結果購買就被歸功給綠界而不是原本帶來訂單的廣告。解法是到 GA4「管理 → 資料串流 → 網站 → 點選你的串流 → 進行代碼設定 → 在設定區塊點『全部顯示』→ 列出不適用的參照連結網址」，新增一個條件，網域填入 `ecpay.com.tw` 後儲存，任何有第三方金流的網站都會踩到這個坑，而且踩到了報表還是有數字，只是全部歸錯。

最後兩個提醒：匯出不會回填歷史資料，連結建立當天以前的事件不會出現；第一張事件表通常要到隔天才會生成，所以今天設定完不會馬上看到東西，先用 GA4 的即時報表確認事件有進來就好。

---

# 4. FinOps 成本防護實踐：三道防線體系

1. **第一道防線**  
   **善用 Google Cloud 每月免費額度**：Cloud Run 請求制計費每月有 18 萬 vCPU 秒、36 萬 GiB 秒與 200 萬次請求免費額度（以帳單帳戶彙總計算，asia-east1 屬第 1 級定價區域，超出免費額度後單價也較低）；`--source` 部署會用到 Cloud Build（每月 2,500 建置分鐘免費）與 Artifact Registry（每月 0.5 GB 儲存免費），GA4 標準版與每日匯出不收費，綠界測試環境也不收費
2. **第二道防線**  
   **架構層被動成本防護**：最少 0 個執行個體，沒人造訪就不計費；最多 2 個執行個體，擋住異常流量；部署腳本自動設定 Artifact Registry 清理政策，只保留最新 2 版容器映像檔，其餘超過 1 天的由背景作業定期刪除，避免每次部署都累積儲存費
3. **第三道防線**  
   **Cloud Billing 預算警報**：沿用 Day 03 設定的預算警報（新台幣帳戶 NT$ 300／美元帳戶 US$ 10：50% 早期預警、80% 警戒通知、100% 超支警告），要注意，預算警報只會寄通知，不會自動停止服務

💡 **小插曲：為什麼 Firebase 用不了免費的 Spark 方案？** 如果你和我一樣透過 Firebase 建立 GA4 資源，把 Firebase 加進 Day 03 的專案時會發現沒有 Spark 可選。原因是這個專案早就為了 BigQuery、Vertex AI 與 Cloud Run 連結了帳單帳戶，Firebase 會直接套用 Blaze 隨用隨付方案；想用 Spark 就得解除帳單連結，Day 01 到 03 建好的資源也會跟著停擺。不過不必擔心，Blaze 方案的大部分產品仍享有與 Spark 相同的免費用量，而且依 Firebase 官方規定，要部署 Cloud Functions 本來就必須使用 Blaze。真正的成本防護從來不是方案名稱，而是免費額度、架構設計與預算警報這三道防線。本篇的 Live Demo 跑在 Cloud Run，沒有用到 Firebase Hosting 或 Cloud Functions，所以不需要安裝 Firebase CLI。

---

# 5. Cloud Shell 實戰演練：5 分鐘部署 Live Demo

## 5.1 事前準備

- **已完成 Day 03**：專案已連結帳單帳戶，且 `run.googleapis.com`、`cloudbuild.googleapis.com` 已啟用，沒做 Day 03 也可以，部署腳本會自動啟用必要 API
- **帳號權限**：建議使用專案擁有者帳號操作，部署腳本會為 Cloud Build 使用的預設服務帳號加上 `roles/run.builder`，這是 Cloud Run 原始碼部署的官方要求
- **GA4 評估 ID（選填）**：到 GA4「管理 → 資料串流 → 網站」建立串流後可以看到 `G-` 開頭的評估 ID，沒有也能先部署，之後再補，本文範例一律寫成 `G-XXXXXXXXXX`，請換成你自己的 ID
- **GA4 參照連結排除**：建立網頁串流後，記得依 3.4 節把 `ecpay.com.tw` 加入「列出不適用的參照連結網址」

以下提供兩條路線，兩條路線的結果完全相同，可以依需求選擇：

**路線 A**：喜歡先看到成果的讀者，可以直接複製一行指令跑完整個部署

**路線 B**：想要理解每個步驟的讀者，可以跟著逐步教學一個指令一個指令操作

## 5.2 路線 A｜懶人包：一行指令完成部署

在 Cloud Shell 先指定專案：

```shell
gcloud config set project YOUR_PROJECT_ID
```

接著貼上這一行：

```shell
cd ~ && if [ -d ai-driven-martech-pipeline/.git ]; then git -C ai-driven-martech-pipeline pull --ff-only; else git clone https://github.com/gminc/ai-driven-martech-pipeline.git; fi && bash ai-driven-martech-pipeline/scripts/deploy_live_demo.sh
```

已經有 GA4 評估 ID 的話，在指令最前面加上環境變數即可：

```shell
cd ~/ai-driven-martech-pipeline && GA_MEASUREMENT_ID=G-XXXXXXXXXX bash scripts/deploy_live_demo.sh
```

`deploy_live_demo.sh` 會依序啟用 Cloud Run、Cloud Build 與 Artifact Registry 三個 API，檢查並補齊預設服務帳號的 `roles/run.builder` 權限，用 `gcloud run deploy --source` 把原始碼交給 Cloud Build 建置後部署到 `asia-east1`，設定映像檔清理政策，最後印出服務網址與查詢付款日誌的指令。看到「✅ Live Demo 已上線」就完成了。

## 5.3 路線 B｜逐步教學：理解每一個指令

### 步驟 1：在 Cloud Shell 本機跑測試

```shell
cd ~/ai-driven-martech-pipeline/live-demo
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest -q tests
```

- ✅ **成功的樣子**：看到 `26 passed`，逐項說明見 `live-demo/README.md`

### 步驟 2：用模擬結帳先看畫面

```shell
PAYMENT_MODE=simulate python main.py
```

點 Cloud Shell 右上角的「網頁預覽 → 透過通訊埠 8080 預覽」就能看到商品頁。這裡使用模擬結帳，因為 Cloud Shell 的預覽網址需要登入，綠界伺服器無法把付款結果通知送進來。看完按 `Ctrl + C` 停止。

### 步驟 3：啟用 API 與建置權限

```shell
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
PROJECT_NUMBER="$(gcloud projects describe "$(gcloud config get-value project)" --format='value(projectNumber)')"
gcloud projects add-iam-policy-binding "$(gcloud config get-value project)" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/run.builder" --condition=None
```

Cloud Run 原始碼部署預設由 Compute Engine 預設服務帳號執行 Cloud Build，需要 Cloud Run Builder 角色才能建置與推送映像檔。

### 步驟 4：部署到 Cloud Run

```shell
gcloud run deploy martech-live-demo \
  --source ~/ai-driven-martech-pipeline/live-demo \
  --region asia-east1 \
  --allow-unauthenticated \
  --min-instances 0 --max-instances 2 \
  --cpu 1 --memory 512Mi \
  --update-env-vars PAYMENT_MODE=ecpay
```

`--source` 直接上傳原始碼由 Cloud Build 依 `Dockerfile` 建置，不必自己裝 Docker，第一次執行會詢問是否建立 `cloud-run-source-deploy` 儲存庫，輸入 `Y` 即可。`--allow-unauthenticated` 是必要的，因為展示站需要公開瀏覽，綠界也必須能呼叫 `ReturnURL`。

- ✅ **成功的樣子**：最後出現 `Service URL: https://martech-live-demo-專案編號.asia-east1.run.app`

Cloud Run 會同時給服務兩個網址：含專案編號、可預測的 `*.run.app` 網址，以及含隨機碼的 `*.a.run.app` 網址，兩個都能用。若不想在公開文章中露出專案編號，可以分享 `*.a.run.app` 那個，`deploy_live_demo.sh` 預設就是印出這個。

## 5.4 驗證部署成果

```shell
SERVICE_URL="$(gcloud run services describe martech-live-demo --region asia-east1 --format='value(status.url)')"
curl -s "${SERVICE_URL}/health"
```

- ✅ **成功的樣子**：回傳 `{"status":"ok"}`

接著跑一次完整的測試結帳：打開服務網址挑一款商品按「前往結帳」，在綠界測試付款頁輸入測試卡號 `4311-9522-2222-2222`，有效期限填任一未來月份，CVV 任意三碼，3D 驗證頁面輸入 `1234`。看到網站的「謝謝你的訂購」頁面就代表驗章成功。

確認付款結果通知有進 Cloud Logging：

```shell
gcloud logging read 'resource.type="cloud_run_revision" AND jsonPayload.event="ecpay_payment_notify"' --limit 5 --format json
```

- ✅ **成功的樣子**：看到 `"verified": true`、`"rtn_code": "1"`，以及剛才的訂單編號與金額

設定了 `GA_MEASUREMENT_ID` 的話，打開 GA4「報表 → 即時總覽」，從首頁點進商品頁再結帳，應該能依序看到 `view_item_list`、`select_item`、`view_item`、`begin_checkout`、`purchase`。帶著 `?utm_source=demo&utm_medium=test&utm_campaign=day04` 進站，還能順便驗證來源有沒有被記到綠界的 `CustomField4`。想逐筆檢查參數可以用 GA4 的 DebugView，但一般瀏覽不會出現在 DebugView，需要先安裝 Google Analytics Debugger 擴充功能，或在 gtag 設定中加上 `debug_mode: true`。

## 5.5 不用了？指令全部清除

```shell
gcloud run services delete martech-live-demo --region asia-east1 --quiet
gcloud artifacts repositories delete cloud-run-source-deploy --location asia-east1 --quiet
gcloud storage ls | grep run-sources
```

前兩行刪除服務與映像檔儲存庫；第三行列出原始碼部署時自動建立、名稱以 `run-sources-` 開頭的 Cloud Storage 儲存庫，確認後可用 `gcloud storage rm -r gs://儲存庫名稱` 一併刪除。GA4 資源與 BigQuery 連結則到 GA4 管理介面中移除。

## 5.6 常用指令速查

- `gcloud run services list`：列出所有 Cloud Run 服務
- `gcloud run services describe 服務名稱 --region asia-east1`：查看服務設定與網址
- `gcloud run services logs read 服務名稱 --region asia-east1`：查看最近的服務日誌
- `gcloud run services update 服務名稱 --region asia-east1 --update-env-vars GA_MEASUREMENT_ID=G-XXXXXXXXXX`：只更新環境變數不重新建置，注意 `--set-env-vars` 會整組覆蓋，沒列到的變數會被清掉，`deploy_live_demo.sh` 因此使用 `--update-env-vars`
- `gcloud artifacts docker images list asia-east1-docker.pkg.dev/專案ID/cloud-run-source-deploy`：查看儲存庫中的映像檔

---

# 6. 工程實務避坑指南

前四個是會讓資料默默出錯的坑，也是本篇最想留給讀者的部分。

1. **金流網域一定要排除參照連結**：沒有把 `ecpay.com.tw` 加入 GA4「列出不適用的參照連結網址」，所有購買都會被歸功給金流商，報表照樣有數字，只是廣告成效全部歸零，任何有第三方金流的網站都會踩到
2. **公開測試金鑰不防偽造**：驗章只證明資料完整，不證明來源可信，公開測試特店的金鑰人人可得，所以金額與訂單編號一定要在伺服器端重新檢查過才輸出購買事件
3. **自訂欄位只放 ASCII**：放中文或半形空白，只要金流端做過任何正規化，整筆付款就會被判定失敗，而且不會有任何錯誤提示，理由見 3.2 節
4. **GA4 事件不能卡住結帳**：`event_callback` 在 GA 被攔截時永遠不會被呼叫，一定要搭配保底計時器，另外沒設定評估 ID 時 `window.gtag` 根本不存在，攔截表單前要先判斷
5. **`OrderResultURL` 與 `ClientBackURL` 同時設定時以前者為主**：付款完成後綠界會直接把結果 POST 回感謝頁，所以感謝頁一定要驗章，不能只看網址就判定付款成功
6. **健康檢查路徑不要用 `/healthz`**：Kubernetes 慣用的 `/healthz` 在 Cloud Run 上會被平台攔截，直接回 Google 的 404，根本到不了你的程式，官方文件說明部分以 `z` 結尾的路徑是保留路徑，建議避開，之前第一次部署時健康檢查就是這樣失敗的，後來改成 `/health`
7. **剛授予的 IAM 角色不會馬上生效**：第一次部署時若剛加上 `roles/run.builder` 就立刻建置，可能出現 `PERMISSION_DENIED: Build failed because the default service account is missing required IAM permissions`，腳本在授權後會先等 90 秒，手動操作時稍等一兩分鐘再重試即可
8. **Cloud Run 後面要處理協定標頭**：Cloud Run 前面有 Google Front End 代理，Flask 直接用 `url_for(..., _external=True)` 可能產生 `http://` 開頭的網址，本專案用 `ProxyFix(x_proto=1)` 只信任代理送來的協定標頭，並刻意不信任 `X-Forwarded-Host`，避免有人自帶標頭把回程網址改到別的網域
9. **時區要寫死台北**：Cloud Run 容器預設是 UTC，直接用 `datetime.now()` 產生的 `MerchantTradeDate` 會差 8 小時
10. **`ReturnURL` 必須公開且回應 `1|OK`**：綠界沒收到 `1|OK` 會視為通知失敗並重送，Cloud Shell 網頁預覽與需要登入的網址都收不到付款結果通知，本機測試請改用 `PAYMENT_MODE=simulate`

---

# 7. 總結與明日預告

今天用一個 Cloud Run 服務把「商品瀏覽 → 開始結帳 → 綠界測試付款 → 驗章 → 購買事件」整條即時資料流打通了，前端事件進 GA4 並每日匯出到 BigQuery，付款紀錄進 Cloud Logging，兩邊用同一個訂單編號與 GA `client_id` 對帳，軌道 A 的即時驗證正式上線。

回頭看前言提的三個問題，今天的作法分別對應：事件有沒有送出去，用 GA4 即時報表與 Cloud Logging 雙邊確認；金額對不對，用伺服器端定價加上三道檢查；結帳會不會被追蹤程式卡住，用 `event_callback` 加保底計時器，這三件事在真實專案裡都是事後才被發現的，先擋掉才有資格談歸因。

從明天開始，資料量會是主角。

**明日預告**：Day 05《雙軌資料工程：電商大數據合成器》，我們將用 Python 模擬 90 天、符合真實電商統計分佈的跨通路日誌，並沿用今天的商品 ID 與事件欄位，讓合成資料與 Live Demo 的真實事件能無縫對齊！
