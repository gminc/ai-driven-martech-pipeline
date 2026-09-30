# features：讓 Gemini 一口氣看完所有素材圖，整理成視覺特徵表（Day 16）

Day 15 用六張樣本圖確認了寫法：`AI.GENERATE` 的 `output_schema` 鎖型別、題目寫進選項與判斷標準。Day 16 把同一套寫法放大到物件表裡的全部 24 張，存成特徵表 `mart_creative_features` 給 Day 17 和廣告成效 JOIN，並用低解析度再看一次，比較能不能省錢。

## 檔案

| 檔案 | 做什麼 | 收費 | 讀答案表 |
| --- | --- | --- | --- |
| `review.sql` | 記下規格和畫面看起來不一致的格子，存成 `martech_gt.gt_creative_review` | 免費額度內 | 建答案表 |
| `extract.sql` | 每張圖 × 預設、低解析度各看一次，呼叫紀錄存進 `mm_features_log`，用量抄進 `ops_llm_usage`，只呼叫還沒成功過的 | Gemini Token 費 | 否 |
| `mart.sql` | 從呼叫紀錄挑出每張圖一列，建特徵表 `mart_creative_features` | 免費額度內 | 否 |
| `check.sql` | 12 項流程檢查（`run.sh` 再補 1 項） | 免費額度內 | 否 |
| `report.sql` | 八段報表：分佈、每次呼叫幾次、逐欄答對、答錯清單、兩種口徑、高低解析度一致度、費用、用量表 | 免費額度內 | 第 3、4、5 段 |
| `run.sh` | 依序執行，呼叫 Gemini 前依這次真的要呼叫的次數印最壞費用並要求輸入 yes | — | — |

## 放大到整批時多做的三件事

1. **跑過的不重跑**：`mm_features_log` 用 `CREATE TABLE IF NOT EXISTS` 建立、不會被重建，每一次呼叫（成功或失敗）一列。`extract.sql` 先算出「還沒有成功紀錄的圖 × 解析度」存成暫存表 `todo`，只對它們呼叫，所以同一段 SQL 執行第二次，成功過的圖不會再花錢，失敗的會自動補跑。「成功」的定義是 `status` 為空字串而且五個欄位都有值，`extract.sql`、`mart.sql`、`check.sql` 與 `run.sh` 用同一條。`run.sh` 會真的跑第二次，`check.sql` 第 12 項確認沒有任何一張圖在成功之後又被呼叫。第一次有沒成功的，第二次執行前會再問一次 yes
2. **超出選項只補那幾張**：`output_schema` 只能鎖型別，萬一預設解析度回來的值不在選項裡，`extract.sql` 只把那幾張改用 `response_schema` 的 enum 再問一次，都在選項裡時這一段是 0 次呼叫。`mart.sql` 挑紀錄時先挑值都在選項裡的，再挑最新的
3. **用量記進共用表**：每一次呼叫都抄一份進 `martech_dw.ops_llm_usage`（日期分區），欄位有第幾天、哪個程式、`run_id`、模型、端點類型、解析度、素材 ID、輸入與輸出 Token、狀態。單價不存在表裡，計費時再依模型與端點類型對照。抄寫時會補上所有還沒抄過的執行，萬一某次執行在中途出錯、沒抄到，下一次會補上。Day 25 的監控從這張表讀，之後各天呼叫 Gemini 也寫進來

BigQuery 腳本裡變數不能和欄位同名，`extract.sql` 的執行編號變數叫 `this_run`，如果叫 `run_id`，`WHERE run_id = run_id` 會比到欄位自己、永遠成立。

## 規格和畫面不一致的圖

素材的底圖是 AI 生的，生出來的畫面不一定完全照規格。看圖之前，先請一位沒看過規格的判讀者照 `extract.sql` 同一套判斷標準逐張判讀 24 張，再和規格比對：

- **disagree**（判讀和規格不同）1 格：`cr-meta-trn-r2` 的主色，規格是 cool，背景是淺灰牆和水泥地，照判斷標準算 neutral
- **borderline**（判讀者認為可能判得不一樣）6 格，全部是主色，背景混了兩種色系或灰藍很淡

`report.sql` 第 5 段分兩種口徑算主色答對率，Day 20 評測排除 disagree 的格子。

## 特徵表 `mart_creative_features`

| 欄位 | 說明 |
| --- | --- |
| `creative_id` | 素材 ID，和 `dim_creative`、`fct_ad_daily` JOIN |
| `has_person`、`cta_position`、`dominant_color`、`text_density`、`headline` | Gemini 看圖抽出的五個欄位 |
| `in_option` | 三個 STRING 欄位是否都在選項內 |
| `model`、`method`、`resolution`、`extracted_at` | 這一列來自哪個模型、哪種鎖法、哪種解析度、什麼時候 |

只收預設解析度的結果，低解析度只拿來對照。

## 前置

1. 先 `git pull`
2. 已完成 Day 14（物件表 `obj_creatives`、bucket 裡 24 張圖）與 Day 15 的搬家（`martech_gt.gt_creative_design`）
3. `gcloud auth list` 有星號的帳號、`gcloud config get-value project` 印出專案 ID

## 執行

```bash
cd ~/ai-driven-martech-pipeline && git pull && bash features/run.sh
```

## 費用

最壞情況：第一次執行 48 次呼叫，預設解析度每次輸入以 1,600 個 Token、低解析度以 800 個計，輸出以上限 256 計，約 US$ 0.053 ≈ 新台幣 1.7 元。單價用非 global 端點（`endpoint` 只寫模型名稱時 BigQuery 送到非 global，比 global 高一成，見 `caching/README.md`）：3.5-flash-lite 每百萬 Token 輸入 0.33、輸出 2.75 美元，新台幣以 1 美元 32 元換算。第二次執行只呼叫還沒成功的，全部成功時是 0 元。實際費用由 `report.sql` 第 7 段依 Token 數算出。

## 用完後

```bash
bq rm -f -t martech_dw.mm_features_log
```

`mart_creative_features` 是 Day 17 要用的特徵表，`gt_creative_review` 是 Day 20 評測要用的判讀表，`ops_llm_usage` 是 Day 25 要用的用量表，這三張留著。刪掉 `mm_features_log` 之後再跑 `run.sh` 會重新呼叫 48 次。
