# 1. 前言：等月底帳單來了才知道花多少，那時候已經來不及了

從 Day 16 到 Day 24，素材特徵、素材草稿、一致性審查、模型比較，再到行銷助理的問答、護欄與評測，幾乎每一天都在呼叫模型，每一篇文章的 FinOps 小節也都交代了當天花多少，可是那些數字每天各算各的散在好幾篇文章裡，如果主管問這個專案到今天為止總共花了多少、哪一天最貴、是哪個模型吃掉的，就得把那幾篇文章翻出來自己加。

明天助理就要部署上線給同事用了，到時候呼叫模型的不再只有我，更不可能靠翻文章來算，這件事要在上線之前先解決。

好在 Day 16 就先做了準備，從那一天開始，拿得到用量的每一次模型呼叫都抄一份進同一張表 `ops_llm_usage`，一列就是一次呼叫，記了哪一天、哪支程式、哪個模型、輸入與輸出各多少 Token，今天要做的就是把這張表變成打開就看得到的儀表板，再替它配一個超過門檻會主動寄信的警報。

今日核心目標：

1. 用一張單價對照表加兩個 view，把只記 Token 的用量表換算成每一天、每一篇、每個模型花了多少錢
2. 在 Data Studio（原 Looker Studio）接上 view 做成儀表板，只開給指定的 Google 帳號
3. 沿用 Day 03 的預算警報，多連一個 Cloud Monitoring 的通知信箱，並且弄清楚儀表板和帳單各自能回答什麼

---

# 2. 系統架構全景與設計理念

![圖一：用量表 ops_llm_usage 加上單價表 ref_llm_price，經過兩個 view 換算成費用，一邊給 Data Studio 儀表板看，另一邊是 Cloud Billing 預算警報透過 Cloud Monitoring 通知管道寄信，兩條線的資料來源不同](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day25-token-flow.svg)

今天的架構是兩條互不相干的線，一條負責看，一條負責高呼警報。

| | 儀表板 | 預算警報 |
| --- | --- | --- |
| 回答的問題 | 錢花在哪一天、哪一篇、哪個模型 | 這個月整個專案花超過門檻了沒 |
| 資料來源 | 自己記的用量表乘上單價表 | Cloud Billing 的實際帳單 |
| 範圍 | 只有寫進用量表的模型呼叫 | 專案裡所有會收費的服務 |
| 多久更新 | 查的時候才算，預設快取 12 小時 | 官方沒有給固定數字，用量回報到帳單會晚一段時間 |
| 要不要有人去看 | 要 | 不用，超過門檻自己寄信 |
| 工具 | BigQuery view 加 Data Studio | Cloud Billing 預算加 Cloud Monitoring 通知管道 |

這個設計有三個刻意的安排。

第一，用量表只存 Token 不存錢，單價另外放一張表 `ref_llm_price`，一列是一個模型在一種端點、一段期間的單價，這樣做是因為單價會變，gemini-3.6-flash 現在是導入期價格，官方定價頁寫明 2027 年 1 月 1 日起恢復原價，也就是現在的兩倍，如果當初把錢直接寫死在用量表裡，調價那天就得回頭改歷史資料，分開放的話只要在單價表加一列。

第二，換算放在 view 裡，不另外存一張算好的表，view 不存資料，每次被查才去讀用量表，所以儀表板看到的永遠是用量表當下的內容，不需要排程去更新，到今天為止用量表只有 279 列，每次現算完全沒有負擔。

第三，Cloud Monitoring 今天只做一件事，就是當預算警報的通知管道，我沒有另外做自訂指標把 Token 數送進 Cloud Monitoring 畫圖，原因是用量已經在 BigQuery 裡了，再送一份到另一個系統等於同一份資料維護兩個地方，而且預算警報看的是實際帳單，比我自己記的用量更適合拿來當警報的依據。

---

# 3. 核心技術深度拆解

## 3.1 單價表：同一個模型有四種價格

先看用量表裡到今天為止實際出現過哪些模型和端點。

| 模型 | 端點 | 出現在哪幾天 | 呼叫次數 |
| --- | --- | --- | --- |
| gemini-3.5-flash-lite | 非 global | Day 16、20 | 72 |
| gemini-3.6-flash | 非 global | Day 18、19、20 | 97 |
| gemini-3.6-flash | global | Day 21 到 24 | 85 |
| gemini-3.1-pro-preview | global | Day 20 | 24 |
| veo-3.1-lite-generate-001 | 非 global | Day 18 | 1 |

端點分兩種是因為價格不同，Day 16 到 20 是在 BigQuery 的 SQL 裡呼叫模型，資料集在美國多區域，只寫模型名稱的走非 global 端點，例外是 Day 20 的 gemini-3.1-pro-preview，它要把端點寫成 global 的完整網址才呼叫得到，Day 21 起的助理用 Python SDK 直接呼叫，走的也是 global 端點，官方定價頁上非 global 比 global 貴一成，同一個 gemini-3.6-flash 再加上 2027 年調價前後，就有四種價格。

```sql
INSERT INTO martech_dw.ref_llm_price VALUES
  ('gemini-3.6-flash',      'global',     DATE '2026-07-21', DATE '2026-12-31', 0.75,  3.75,  'introductory pricing'),
  ('gemini-3.6-flash',      'non-global', DATE '2026-07-21', DATE '2026-12-31', 0.825, 4.125, 'introductory pricing'),
  ('gemini-3.6-flash',      'global',     DATE '2027-01-01', DATE '9999-12-31', 1.50,  7.50,  'standard pricing'),
  ('gemini-3.6-flash',      'non-global', DATE '2027-01-01', DATE '9999-12-31', 1.65,  8.25,  'standard pricing'),
  ('gemini-3.5-flash-lite', 'global',     DATE '2026-07-21', DATE '9999-12-31', 0.30,  2.50,  ''),
  ('gemini-3.5-flash-lite', 'non-global', DATE '2026-07-21', DATE '9999-12-31', 0.33,  2.75,  ''),
  ('gemini-3.1-pro-preview', 'global',    DATE '2026-01-01', DATE '9999-12-31', 2.00,  12.00, 'input up to 200K tokens');
```

數字是每百萬 Token 的美元單價，前一個是輸入、後一個是輸出，輸出價包含思考 Token，都是 2026 年 10 月 8 日從官方定價頁查的，單價會變，照做之前請自己再查一次。

這張表有兩件事要留意，第一是同一個模型、同一種端點的期間不能重疊，重疊的話一次呼叫會對到兩列單價，費用就算了兩次，這件事交給檢查去守，第二是表裡沒有 Veo，Day 18 那支影片是按秒計費的，用量表裡它的 Token 欄位是空的，沒辦法用同一條公式算，後面會交代它在儀表板上怎麼呈現。

## 3.2 兩個 view：一個留明細，一個給儀表板

第一個 view `v_llm_usage_calls` 維持一列一次呼叫，做三件事，把時間換成台北日期、依模型與端點與日期對到單價、算出費用，下面是節錄，完整的在 `monitoring/views.sql`。

```sql
SELECT
  DATE(u.logged_at, 'Asia/Taipei') AS usage_date,
  u.day, u.job, u.model, u.endpoint_type,
  IF(u.status = '', 'ok', 'failed') AS call_result,
  IFNULL(u.prompt_tokens, 0) AS prompt_tokens,
  IFNULL(u.output_tokens, 0) AS output_tokens,
  p.model IS NOT NULL AS priced,
  IFNULL(u.prompt_tokens, 0) * p.usd_in_per_m / 1e6 * 32 AS cost_in_twd,
  IFNULL(u.output_tokens, 0) * p.usd_out_per_m / 1e6 * 32 AS cost_out_twd,
  (IFNULL(u.prompt_tokens, 0) * p.usd_in_per_m + IFNULL(u.output_tokens, 0) * p.usd_out_per_m) / 1e6 * 32 AS cost_twd
FROM martech_dw.ops_llm_usage u
LEFT JOIN martech_dw.ref_llm_price p
  ON p.model = u.model
 AND p.endpoint_type = u.endpoint_type
 AND DATE(u.logged_at, 'Asia/Taipei') BETWEEN p.valid_from AND p.valid_to;
```

幾個地方值得說明：

- 用 LEFT JOIN 而不是 JOIN，對不到單價的呼叫才不會整列消失，它會留下來，`priced` 是 false、費用是空值
- 費用是空值而不是 0，這是刻意的，0 元讀起來像免費，空值才會提醒看的人這一筆沒有算到
- 輸入和輸出的費用分開算成兩欄，之後才看得出錢是花在輸入還是輸出
- 匯率固定用 1 美元 32 元，和前面每一篇一致，實際金額以帳單為準

第二個 view `v_llm_usage_daily` 把第一個彙總成一列是一天、哪一篇、哪支程式、哪個模型、哪種端點，儀表板接的是這一個，裡面多一欄 `unpriced_calls`，數的是對不到單價的呼叫有幾次，因為 SUM 會自動跳過空值，光看費用合計看不出少算了什麼，要有這一欄放在旁邊才知道合計不是全部。

## 3.3 Data Studio：接上 view，五個元件

Data Studio 是 Google 的免費報表工具，2026 年 4 月以前叫 Looker Studio，舊網址 lookerstudio.google.com 現在會自動轉到 datastudio.google.com，接 BigQuery 當資料來源本身不收費，收的是 BigQuery 的查詢費，記在資料來源設定的帳單專案上。

先講一個限制，Data Studio 沒有可以從零建立報表的 API，也沒有 Terraform 資源，所以這個系列一路堅持的一行指令做完，今天在儀表板這一步做不到，最接近的做法是 Linking API，把資料來源寫進一個網址，點開之後報表和資料來源就建好了，剩下的圖表要在瀏覽器裡用拖拉的方式完成。

```text
https://datastudio.google.com/reporting/create?r.reportName=MarTech%20AI%20Token%20Cost&ds.connector=bigQuery&ds.type=TABLE&ds.projectId=你的專案ID&ds.datasetId=martech_dw&ds.tableId=v_llm_usage_daily&ds.billingProjectId=你的專案ID
```

點開網址之後會連續遇到四個確認，授權 Data Studio 讀取 BigQuery、確認資料來源用的是擁有者憑證、同意報表使用你的帳號資訊做稽核紀錄、第一次使用還要選國家並同意服務條款，全部通過之後按 Edit and share 進入編輯模式。

![圖二：Data Studio 儀表板截圖，上方是每一篇的費用與呼叫次數表格和各模型的費用與呼叫次數長條圖，下方是累計費用、對不到單價的呼叫次數兩張計分卡和每天 Token 數的長條圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day25-dashboard.png)

我放了五個元件，做法都是從右邊的欄位清單把欄位拖到畫布或圖表的設定欄裡。

| 元件 | 維度 | 指標 | 要回答的問題 |
| --- | --- | --- | --- |
| 表格 | day | cost_twd、calls、unpriced_calls | 每一篇花多少、呼叫幾次 |
| 長條圖 | model | cost_twd、calls | 哪個模型用得多、哪個模型花得多 |
| 計分卡 | 無 | cost_twd | 到目前為止總共花多少 |
| 計分卡 | 無 | unpriced_calls | 有幾次呼叫沒有算進上面的合計 |
| 長條圖 | usage_date | total_tokens | 每一天用掉多少 Token |

資料來源用的是擁有者憑證，意思是看報表的人不需要自己有 BigQuery 的權限，查詢都用我的身分去跑、費用記在我的專案，換來的代價是任何拿得到報表的人都看得到資料，所以分享設定維持預設的 Restricted，只有被加進名單的 Google 帳號打得開，不要改成知道連結的人都能看。

## 3.4 儀表板和報表告訴我的四件事

第一件事，Day 16 到 Day 24 共 279 次呼叫，算得出來的費用合計是新台幣 22.73 元。

| 篇 | 呼叫次數 | 輸入 Token | 輸出 Token | 費用（新台幣） |
| --- | --- | --- | --- | --- |
| Day 16 | 48 | 51,408 | 2,748 | 0.78 |
| Day 18 | 25 | 54,100 | 12,245 | 3.04（不含影片） |
| Day 19 | 48 | 171,520 | 7,509 | 5.52 |
| Day 20 | 73 | 140,245 | 10,411 | 7.60 |
| Day 21 | 16 | 9,111 | 5,466 | 0.87 |
| Day 22 | 8 | 30,761 | 2,920 | 1.09 |
| Day 23 | 37 | 61,429 | 8,882 | 2.54 |
| Day 24 | 24 | 14,294 | 7,752 | 1.27 |

最貴的是 Day 20 的模型比較，那一天同一批題目讓三個模型各做一次，Day 23 的 2.54 元和 Day 24 的 1.27 元，跟那兩天文章裡寫的數字一樣，這也順便驗證了 view 的算法和當時程式裡的算法是一致的。

第二件事，輸出整體不到 Token 的一成，卻佔了費用的三到五成，下面這張表是報表第 3 段印出來的。

| 模型 | 端點 | 呼叫次數 | 費用（新台幣） | 輸出佔 Token | 輸出佔費用 |
| --- | --- | --- | --- | --- | --- |
| gemini-3.6-flash | 非 global | 97 | 9.75 | 7.5% | 28.9% |
| gemini-3.6-flash | global | 85 | 5.78 | 17.8% | 52.0% |
| gemini-3.1-pro-preview | global | 24 | 5.63 | 10.5% | 41.4% |
| gemini-3.5-flash-lite | 非 global | 72 | 1.57 | 5.1% | 30.9% |

原因是輸出的單價是輸入的五倍以上，gemini-3.6-flash 輸入 0.75 美元、輸出 3.75 美元，global 那一列是助理的問答，回答寫得長、還有思考 Token，輸出佔到 Token 的 17.8%，費用就有一半以上花在輸出，所以助理這種回答長、會思考的用法，限制輸出長度和思考的額度省得比較多，看圖和比對這種輸入大、回答短的用法，要省的反而是輸入。

第三件事，模型的選擇比呼叫次數更影響費用，gemini-3.1-pro-preview 只呼叫了 24 次就花了 5.63 元，gemini-3.6-flash 在 global 端點呼叫 85 次是 5.78 元，兩個幾乎一樣，而 gemini-3.5-flash-lite 呼叫 72 次只要 1.57 元，圖二右上角那張長條圖把費用和呼叫次數並排，gemini-3.6-flash 兩種端點合在一起所以兩根都高，gemini-3.5-flash-lite 次數多費用少，gemini-3.1-pro-preview 次數少費用多，一眼就看得出來。

第四件事最重要，儀表板上的 22.73 元不是這個專案的全部花費，至少有三筆不在裡面：

- Day 18 的 Veo 影片：按秒計費、沒有 Token，用量表記了這一次呼叫但算不出錢，當天文章估的是新台幣 4 到 6 元，這一筆比 Day 18 其他 24 次呼叫加起來還多，儀表板上它沒有費用，只算在 `unpriced_calls` 的 1 裡
- Day 24 的評分模型：Gen AI evaluation service 不回報 Token 用量，32 次評分完全沒有寫進用量表，當天的估價上限是 2.77 元
- Day 16 以前的呼叫：共用用量表是 Day 16 才建的，Day 09、10、13、14、15 呼叫 Gemini 的費用只記在各自的文章裡

另外還有模型以外的費用，BigQuery、Cloud Storage、Cloud Run 就算都在免費額度內，也不會出現在這張儀表板上，所以儀表板適合回答錢是怎麼花的、趨勢往哪裡走，實際花了多少要看 Cloud Billing 的帳單。

## 3.5 預算警報：多連一個通知信箱

儀表板要有人打開才有用，超過門檻這件事不能靠人記得去看，Day 03 用 Terraform 建的預算警報本來就在做這件事，每月預算新台幣 300 元，在 50%、80%、100% 三個門檻寄信，預設的收件人是帳單帳戶的管理員與使用者。

今天加的是讓它多寄一份到指定的信箱，做法是在 Cloud Monitoring 建一個 email 類型的通知管道，再把預算連到這個管道。

```hcl
resource "google_monitoring_notification_channel" "budget_email" {
  count        = var.billing_account_id != "" && var.alert_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "MarTech Budget Alert Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}
```

預算那一邊多一個 `all_updates_rule` 區塊，把通知管道的 ID 填進 `monitoring_notification_channels`，`disable_default_iam_recipients` 維持 false，原本寄給帳單帳戶管理員與使用者的那一份照舊，一個預算最多可以連 5 個通知管道，團隊裡要收到警報的人不一定有帳單帳戶的權限，這個管道就是給他們用的。

這裡要講清楚預算警報做不到的兩件事，它只會寄信，不會幫你把服務停掉，錢還是會繼續花，另外它有延遲，官方文件只說用量回報到 Cloud Billing 需要時間、沒有給數字，另外提到預算剛建好的時候第一封通知可能要等幾個小時，所以它擋不住幾分鐘內就燒完預算的那種意外，那一類要靠前面每一天都在做的第二道防線，也就是程式裡的呼叫次數上限、Token 上限和花錢前的估價確認。

---

# 4. FinOps 成本防護實踐：三道防線體系

1. **第一道防線：善用 Google Cloud 每月免費額度**：今天完全沒有呼叫模型，單價表只有 7 列，view 不存資料，Data Studio 本身免費，儀表板的每一個元件會對 BigQuery 發一次查詢，在每月 1 TiB 的查詢免費額度內，通知管道與預算警報都不收費
2. **第二道防線：架構層被動成本防護**：Data Studio 的資料新鮮度預設是 12 小時，期限內相同的查詢會直接用暫存的結果，不會每開一次報表就查一次 BigQuery，報表只分享給指定帳號，不會有不認識的人一直重新整理
3. **第三道防線：Cloud Billing 預算警報**：沿用 Day 03 由 Terraform 建立的預算警報，50%、80%、100% 三段通知，今天多連了一個 Cloud Monitoring 的通知信箱

| 項目 | 今天的費用（新台幣） | 說明 |
| --- | --- | --- |
| 模型呼叫 | 0 元 | 今天沒有呼叫任何模型 |
| BigQuery 查詢 | 0 元 | 在每月 1 TiB 免費額度內 |
| Data Studio | 0 元 | 免費版 |
| 通知管道與預算警報 | 0 元 | 不收費 |

---

# 5. Cloud Shell 實戰演練：從用量表到儀表板

## 5.1 事前準備

- 先在 `~/ai-driven-martech-pipeline` 執行 `git pull`，取得 Day 25 新增的 `monitoring/` 目錄
- `gcloud config get-value project` 要印出你的專案 ID
- 用量表 `ops_llm_usage` 是 Day 16 建的，至少要跑過 Day 16 之後任何一天的程式，表裡才有資料
- 你的用量和我的不會一樣，跑過哪幾天、各跑幾次，儀表板上就是那些

## 5.2 路線 A｜一個指令加一個網址

```bash
cd ~/ai-driven-martech-pipeline
bash monitoring/run.sh
```

這個指令會建立單價表和兩個 view，跑 12 項檢查，再印出四段報表，全程不呼叫模型，最後一行會印出儀表板要接的 view 名稱，接著把 3.3 那個網址裡的兩個「你的專案ID」換成自己的，貼到瀏覽器打開，照畫面完成授權，再把欄位拖成圖表。

## 5.3 路線 B｜一步一步看

### 步驟 1：先看用量表裡實際有什麼

```bash
cd ~/ai-driven-martech-pipeline
bq query --nouse_legacy_sql --format=pretty < monitoring/probe.sql
```

會列出每一天、每支程式、每個模型、每種端點各有幾次呼叫，單價表要列哪些模型是看這個結果決定的，不要憑印象。

### 步驟 2：建立單價表與 view

```bash
bq query --nouse_legacy_sql < monitoring/price.sql
bq query --nouse_legacy_sql < monitoring/views.sql
```

### 步驟 3：檢查

```bash
bq query --nouse_legacy_sql --format=pretty < monitoring/check.sql
```

12 項裡最值得看的是第 06、07 兩項，第 06 項確認單價表沒有期間重疊，第 07 項確認沒有「有 Token 卻對不到單價」的呼叫，如果你用了單價表裡沒有的模型，第 07 項會是 DIFF，到 `price.sql` 補一列再跑一次。

### 步驟 4：看報表

```bash
bq query --nouse_legacy_sql --format=pretty < monitoring/report.sql
```

四段依序是每一篇、每一天、每個模型與端點、對不到單價的呼叫。

### 步驟 5：預算警報多連一個信箱

```bash
cd ~/ai-driven-martech-pipeline/terraform
grep -q '^alert_email' terraform.tfvars || echo 'alert_email = ""' >> terraform.tfvars
sed -i 's/^alert_email.*/alert_email = "你的信箱"/' terraform.tfvars
~/bin/terraform plan
~/bin/terraform apply
```

前兩行是把 `terraform.tfvars` 裡的 `alert_email` 改成你的信箱，檔案裡沒有這一行就先補上，記得把「你的信箱」換掉，先看 plan 的結果再決定要不要 apply，這一次 plan 除了預算警報的變更與通知管道，還會列出 Day 26 到 28 要用的資源（三個 API、映像檔存放區、兩個服務帳號、一個空的密鑰，以及六個權限綁定），我的環境是 14 個新增、1 個變更、0 個刪除，這些資源建立當下都不收費。

## 5.4 驗證成果

- `check.sql` 的 12 項都是 OK
- 報表第 1 段每一篇的費用，和那幾天文章 FinOps 小節寫的數字對得起來，Day 18 和 Day 20 因為四捨五入的位置不同會差 0.01 元
- Data Studio 計分卡上的費用合計，和報表第 1 段每一篇加起來差不多，每一篇各自四捨五入到分，加起來會差一兩分錢，我的環境是 22.71 對 22.73
- Cloud Console 的「預算與快訊」頁面打開預算，通知的地方看得到連結的通知管道

## 5.5 用完後怎麼處理

單價表和兩個 view 都很小，留著不會產生費用，Day 26 助理上線之後的用量會繼續寫進同一張用量表，儀表板不用改就會多出新的資料，真的要清掉的話：

```bash
bq rm -f -t martech_dw.v_llm_usage_daily
bq rm -f -t martech_dw.v_llm_usage_calls
bq rm -f -t martech_dw.ref_llm_price
```

Data Studio 的報表在 datastudio.google.com 首頁選移除，預算警報的通知信箱把 `terraform.tfvars` 裡的 `alert_email` 改回空字串再 apply 一次。

---

# 6. 工程實務避坑指南

1. **儀表板不是帳單**：儀表板只算得出寫進用量表、又對得到單價的呼叫，按秒計費的影片、不回報用量的服務、建用量表之前的呼叫都不在裡面，要在儀表板上放一個「沒算到幾次」的數字，並且把實際金額以帳單為準這句話講在前面
2. **對不到單價要留空值，不要補 0**：補 0 之後合計看起來完整，少算的部分就再也沒人發現，留空值加上一個計數欄位，少算了什麼才看得見
3. **單價表的期間不能重疊**：重疊會讓同一次呼叫對到兩列單價，費用變兩倍而且不會報錯，檢查裡要有一項專門看這個，起始日相同的重複列也要抓得到
4. **用量表裡的失敗次數不一定是全部**：Day 16 到 20 的程式會把失敗的呼叫也寫進用量表，Day 21 起的助理只寫成功的，所以 view 和報表裡那幾天的失敗次數一定是 0，這不代表沒有失敗過，要看失敗得回到各天自己的紀錄表
5. **Linking API 的資料來源別名**：官方範例寫的是 `ds.ds0.connector` 這種帶別名的參數，在沒有指定範本、用預設範本建立的報表上會出現「ds0 is not a valid data source alias」，把別名拿掉寫成 `ds.connector` 才會成功
6. **資料新鮮度預設 12 小時**：剛跑完程式馬上開儀表板，看到的可能還是舊的數字，編輯模式可以手動重新整理，要讓只有檢視權限的人也能重新整理，得在報表設定裡另外打開
7. **擁有者憑證等於把資料交給看得到報表的人**：看報表的人不需要 BigQuery 權限就看得到資料，查詢費也算在你的專案，所以分享對象要一個一個加，不要開成知道連結就能看
8. **預算警報不會幫你停機，也不是即時的**：它只寄信，而且可能晚幾個小時，真正能擋住意外的是程式裡的上限與花錢前的確認

---

# 7. 總結與明日預告

今天把 Day 16 以來累積的 279 次模型呼叫，用一張單價表和兩個 view 換算成費用，接上 Data Studio 做成儀表板，算得出來的部分合計新台幣 22.73 元，最貴的是 Day 20 的模型比較，輸出整體不到 Token 的一成卻佔了費用的三到五成，24 次 gemini-3.1-pro-preview 花的錢和 global 端點那 85 次 gemini-3.6-flash 差不多，另外沿用 Day 03 的預算警報，多連了一個通知信箱，今天沒有呼叫模型，花費是 0 元。

回到篇名，打開儀表板確實一眼就看得到每天被扣了多少 Token、每一篇換算成多少錢，但今天更想留下的是它的邊界，按秒計費的影片、不回報用量的評分服務、建表之前的呼叫，這三筆它都看不到，儀表板回答的是錢怎麼花的，花了多少要回到帳單，超過了沒要交給預算警報，三樣東西各有各的用處，少了哪一樣都會有看不到的地方。

**明日預告**：Day 26《把 AI 助理部署上線，讓全團隊都能直接用》，把 Day 21 到 23 做好的助理連同護欄包成 Cloud Run 服務，只開給指定的 Google 帳號，同事用的每一次呼叫都會出現在今天的儀表板上。
