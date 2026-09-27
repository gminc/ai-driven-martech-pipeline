# acceptance — Day 13 資料引擎驗收：先把答案藏好再來考，看找回幾個

把 Day 05 合成器藏進資料裡的訊號（`synthesizer/out/ground_truth/ground_truth.json`）當考卷，
把 Day 08 到 Day 12 的分析結果整理成一張成績單，再做一次不給提示的 AI 盲測。
判準在看成績之前先寫死、先 commit，跑的時候會印出判準的 commit 時間和評分時間。

文章：Day 13《先把答案藏好再來考 AI，看它能找回幾個》

## 三個原則

1. 答案表（`martech_gt`）和分析用的資料集（`martech_dw`）分開，只有 `scorecard.sql`、`blind_score.sql` 會把兩邊放在一起，`run.sh` 會用 grep 確認題目與呼叫的 SQL 沒有讀 `martech_gt`
2. 判準（`criteria.sql`、`blind_criteria.sql`）先 commit 再跑成績，`run.sh` 的第 17 項檢查會比對 commit 時間與評分時間
3. 看完成績不回頭改判準；真的要改，另開一版檔名（例如 `criteria_v2.sql`）並在這裡記錄原因與日期

## 考卷與判準

| 訊號 | 內容 | 之前在哪一篇找 | 檢查項目 |
| --- | --- | --- | --- |
| S1 | meta-trn-prospecting 8/12 起點擊成本變兩倍 | Day 09 | S1a SQL 倍數 1.6–2.4；S1b flash-lite 判「競價變貴」 |
| S2 | 8/27 purchase 事件整天沒送出 | Day 09 | S2a 追蹤事件÷後台訂單 ≤ 0.1；S2b flash-lite 判「追蹤碼失效」 |
| S3 | cr-meta-evg-p1 點擊率每週衰退約 8% | Day 09 | S3a 週倍數 0.88–0.96；S3b flash-lite 判「素材疲乏」 |
| S4 | 圖片屬性對點擊率的乘數 | Day 17 | 待考 |
| S5 | 四種顧客類型 | Day 11、12 | S5a 分群後四種類型各自落在「自己是多數」的群的比例，最低的一個 ≥ 0.6；S5b 高頻買襪客平均預測÷其他 ≥ 1.5 |
| S6 | meta 在路徑開頭、google 搜尋在最後一步 | Day 08 | S6a meta 第一次÷最後接觸功勞 ≥ 1.2；S6b google/cpc 最後÷第一次 ≥ 1.2 |
| S7 | 秋日棉織專案期間專案商品占比上升 | Day 09 | S7a 專案期間占比－前三週占比 ≥ 5 個百分點 |

門檻的來源：S1a、S3a 是答案值的 ±20%；S2a 容許零星漏報；S5a、S5b、S6、S7a 是「方向對、幅度明顯」的下限。
判準寫於 9/24（commit 02845b2），當時 Day 08、09 已經發表、Day 11、12 還在開發，這一點文章裡會說明。

## AI 盲測

Day 09 是先用 SQL 挑出四筆異常、再給六個候選原因讓 Gemini 選；這次不挑、不給候選，
把整季（6/15 到 9/14 週）的週報交給 Gemini，請它自己列出值得注意的異常和可能原因：

- 週報內容（`blind_prompt.sql`）：15 個廣告群組每週的點擊／點擊率／每次點擊花費／花費、30 個素材每週點擊率、每週網站追蹤到的購買事件 vs 後台訂單、每週各商品售出件數，只有活動名稱與期間當背景說明
- 兩個模型（gemini-3.5-flash-lite、gemini-3.6-flash）各問三次，`thinking_budget` 設 0、`max_output_tokens` 4096，回傳格式鎖成 JSON 的 findings 陣列
- 週報看得到的只有 S1、S2、S3、S7 四題，S5、S6 這種資料週報裡沒有，不考
- 評分（`blind_criteria.sql`）：每個訊號三組關鍵字（規則運算式），一項發現同時命中三組，那一次就算找到；關鍵字判定會有誤差，文章裡會把每一項發現的原文列出來對照

## 檔案

| 檔案 | 做什麼 | 讀答案表 |
| --- | --- | --- |
| `criteria.sql` | 成績單判準 → `martech_gt.acceptance_criteria`（12 列） | 建在答案表資料集 |
| `scorecard.sql` | 各篇結果表算實測值，最後對照判準 → `martech_gt.acceptance_scorecard` | 最後一段 |
| `blind_criteria.sql` | 盲測判準 → `martech_gt.blind_criteria`（4 列） | 建在答案表資料集 |
| `blind_prompt.sql` | 整季週報寫成題目 → `martech_dw.blind_prompt`（3 列相同） | 否 |
| `blind_cost.sql` | 數 Token、估最壞費用 | 否 |
| `blind.sql` | 呼叫 Gemini 6 次 → `martech_dw.blind_result`、拆成 `blind_findings` | 否 |
| `blind_score.sql` | 發現對照盲測判準 → `martech_gt.blind_scorecard`（24 列） | 是 |
| `check.sql` | 15 項流程檢查（列數、格式、有沒有用到思考），`run.sh` 補 2 項 | 是 |
| `report.sql` | 六段報表：成績單、每題判定、盲測命中、每次呼叫、實際費用、每一項發現 | 是 |
| `run.sh` | 一行跑完，呼叫 Gemini 前會停下來問 | — |

## 執行

```bash
cd ~/ai-driven-martech-pipeline && git pull && bash acceptance/run.sh
```

前置：Day 07 `warehouse/build.sh`、Day 08 `attribution/`、Day 09 `diagnosis/run.sh`、Day 11 `segmentation/run.sh`、Day 12 `ltv/run.sh`，
以及 Day 03 的連線 `us.vertex_ai_conn`；答案表沒載過會自動跑 `scripts/load_ground_truth.sh`。

流程：印判準 commit 時間 → 建判準表 → 成績單 → 盲測題目（印前 10 行）→ 數 Token 與估價 → 輸入 `yes` → 呼叫 Gemini →
盲測評分 → 17 項檢查 → 六段報表。`AUTO_YES=1` 可以跳過確認。

S5a 讀 `mart_customer_segment_official`（Day 11 發表當天的分群，另存成固定輸入，因為 K-means 每次重建分法可能不同）；
你的環境沒有這張表的話 `run.sh` 會改讀 `mart_customer_segment`，S5a 的數字可能和文章不同。

## 費用

- 成績單、題目、評分、檢查、報表都是查詢，含在每月 1 TiB 免費額度內
- 盲測 6 次：題目約 6,000–8,000 個 token（實測數字見文章第 4 章），最壞情況（每次都輸出滿 4,096 個 token）約新台幣 7 元，實際輸出通常 1,000–2,000 個 token、約新台幣 3 元，`blind_cost.sql` 會先印估價，`report.sql` 第 ⑤ 段依實際 token 數算費用
- 遠端模型 `gemini_flash_lite`、`gemini_flash` 建立本身不收費，Day 09 建過就沿用

## 用完後怎麼處理

```bash
bq rm -f -t martech_dw.blind_prompt
bq rm -f -t martech_dw.blind_result
bq rm -f -t martech_dw.blind_findings
```

`martech_gt.acceptance_scorecard`、`blind_scorecard` 很小，建議保留當紀錄；重跑 `run.sh` 會重建全部。
