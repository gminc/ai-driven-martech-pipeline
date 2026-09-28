# structured：讓 Gemini 看圖交出固定欄位（Day 15）

Day 14 讓 Gemini 自由描述三張圖，結果每段都不一樣、GROUP BY 只能得到 12 組。Day 15 改成規定欄位，讓每一張圖變成一列可以查詢、可以分組的資料，並比較兩種鎖格式的寫法：`AI.GENERATE` 的 `output_schema` 鎖型別，`model_params` 裡的 `response_schema` 用 enum 鎖選項。

## 檔案

| 檔案 | 做什麼 | 收費 | 讀答案表 |
| --- | --- | --- | --- |
| `move_design.sql` | 四個設計欄位從 `dim_creative` 搬進答案表 `martech_gt.gt_creative_design`（加圖上標題），`dim_creative` 拿掉這四欄，可重複執行 | 免費額度內 | 建答案表 |
| `sample.sql` | 挑六張樣本圖存成 `mm_sample` | 免費額度內 | 否 |
| `extract.sql` | 六張圖各跑五輪，共 30 次，存成 `mm_structured` | Gemini Token 費 | 否 |
| `check.sql` | 10 項流程檢查（`run.sh` 再補 1 項） | 免費額度內 | 否 |
| `report.sql` | 六段報表：能不能分組、超出選項、逐張對答案、各輪答對幾張、兩次一不一樣、費用 | 免費額度內 | 第 3、4 段 |
| `run.sh` | 依序執行，呼叫 Gemini 前先印最壞費用並要求輸入 yes | — | — |

## 為什麼要先搬家

`has_person`、`cta_position`、`dominant_color`、`text_density` 是合成器畫圖時照的規格（`synthesizer/creatives.json`、`creatives/compose.py`），等於「這張圖長什麼樣子」的標準答案。Day 07 建 `dim_creative` 時把它們放進了分析資料集 `martech_dw`，之後任何分析 SQL 只要 JOIN 一下就拿得到答案，也不會被各目錄 `run.sh` 只認 `martech_gt` 字串的檢查擋下來，和 Day 11 到 Day 13 建立的「答案只放在 `martech_gt`」原則不一致。Day 15 起答案表是 `martech_gt.gt_creative_design`，`dim_creative` 沒有這四欄（`warehouse/ddl.sql`、`build.sql` 已同步），Day 14 的 `multimodal/report.sql` 第 4 段改讀答案表。`raw_creatives` 是 Day 06 原樣載入的檔案，欄位不動，分析 SQL 一律不讀它。

`headline` 由 `move_design.sql` 依主打商品對照 `compose.py` 的文案填入，讓標題可以逐字對。

## 五輪的設計

| 輪 | 鎖法 | 題目 | 模型 | 看什麼 |
| --- | --- | --- | --- | --- |
| A | `output_schema` | 只列欄位與選項 | 3.5-flash-lite | 只鎖型別時值會不會超出選項 |
| B1 | `output_schema` | 加判斷標準 | 3.5-flash-lite | 對 A：判斷標準有沒有用 |
| B2 | 同 B1 | 同 B1 | 3.5-flash-lite | 對 B1：同一張圖兩次一不一樣 |
| C | `response_schema` enum | 同 B | 3.5-flash-lite | 對 B1：enum 有沒有用 |
| D | 同 C | 同 B | 3.6-flash | 換模型對照 |

六張樣本圖是照「四個設計欄位每一個值都至少出現一次」挑的，含 Day 14 的三張示範圖。`max_output_tokens` 設 256，五個欄位的 JSON 不到 100 個 Token，`check.sql` 第 10 項確認沒有一次撞到上限。六張是抽查，正式正確率留給 Day 20。

## 前置

1. 先 `git pull`
2. 已完成 Day 14（物件表 `obj_creatives`、bucket 裡 24 張圖）與 Day 13（答案資料集 `martech_gt`）
3. `gcloud auth list` 有星號的帳號、`gcloud config get-value project` 印出專案 ID

## 執行

```bash
cd ~/ai-driven-martech-pipeline && git pull && bash structured/run.sh
```

## 費用

最壞情況：30 次呼叫，每次輸入以 1,600 個 Token（一張圖 1,104、題目與判斷標準約 300、`response_schema` 約 150）、輸出以上限 256 計，3.5-flash-lite 24 次加 3.6-flash 6 次約 US$ 0.044 ≈ 新台幣 1.4 元。單價用非 global 端點（`endpoint` 只寫模型名稱時 BigQuery 送到非 global，比 global 高一成，見 `caching/README.md`）：3.5-flash-lite 每百萬 Token 輸入 0.33、輸出 2.75 美元，3.6-flash 輸入 0.825、輸出 4.125 美元，新台幣以 1 美元 32 元換算。實際費用由 `report.sql` 第 6 段依 Token 數算出。

## 用完後

```bash
bq rm -f -t martech_dw.mm_sample
bq rm -f -t martech_dw.mm_structured
```

`gt_creative_design` 是 Day 16、17、20 的答案表，留著，`dim_creative` 的四欄拿掉後不要加回去。
