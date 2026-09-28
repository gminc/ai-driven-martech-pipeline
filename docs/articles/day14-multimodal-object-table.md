# 1. 前言：報表只會記得 creative_id，不會記得圖長什麼樣子

LINE 重訓襪專案的開發新客群組裡有兩張圖片素材，同一個通路、同一群受眾、同一段期間，整季的曝光都在 28 萬次上下，cr-line-trn-p2 的點擊率是 2.11%，cr-line-trn-p1 只有 1.66%，打開廣告報表能看到的就只有這兩個編號和一排數字，兩張圖長什麼樣子、畫面裡有什麼、圖上寫了什麼字，這兩張圖片在人物、按鈕、色調、主打商品上都不一樣，但是報表一概不知道，差距從哪裡來今天不回答，要等 Day 17 把通路、受眾和商品都控管完成之後才能談。

Day 08 到 Day 13 分析的全是這種數字，素材疲乏那一題可以只靠點擊率找出來，因為它是同一張圖自己跟自己比，但要比較兩張不同的圖必須先看得到圖裡有什麼，這些圖片放在資料夾裡，BigQuery 查不到、SQL 也 JOIN 不到，行銷圈常說的非結構化資料指的就是這種東西。

今天先讓 BigQuery 看得到圖，把素材圖放進 Cloud Storage、建一張物件表，再用 `AI.GENERATE` 把圖交給 Gemini，請它用一句話的題目自由描述三張圖，看圖片能不能變成查得到的資料，也看自由描述卡在哪裡，今天的雲端費用都以 1 美元 32 元換算成新台幣。

今日核心目標：

1. 在 BigQuery 建立指向 Cloud Storage 素材圖的物件表，讓 SQL 查得到 24 張圖
2. 用 `AI.GENERATE` 讓 Gemini 直接看圖，比較同一張圖問兩次、換模型、降低解析度的差別
3. 量出一張圖算多少 Token，並看自由描述為什麼還不能直接拿來分組

---

# 2. 系統架構全景與設計理念

![圖一：素材圖放在 Cloud Storage，物件表只記錄每張圖的位置與中繼資料，AI.GENERATE 透過同一個連線讀圖交給 Gemini，描述寫回 BigQuery](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day14-multimodal-object-table.svg)

| 步驟 | 做什麼 | 產出 |
| --- | --- | --- |
| 放圖 | 24 張 1200×628 的素材圖上傳到 us-central1 的 bucket | `gs://<專案>-martech-assets/creatives/` |
| 建物件表 | 透過 Day 03 的連線 `us.vertex_ai_conn` 列出 bucket 裡的圖 | `martech_dw.obj_creatives`，24 列 |
| 挑示範圖 | 前言那兩張，加上 Meta 常態活動裡圖上文字最多的一張 | `martech_dw.mm_demo`，3 列 |
| 看圖 | 三張圖各問四輪，共 12 次 | `martech_dw.mm_describe`，12 列 |

💡 **核心工程理念**：

1. **圖片不搬進 BigQuery**：物件表只記錄路徑、大小、類型與更新時間，圖片本身留在 Cloud Storage，要看圖時才透過連線讀取
2. **先看少量再放大**：今天只看 3 張，確認寫法、Token 與描述的樣子，Day 16 才一次處理 24 張
3. **自由描述只是起點**：今天刻意不給格式，先看 AI 自己會寫什麼，再決定 Day 15 要它照什麼格式交資料

---

# 3. 核心技術深度拆解

## 3.1 非結構化資料牆：報表有什麼、沒有什麼

廣告報表 `fct_ad_daily` 每天每個素材一列，只有曝光、點擊、花費，Day 07 建的素材維度表 `dim_creative` 多了通路、活動、受眾、主打商品，合成資料另外有四個設計欄位，有沒有人物、按鈕位置、主色、文字多寡，那是合成器產生素材時照著畫的規格，等於標準答案，留給 Day 16 抽特徵與 Day 20 評測對答案用（發表時這四欄放在 `dim_creative`，Day 15 起搬進答案資料集 `martech_gt.gt_creative_design`，分析資料集裡不再有答案，原因在 Day 15 說明），真實的廣告後台沒有這幾欄，設計師交圖時不會順手填一張表，就算填了也沒人維護，所以這些資訊只能從圖裡讀出來，今天拿這四欄只是為了檢查 AI 的描述準不準，前言那兩張圖的差異也不只在畫面，p1 主打厚底毛巾襪、p2 主打純棉短襪，連商品都不同。

要回答這種問題，第一步是讓每一張圖都有一組可以 GROUP BY 的欄位，而這些欄位要從圖本身讀出來，不能靠人工補，今天先解決「讀得到圖」和「看得懂圖」，欄位的格式留給 Day 15，特徵和點擊率的關係留給 Day 17。

## 3.2 讓 BigQuery 看得到圖：bucket、物件表、連線權限

素材圖放在 Day 03 用 Terraform 建的 bucket，位置是 us-central1，24 張合計約 2.9 MB，物件表是一種特別的外部表，建立時指定連線與路徑：

```sql
CREATE OR REPLACE EXTERNAL TABLE martech_dw.obj_creatives
WITH CONNECTION `us.vertex_ai_conn`
OPTIONS (
  object_metadata = 'SIMPLE',
  uris = ['gs://PROJECT_ID-martech-assets/creatives/*.jpg']
);
```

查這張表會得到 24 列，每一列有 `uri`、`size`、`content_type`、`updated` 等中繼資料，還有一個 `ref` 欄，它是指向那張圖的參照，之後交給 Gemini 看圖就是傳這一欄，`PROJECT_ID` 由 `run.sh` 換成你的專案 ID，BigQuery 規定 US 多區域的資料集要搭配 US 多區域、us-central1 或含 us-central1 的雙區域 bucket，這個系列的資料集在 US 多區域、bucket 在 us-central1，剛好符合。

連線 `us.vertex_ai_conn` 在 Day 03 建立時是為了呼叫 Gemini，它背後有一個 Google 管理的服務帳號，BigQuery 透過這個帳號去讀 bucket，所以要給它這個 bucket 的物件讀取權限（`roles/storage.objectViewer`），我把這個授權寫進 Terraform，只開這一個 bucket、只能讀，完整的前置步驟與上傳指令寫在 [multimodal/README.md](https://github.com/gminc/ai-driven-martech-pipeline/blob/main/multimodal/README.md)。

## 3.3 第一次讓 Gemini 看圖

看圖用的是 `AI.GENERATE`，題目寫成一組括號，文字和 `ref` 並列：

```sql
SELECT
  AI.GENERATE(
    ('這是一張電商廣告圖，請用繁體中文描述它，讓沒看過這張圖的行銷同事知道它長什麼樣子，150 字以內。', ref),
    connection_id => 'us.vertex_ai_conn',
    endpoint => 'gemini-3.5-flash-lite',
    model_params => JSON '{"generation_config": {"max_output_tokens": 1024, "thinking_config": {"thinking_budget": 0}}}'
  ) AS g
FROM martech_dw.obj_creatives
JOIN martech_dw.mm_demo USING (uri);
```

`JOIN mm_demo` 只留三張示範圖，拿掉這一行就會對 24 張圖各呼叫一次，BigQuery 會透過連線把圖讀出來交給 Gemini，不用自己產生下載網址，回傳的 `g.result` 是描述、`g.full_response` 裡有 Token 用量，題目只有一句話，不給格式、不給要看哪些東西，三張示範圖是前言的 p1、p2，加上 Meta 常態活動裡圖上文字最多的 cr-meta-evg-r2，每張問四輪：

| 輪 | 模型 | 解析度 | 目的 |
| --- | --- | --- | --- |
| 1、2 | gemini-3.5-flash-lite | 預設 | 同一張圖問兩次，看措辭一不一樣 |
| 3 | gemini-3.6-flash | 預設 | 換一個模型對照 |
| 4 | gemini-3.5-flash-lite | 低 | 看少算多少 Token、描述少了什麼 |

12 次全部成功，每段約 110 到 190 字（含標點），題目要求 150 字以內，有兩段超過，看得出來 Gemini 看懂了圖，p2 四次都寫出一位短髮女性坐在木椅上，腳上是米白色的襪子，也都讀出右上角的「天天穿的純棉短襪」，p1 四次都寫出畫面中央的厚底毛巾襪、右上角的標題和下方的「立即選購」按鈕，p2 這張圖本來就沒有按鈕，四次也都沒有提到按鈕，r2 圖上有五段字，「新品」「免運」兩個圓形標籤、一行標題、兩行賣點，四次全部讀對。

同一張圖問兩次，內容一致、措辭不同，flash-lite 看 p1 第一次寫「簡約質感」，標題是「白底黑字」、按鈕是「黑底白字」，第二次寫「溫馨簡約」，標題在「半透明白框」裡、按鈕是「黑色膠囊狀按鈕」，3.6-flash 則寫「大地色系」，按鈕是「深灰色」，三段描述各是一種說法，另一個例子是 p2 的襪子，圖上的標題是「天天穿的純棉短襪」，畫面裡是拉到小腿的羅紋襪，flash-lite 三次都寫短襪，3.6-flash 照畫面寫成「中筒襪」，自由描述不會告訴你它是照畫面還是照文案寫的。

低解析度省了四分之三的圖片 Token，內容卻沒有少，一張 1200×628 的圖在預設解析度算 1,104 個 Token，低解析度只算 276 個，剛好四分之一，加上約 40 個 Token 的題目，每次呼叫的輸入從 1,144 降到 316，但這三張圖的主要內容和圖上的每一段字都還是讀對了，整批 24 張能不能都用低解析度，要到 Day 16 逐張比對才知道，字小或細節多的圖更要先抽幾張比較再決定。

## 3.4 自由描述為什麼還不能直接分組

12 段描述存在 `mm_describe` 的一個文字欄裡，直接 `GROUP BY description` 會得到 12 組，每一段都不一樣，要分組只能自己寫規則，我試了兩條關鍵字規則，再和設計規格對照：

| 規則 | 關鍵字 | 結果 |
| --- | --- | --- |
| 有沒有提到人 | 人物、女性、男性、一位、一名等 | 12 次都和規格一致 |
| 有沒有提到暖色 | 暖色、橘、磚紅、米色、大地色等 | 三張規格都不是暖色卻有 5 次判成暖色 |

人物這次很好判斷，三張圖只有一張有人物，四次描述都寫了出來，顏色就不一樣了，r2 的三次命中都是「米色毛巾」這類商品本身的顏色，p1 的兩次則是把整張圖說成「米色調」或「大地色系」，而規格把這種米白、淺灰的畫面歸成中性色，更麻煩的是同一張圖兩次描述結果不同，r2 第一次寫「燕麥色純棉毛巾」沒被判成暖色，第二次寫「米色毛巾」就被判成暖色，規則是我自己猜的，換一批圖、換一次措辭就會失準。

自由描述適合給人讀，要拿來計算就需要固定的欄位，例如有沒有人物只能填是或否、主色只能從幾個選項裡挑，這正是 Day 15 要做的事。

---

# 4. FinOps 成本防護實踐：三道防線體系

1. **第一道防線：善用 Google Cloud 每月免費額度**：24 張圖約 2.9 MB，放在 us-central1 的標準儲存，在 Cloud Storage 每月 5 GB 的免費額度內，物件表只記錄中繼資料，建表和查詢都含在 BigQuery 每月 1 TiB 的查詢免費額度內
2. **第二道防線：架構層被動成本防護**：會花錢的只有看圖的 12 次，`run.sh` 呼叫前先用最壞情況估價，每次輸入以 1,200 個 Token、輸出以上限 1,024 個計，約新台幣 1.4 元，看到數字輸入 yes 才會呼叫，實際合計新台幣 0.32 元，flash-lite 看一張圖約 0.023 元、3.6-flash 約 0.046 元，低解析度 flash-lite 約 0.014 元，輸入費降了七成，但每段描述約 120 個 Token 的輸出費沒有變，所以整體只省四成，換算成 1,000 張圖，flash-lite 預設解析度約 23 元、低解析度約 14 元
3. **第三道防線：Cloud Billing 預算警報**：沿用 Day 03 由 Terraform 建立的預算警報（新台幣帳戶 NT$300／美元帳戶US$ 10），50%、80%、100% 三段通知，今天的操作不會觸發

這些金額用的是非 global 端點的單價，Day 10 帶快取時發現 `endpoint` 只寫模型名稱，BigQuery 會把請求送到非 global 的端點，單價比 global 高一成，3.5-flash-lite 每百萬 Token 輸入 0.33、輸出 2.75 美元，3.6-flash 輸入 0.825、輸出 4.125 美元，今天的 `describe.sql` 只寫模型名稱，所以用這組單價計算。

`thinking_budget` 一樣設 0，Day 09 實測 3.6-flash 預設會先思考，思考 Token 會吃掉 `max_output_tokens` 的額度，也以輸出單價計費，描述圖片用不到推理，所以關掉。

---

# 5. Cloud Shell 實戰演練：一行指令從物件表到看圖

## 5.1 事前準備

- 先在 `~/ai-driven-martech-pipeline` 執行 `git pull`，取得 Day 14 的程式與 Terraform 設定
- `gcloud config get-value project` 要印出你的專案 ID，路線 B 會用它代入 bucket 名稱
- 已完成 Day 07，`martech_dw` 裡有 `fct_ad_daily` 與 `dim_creative`
- Terraform 已把連線服務帳號加上素材 bucket 的讀取權限，這個授權是 Day 14 新增的，Day 13 以前建好的環境要在 `terraform/` 再執行一次 `terraform apply`，權限生效可能要等幾分鐘
- 素材圖已上傳到 bucket，指令見 [multimodal/README.md](https://github.com/gminc/ai-driven-martech-pipeline/blob/main/multimodal/README.md)
- 確認 gcloud 有登入中的帳號，輸入 `gcloud auth list`，帳號前面要有星號

## 5.2 路線 A｜懶人包：一行指令跑完

```bash
cd ~/ai-driven-martech-pipeline && git pull && bash multimodal/run.sh
```

`run.sh` 先確認 bucket 裡有 24 張圖，物件表不存在就用你的專案 ID 建一張，已經存在就沿用，接著印出三張示範圖、印出最壞費用，輸入 yes 才會呼叫 Gemini，之後依序是 11 項檢查與五段報表，在估價那一步直接按 Enter 就會停下來，不會產生 Token 費用。

## 5.3 路線 B｜逐步教學：理解每一個步驟

### 步驟 1：物件表與示範圖

```bash
cd ~/ai-driven-martech-pipeline/multimodal
sed "s/PROJECT_ID/$(gcloud config get-value project)/" object_table.sql | bq query --nouse_legacy_sql --format=pretty
bq query --nouse_legacy_sql --format=pretty < demo.sql
```

第一行先用 sed 把 `PROJECT_ID` 換成你的專案 ID，再交給 bq 建物件表並印出張數與總大小，應該是 24 張、2,933,458 bytes，第二個挑三張示範圖。

### 步驟 2：看圖

```bash
bq query --nouse_legacy_sql --format=pretty < describe.sql
```

四輪共 12 次呼叫，最後印出每一輪的成功次數與 Token 合計，這一步會產生約新台幣 0.3 元的費用。

### 步驟 3：檢查與報表

```bash
bq query --nouse_legacy_sql --format=pretty < check.sql
bq query --nouse_legacy_sql --format=pretty --max_rows=100 < report.sql
```

`check.sql` 是 10 項流程檢查，`report.sql` 五段分別是三張圖的點擊率、描述並排、Token、關鍵字分組的對照與實際費用，第 4 段會印出兩張表。

## 5.4 驗證成果

- `obj_creatives` 24 列、全部是 `image/jpeg`
- `mm_describe` 12 列、四輪各 3 張、`status` 全部是空字串、每一列都有 Token 用量
- 低解析度三張的輸入 Token 都比預設解析度少
- `run.sh` 的 11 項檢查全部通過，其中一項確認看圖用的 SQL 沒有讀答案資料集 `martech_gt`

## 5.5 用完後怎麼處理

```bash
bq rm -f -t martech_dw.mm_demo
bq rm -f -t martech_dw.mm_describe
```

物件表和 bucket 裡的圖 Day 15 到 Day 20 都會用到，先留著，物件表不存圖片本身，放著不收費。

---

# 6. 工程實務避坑指南

1. **生圖混進文字**：這批素材的底圖是 AI 生的，底圖一律不放文字，標題、賣點和按鈕由程式照規格畫上去，圖上的字才會和規格一致
2. **服務帳號缺 bucket 權限**：物件表和看圖都是透過連線背後的服務帳號去讀 bucket，不是用你自己的帳號，這個帳號沒有讀取權限時會出現權限錯誤，權限寫進 Terraform 才不會換環境就忘記
3. **物件表的中繼資料快取**：物件表可以設定中繼資料快取，圖很多時查詢比較快，但新上傳的圖要等快取更新才看得到，今天沒有開快取，每次查詢都即時列出 bucket 裡的檔案
4. **bucket 的生命週期規則**：Day 03 設了現行物件 90 天後刪除，素材圖一樣適用，過了 90 天重跑要重新上傳
5. **一次丟整批圖**：`AI.GENERATE` 每一列就是一次呼叫，物件表有幾列就呼叫幾次，今天的 `describe.sql` 先和 `mm_demo` JOIN 只留三張，確認寫法、Token 和描述品質之後再放大到整批
6. **把自由描述當資料**：關鍵字分組會跟著措辭變動，要計算就要先把格式固定

---

# 7. 總結與明日預告

今天讓 BigQuery 第一次看得到素材圖，圖片留在 Cloud Storage，物件表只記錄位置，`AI.GENERATE` 把文字題目和物件表的 `ref` 一起交給 Gemini，三張圖 12 次描述全部成功，畫面主體和圖上的每一段字都讀對了，一張 1200×628 的圖在預設解析度算 1,104 個 Token，低解析度 276 個，這三張用低解析度也讀得對，12 次合計新台幣 0.32 元。

回到篇名，圖裡有報表沒有的資訊，這一點今天已經看得到，前言那兩張圖的點擊率差距是不是來自畫面，要等 Day 17 控管通路、受眾與商品之後才知道，而且自由描述是給人讀的，同一張圖每次寫法都不一樣，關鍵字規則判斷暖色就判錯了 5 次，要讓圖片變成能 GROUP BY 的資料還差一步。

**明日預告**：Day 15《讓 AI 看完廣告圖，乖乖照格式交出結構化資料》，今天的描述是一段自由文字，明天規定 Gemini 每看一張圖都交出固定的幾個欄位，讓每一張圖都變成一列可以查詢、可以分組的資料。
