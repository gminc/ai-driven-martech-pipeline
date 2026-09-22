# 多觸點歸因（Day 08）

把 `martech_dw.fct_events` 的造訪串成每筆訂單的購買路徑，用第一次接觸、最後接觸、時間衰減三種規則分配功勞，結果寫進 `martech_dw.mart_attribution`。

## 執行

```bash
bash attribution/run.sh      # 在儲存庫根目錄執行，需先完成 Day 07 的 bash warehouse/build.sh
```

| 檔案 | 內容 |
| --- | --- |
| `build.sql` | 建立 `mart_attribution`（CREATE OR REPLACE，可重跑） |
| `check.sql` | 功勞守恆、功勞位置與路徑正確性檢查，14 項 OK／DIFF＋1 項 INFO；改了回溯天數要一起改裡面的 30 |
| `report.sql` | 五段報表：direct 的影響、首購主表、路徑長度、路徑天數、秋日專案 |
| `run.sh` | 依序執行上面三份，檢查有任何 DIFF 就以非 0 結束 |

## 定義

| 項目 | 設定 | 說明 |
| --- | --- | --- |
| 轉換 | `fct_orders` 的每一筆訂單 | 不用 purchase 事件，8/27 的 purchase 事件整天沒送出（S2），訂單照常成立 |
| 觸點 | 每一次 `session_start` | 通路＝`utm_source / utm_medium`，另保留 `utm_campaign` |
| 回溯窗口 | 30 天 | 只看下單前 30 天內的造訪，參數在 `build.sql` 開頭 |
| 回購 | 路徑從上一筆訂單之後重新起算 | `is_repeat` 標記第二筆以後的訂單 |
| 截斷 | `window_truncated` | 下單日往前 30 天早於資料起點（6/19），路徑可能不完整 |
| 同時間排序 | 依時間、再依通路名稱與活動 | 避免同一時間的觸點每次跑出不同順序 |
| 資料來源 | 只用 `data_source = 'synthetic'` | GA4 真實事件目前沒有訂單可以歸因 |

## 三種規則

| 欄位 | 規則 |
| --- | --- |
| `credit_first` | 路徑第一個觸點拿 1 |
| `credit_last` | 路徑最後一個觸點拿 1 |
| `credit_decay` | 權重 `0.5 ^ (距離下單天數 / 7)`，再除以整條路徑的權重總和，半衰期 7 天 |

每種規則各有一個 `_nd` 版本（direct 不算觸點）：路徑上有其他通路時 direct 拿 0，整條路徑都是 direct 才把功勞給 direct，其中 `credit_last_nd` 的做法和 GA 的最終非直接點擊（GA4 的跨管道最後點擊）相同。

同一筆訂單的六個功勞欄位各自加總都是 1，所以任何一種規則的功勞總和都等於訂單數，乘上 `revenue` 加總就等於營收，`check.sql` 逐筆檢查這件事；守恆只抓得到漏算或重複算，所以另外檢查第一次／最後接觸的功勞落在路徑的頭尾、回購路徑沒有跨過上一筆訂單。

## 表結構

`mart_attribution` 的粒度是「一筆訂單 × 路徑上的一個觸點」，依 `order_date` 分區、`channel` 叢集。

| 欄位 | 說明 |
| --- | --- |
| `order_date`、`transaction_id`、`order_ts`、`customer_id`、`user_pseudo_id`、`item_id`、`revenue` | 訂單資訊，同一筆訂單的每一列都相同 |
| `order_seq`、`is_repeat` | 這位訪客的第幾筆訂單 |
| `window_truncated` | 回溯窗口是否被資料起點截斷 |
| `touch_seq`、`path_len` | 觸點在路徑中的順序與路徑長度 |
| `touch_ts`、`days_before_order` | 觸點時間與距離下單的天數 |
| `channel`、`utm_campaign`、`is_direct` | 觸點來源 |
| `credit_first`、`credit_last`、`credit_decay` | direct 也算觸點 |
| `credit_first_nd`、`credit_last_nd`、`credit_decay_nd` | direct 不算觸點 |

## 2026-09-22 實測

- 3,304 筆訂單全部歸因，9,043 列觸點，營收 2,056,430 元，14 項檢查全部通過
- 建表處理 58.9 MB、計費 80.7 MB（每個陳述式讀到的每張表最低計費 10 MiB），檢查處理 1.4 MB、計費 21.0 MB，報表實測的兩段處理 0.2–0.7 MB，每段計費 10.5 MB（最低計費）
- 首購且回溯窗口完整的 1,833 筆訂單（direct 不算觸點）：

| 通路 | 第一次接觸 | 最後接觸 | 時間衰減 |
| --- | ---: | ---: | ---: |
| meta / paid_social | 610 | 385 | 507.2 |
| line / display | 545 | 324 | 454.5 |
| google / organic | 333 | 404 | 355.2 |
| google / cpc | 295 | 670 | 466.1 |
| (direct) / (none) | 50 | 50 | 50 |

## 已知限制

- 合成器的回訪名單保留近 14 天來過、還沒下單的訪客，但每次只從名單最後的 400 筆裡挑回訪者，合成資料一天有一千多次造訪，所以首購路徑幾乎都在同一天內走完（首購且窗口完整的 1,399 筆多觸點訂單，第一個觸點距離下單中位數 0.188 天、第 90 百分位 0.541 天；2,461 位買家只有 41 位首購距離第一次造訪超過一天），半衰期 7 天時時間衰減的權重接近平均分配；真實電商的考慮期通常以天計，半衰期要依自家從第一次造訪到下單的天數分佈來設
- 只有規則式歸因，GA4 的數據驅動歸因需要足夠的轉換量與 Google 自己的模型，不在這裡重現
