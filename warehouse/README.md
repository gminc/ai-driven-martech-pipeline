# warehouse：星狀綱要（Day 07）

把 `martech_dw` 的五張 raw 表與 GA4 每日匯出表整理成三張事實表、四張維度表，並做合併前後對帳。

## 用法

```bash
cd ~/ai-driven-martech-pipeline
bash warehouse/build.sh
```

腳本會依序確認 gcloud 登入狀態、raw 表與 GA4 匯出資料集是否存在、兩個資料集位置是否相同，接著執行 `ddl.sql`、`build.sql`、`check.sql`，最後印出對帳報表，有任何一項不一致就以非零狀態結束。

## 檔案

| 檔案 | 內容 |
| --- | --- |
| `ddl.sql` | 七張表的綱要、欄位說明、分區與叢集，`CREATE OR REPLACE` 可重跑 |
| `build.sql` | GA4 攤平、合成資料與 GA4 合併、維度表整理，每張表先 `TRUNCATE` 再 `INSERT` |
| `check.sql` | 合併前後對帳，before 讀 raw 表與 GA4 巢狀原始表，after 讀星狀綱要 |
| `build.sh` | 一鍵執行與報表輸出，GA4 資料集名稱自動偵測，不寫進儲存庫 |

## 表格一覽

| 表 | 粒度 | 分區 | 叢集 | 備註 |
| --- | --- | --- | --- | --- |
| `fct_ad_daily` | 日 × 素材 | `date` | `channel`, `creative_id` | 保留 `channel` 作為叢集欄位 |
| `fct_events` | 一個事件 | `event_dt` | `event_name`, `user_pseudo_id` | `require_partition_filter = TRUE`，`data_source` 為 `synthetic` 或 `ga4` |
| `fct_orders` | 一筆訂單 | `order_date` | `customer_id` | Live Demo 站沒有訂單資料庫，只有合成資料 |
| `dim_date` | 一天 | 無 | 無 | `promotion_ids` 為當天進行中的專案 |
| `dim_creative` | 一則素材 | 無 | 無 | S4 素材屬性分析用 |
| `dim_customer` | 一位顧客 | 無 | 無 | 不含姓名、email、手機 |
| `dim_product` | 一項商品 | 無 | 無 | 最常見成交單價、主打過的專案 |

## GA4 攤平規則

| GA4 欄位 | fct_events 欄位 | 規則 |
| --- | --- | --- |
| `event_params.ga_session_id` | `ga_session_id` | `int_value`，字串時轉整數 |
| `collected_traffic_source.manual_*`、參數 `source`／`medium`／`campaign` | `utm_*` | 同一工作階段內取第一個帶 UTM 的事件，三欄同一事件取值；都沒有時為 `(direct)`／`(none)`／`(direct)` |
| 參數 `creative_name`、`promotion_id` | `creative_id`、`promotion_id` | 字串參數 |
| `items` | `item_id`、`item_variant`、`quantity`、`item_count` | 只有一項商品時才展開，`(not set)` 轉 NULL，`item_count` 為項數 |
| 參數 `value` | `value` | `int_value`、`double_value`、`float_value` 三者取有值者 |
| `ecommerce.transaction_id`、參數 `transaction_id` | `transaction_id` | `(not set)` 轉 NULL |
| `user_id` | `customer_id` | 目前 Live Demo 站未設定 |

- 萬用字元使用 `events_2*` 並檢查後綴為 7 位數字，排除 `events_intraday_*`
- `user_pseudo_id` 為 NULL 的事件（consent mode 無 Cookie 事件）不進事實表，對帳報表以 `info.` 列出筆數

## 對帳項目

列數（七張表）、廣告花費與曝光點擊、訂單金額、合成資料的訪客數、工作階段數、轉換率與客單價、GA4 的訪客數、工作階段數、交易數、購買金額、商品項數、各事件名稱逐項比對，以及時區換算、參照完整性、維度表不含個資、分區與叢集欄位設定。以 `info.` 開頭的項目只列數字不判定。
