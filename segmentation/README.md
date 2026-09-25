# 顧客分群（Day 11）

把每位顧客的訂單整理成一列購買行為特徵，用 BigQuery ML 的 K-means 分群，再和 Day 05 合成器藏進去的四種顧客類型對照。

- 訓練只用首購後觀察滿 30 天的顧客（資料最後一天 9/16，首購在 8/17（含）以前的 1,458 人）
- 所有 2,461 位顧客都會分到最近的群，寫進 `martech_dw.mart_customer_segment`，`observed_30d` 標出觀察未滿 30 天的人
- 答案表放在獨立資料集 `martech_gt`，只有 `reveal.sql`、`reveal_models.sql`、`check.sql` 會讀

## 執行

```bash
bash segmentation/run.sh              # 在儲存庫根目錄執行，印出預估費用後輸入 yes 才建模型
bash segmentation/run.sh --compare    # 另外建 3 群、5 群、全部顧客 4 群三個對照模型
AUTO_YES=1 bash segmentation/run.sh   # 跳過確認
```

需要先完成 Day 07（`martech_dw.fct_orders`），答案表不存在時 `run.sh` 會呼叫 `scripts/load_ground_truth.sh` 載入，這一步需要 Cloud Shell 裡有 Day 05 合成器的輸出 `synthesizer/out/ground_truth/`，沒有的話用固定種子重跑一次合成器會得到同一份。

| 檔案 | 內容 | 讀答案表 | 費用 |
| --- | --- | --- | --- |
| `features.sql` | 建立 `seg_features`，一位顧客一列 10 個特徵，另有 `observed_30d`、`first_order_date` 等輔助欄位 | 否 | 免費額度內 |
| `model.sql` | 正式模型 `seg_kmeans_k4`：4 群、KMEANS++、標準化，只用觀察滿 30 天的人訓練 | 否 | 約 NT$ 0.1 |
| `predict.sql` | `ML.PREDICT` 把所有顧客分群，寫進 `mart_customer_segment` | 否 | 免費額度內 |
| `profile.sql` | 每一群的人數、訂單數、回購率、營收、品類占比，以及 `ML.CENTROIDS` 群中心 | 否 | 免費額度內 |
| `compare.sql` | 對照模型 `seg_kmeans_k3`、`seg_kmeans_k5`、`seg_kmeans_k4_all`（全部顧客訓練） | 否 | 約 NT$ 0.3 |
| `evaluate.sql` | 四個模型的 Davies-Bouldin 指標，需先跑 `compare.sql` | 否 | 免費額度內 |
| `reveal.sql` | 正式模型的分群 × 答案表，分觀察滿 30 天與未滿 30 天兩段 | 是 | 免費額度內 |
| `reveal_models.sql` | 把 `MODEL_NAME` 換成對照模型名稱，看觀察滿 30 天的人怎麼分 | 是 | 免費額度內 |
| `check.sql` | 7 項 OK／DIFF：列數、空值、群數、浴巾大量客與新手組合客集中在同一群的比例（只檢查每次重建都穩定的項目） | 是 | 免費額度內 |
| `run.sh` | features →（確認）→ model → predict →（compare）→ check＋答案表隔離檢查 → profile → reveal | | |

## 特徵

| 欄位 | 說明 |
| --- | --- |
| `order_count`、`total_qty`、`total_revenue` | 訂單數、總件數、總營收 |
| `first_qty` | 首購件數 |
| `share_sock`、`share_bath`、`share_face`、`share_set` | 四個品類的件數占比，加總為 1 |
| `avg_gap_days` | 平均回購間隔，只買一次的人填「首購到基準日的天數」，不留空（BigQuery ML 會用平均值補空值） |
| `recency_days` | 最後一次下單到基準日的天數 |

基準日取 `fct_orders` 的最後一天，縣市與通路不放進特徵。

## 9/24 實測（觀察滿 30 天的 1,458 人）

| 模型 | Davies-Bouldin |
| --- | --- |
| k3 | 1.480 |
| k4（正式） | 1.058 |
| k5 | 1.365 |
| k4_all（全部顧客訓練） | 1.379 |

- k4 依品類分成組合、洗臉巾、浴巾、襪子四群，浴巾大量客 191 人與高頻買襪客 474 人各自全部集中在一群，沉睡客 518 人散在四群
- k5 有一群 436 人平均只下單 1 次，其中 359 人是沉睡客
- 觀察未滿 30 天的 1,003 人容易被分進有回購的襪子群：k5 有 248 個沉睡客、k4_all 有 176 個沉睡客被這樣分
- 每個 `CREATE MODEL` 實際處理約 0.2 MB，照最低 10 MB 計費一次，不因迭代次數重複收費
- KMEANS++ 仍有隨機成分，9/25 發文前重建 k4 得到另一種分法：DBI 1.235，浴巾客一樣自成一群，襪子客改依有沒有回購拆成兩群（300／174 位高頻買襪客）、組合與洗臉巾併成一群，文章以 9/24 那次為正式結果，要看輪廓認群
