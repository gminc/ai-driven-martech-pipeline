# 快取機制實測（Day 10）

把 Day 09 每題都重送的固定內容（角色、候選原因、規則、背景資料）整理成一段 6,234 Token 的文字，實測三種做法的費用：

- `old`：Day 09 的排法，每題的數字在前、固定內容在後
- `new`：固定內容移到最前面，等 Gemini 自動命中（隱含式快取）
- `explicit`：固定內容先建成明確快取，每題只送數字並帶上快取名稱

結果寫進 `martech_dw.cache_runs`。

## 執行

```bash
bash caching/run.sh              # 在儲存庫根目錄執行，會先印出預估費用，輸入 yes 才建快取並呼叫 Gemini
AUTO_YES=1 bash caching/run.sh   # 跳過確認
bash caching/cache.sh list       # 檢查有沒有忘了刪的快取
```

需要先完成 Day 03 的 Terraform（連線 `us.vertex_ai_conn`，服務帳號要有 Vertex AI User 角色）與 Day 09 的 `diag_prompt`，如果照 Day 09 第 5.5 節刪掉了，只要重跑 `diagnosis/summary.sql` 與 `diagnosis/prompt.sql`，不會呼叫 Gemini。

| 檔案 | 內容 | 會呼叫 Gemini |
| --- | --- | --- |
| `context.sql` | 建立 `cache_context`（固定內容一列）、檢視表 `cache_prompt`（每題只剩數字）、實測紀錄表 `cache_runs` | 否 |
| `cost.sql` | 用 `AI.COUNT_TOKENS` 數固定內容與題目長度，估三種做法的最壞情況費用（新台幣） | 否（只數 Token） |
| `cache.sh` | `create`／`delete`／`list` 明確快取，用 curl 呼叫 Vertex AI 的 `cachedContents`，建在 global，存活時間預設 30 分鐘 | 建立時會算一次輸入費 |
| `experiment.sql` | 三種做法 × 3 輪 × 4 題，全部用 `AI.GENERATE` 與同一個 global 端點 | 是，36 次 |
| `check.sql` | 16 項 OK／DIFF：固定內容夠長、每種做法 12 列、沒有錯誤、答案正確、old 不命中、explicit 全命中 | 否 |
| `report.sql` | 三段報表：每一輪的 Token 與費用、三種做法合計、明確快取的兩平呼叫次數 | 否 |
| `run.sh` | context → cost →（確認）→ 建快取 → experiment → 刪快取 → check → report，中途出錯也會刪快取 | |

## 固定內容

| 區塊 | 來源 | 內容 |
| --- | --- | --- |
| 角色、候選原因、規則 | 從 Day 09 `prompt.sql` 搬過來 | 六個候選原因、四條規則 |
| 背景一 商品清單 | `dim_product` | 商品、定價、第一次出現日 |
| 背景二 專案檔期 | `dim_date.promotion_ids` | AUTUMN2026 起訖日 |
| 背景三 素材清單 | `dim_creative` | 30 支素材的通路、廣告群組、受眾、格式、上下檔日、主打商品 |
| 背景四 各廣告群組每週成效 | `fct_ad_daily` | 15 個廣告群組 × 6/22 起每週的點擊、點擊率、每次點擊花費 |

## 2026-09-24 實測（gemini-3.5-flash-lite，每種做法 12 次）

| 做法 | 命中題數 | 輸入 Token | 其中命中 | 輸出 Token | 費用（新台幣） |
| --- | --- | --- | --- | --- | --- |
| old | 0／12 | 78,657 | 0 | 1,357 | 約 0.86 |
| new | 1／12 | 78,657 | 6,016 | 1,519 | 約 0.82 |
| explicit | 12／12 | 78,645 | 74,772 | 1,434 | 約 0.30（含建立與約 6 分鐘儲存費） |

- 三個植入狀況（S1、S2、S3）三種做法共 27 題全部答對；第四筆 meta-evg-prospecting 答案表沒有標準答案，Day 09 沒有背景資料時 flash-lite 判「資料不足」，今天 9 題都選素材疲乏，但只有 3 天資料且呼叫方式不同，不能據此說判斷更準
- 稍早用 Day 09 的遠端模型（`AI.GENERATE_TEXT`）測隱含式快取，第二輪 4 題有 3 題命中；正式實測（`AI.GENERATE`＋global 端點）12 題只命中 1 題，兩次的呼叫方式與間隔都不同，單次實測分不出原因，隱含式快取不保證命中
- 單價（2026-09 官方價目表，global，美元／百萬 Token）：輸入 0.30、快取命中 0.03、輸出 2.50、明確快取儲存每小時 1.00；新台幣以 1 美元約 32 元換算

## 已知限制與注意事項

- `gemini-3.5-flash-lite` 沒有 us-central1 版本，在 us-central1 建快取會回 404，所以快取建在 global
- `AI.GENERATE` 帶快取時，`endpoint` 要寫 global 的完整網址；只寫模型名稱時會出現「Not found: cached content metadata」，看起來是 BigQuery 把請求送到了別的區域
- `endpoint` 用腳本變數會報錯（must be a string literal），只能寫常數，`model_params` 也一併寫成常數，所以 `experiment.sql` 三段各寫一次，專案 ID 與快取名稱由 `run.sh` 代入
- 固定內容要至少 4,096 Token 才能快取（Gemini 3 系列，見官方 [Context caching overview](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/context-cache/context-cache-overview) 的 Limits），明確與隱含式都一樣
- `AI.COUNT_TOKENS` 數出 6,234，建快取時 Vertex 回報 6,231，兩種算法差 3 個 Token，文章與報表以實際命中的 6,231 為準
- 每一輪在會變的那一段開頭加上「檢查批次：第 N 批」（old 等於整題最前面，new 在固定內容之後，explicit 在快取內容之後），模擬每次都是新的一批數字；如果每輪送一模一樣的整段文字，連 old 也可能整段命中
- `thinking_level` 要寫大寫 `"LOW"` 才會通過 BigQuery 的參數檢查（小寫會被擋），但 flash-lite 在 LOW 仍會思考；這種分類題用 `thinking_budget: 0` 比較省
- 明確快取只要還活著就一直收儲存費，`run.sh` 結束時會主動刪除，刪不掉會印警告；手動建的快取記得跑 `bash caching/cache.sh delete`，`cache.sh` 預設存活 30 分鐘，時間到會自動過期
- 手動逐步執行時，建快取和跑 `experiment.sql` 之間不要超過 30 分鐘，否則快取已過期，explicit 12 題會出錯，old、new 照樣計費
- 在 `run.sh` 執行中按 Ctrl+C 會刪快取，但 BigQuery 那邊已送出的查詢會繼續跑、照樣計費，要停止請用 `bq ls -j -a -n 5` 找到工作後 `bq cancel <工作 ID>`
- `cache.sh create` 發現上一次的快取還沒刪（`caching/.cache_name` 還在）時，會先刪掉舊的再建新的
