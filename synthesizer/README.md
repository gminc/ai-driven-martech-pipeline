# 電商大數據合成器（軌道 B）

Day 05、Day 06 的程式碼，產生「織日常」90 天、約 50 萬筆事件的跨通路合成資料，商品、價格、尺寸與活動直接讀 `../live-demo/products.json`，所以和 Live Demo 的真實事件用的是同一套 ID。

只用 Python 標準函式庫，Cloud Shell 內建的 `python3` 可以直接執行，不需要 `pip install`。

## 執行

```bash
cd synthesizer
python3 synthetic_pipeline.py --days 7 --out ./sample   # 先跑一週
python3 synthetic_pipeline.py --out ./out               # 完整 90 天（約 10–20 秒）
python3 validate.py ./out                                # 檢查完整性、統計目標與植入的訊號（PASS／FAIL／SKIP）
python3 -m unittest discover -s tests -v                 # 單元測試（約 1 分鐘，過程中的 usage 錯誤訊息是刻意觸發的）
```

| 參數 | 預設 | 說明 |
| --- | --- | --- |
| `--start` | 2026-06-19 | 起始日，預設期間到 9/16，9/17 起由 Live Demo 的真實事件接手 |
| `--days` | 90 | 天數 |
| `--seed` | 20260919 | 亂數種子，同一個種子輸出完全相同 |
| `--out` | ./out | 輸出資料夾 |

## 載入 BigQuery 與對帳（Day 06）

`bigquery/` 把 90 天資料用批次載入工作灌進 `martech_dw` 的五張 raw 表，再用兩邊對帳確認搬運後資料沒有變。

```bash
bash bigquery/load.sh                  # 產生（若 ./out 不存在）→ validate.py → 核對標題順序 → 載入 → 比對列數
python3 bigquery/reconcile.py ./out    # 本機與 BigQuery 各算 55 項指標逐項比對
```

| 檔案 | 內容 |
| --- | --- |
| `bigquery/schemas/raw_*.json` | 五張表的明確綱要，不用自動偵測 |
| `bigquery/load.sh` | 確認 gcloud 登入與資料集、本機驗證、依綱要載入（`--replace`），最後比對列數 |
| `bigquery/verify.sql` | 在 BigQuery 端算指標，參數由 reconcile.py 從 `ground_truth.json` 帶入 |
| `bigquery/reconcile.py` | 本機從 CSV 算同一份指標並比對，整數與字串完全相同、浮點數容許 1e-9 相對誤差 |

型別的幾個決定：

- `event_date` 用 STRING、`event_timestamp` 用 INT64、`value` 用 FLOAT64，和 GA4 匯出表一致，Day 07 合併真實事件時不用轉型
- `user_pseudo_id` 與 `phone` 必須是 STRING，自動偵測會分別判成 FLOAT 與 INTEGER，造成尾數被捨去與開頭的 0 消失
- `cost` 用 NUMERIC、訂單金額用 INT64、`order_ts` 用 TIMESTAMP（CSV 帶 `+08:00`）、`has_person` 用 BOOL
- 主鍵與時間欄位設成 REQUIRED，缺值就讓載入工作失敗

55 項指標分成列數與總量 23 項、期間與型別 9 項、統計分佈 5 項、七個訊號 18 項。S5 的顧客類型（`ground_truth/customer_segments.csv`）不載入倉儲，倉儲這一側只比對每位顧客的訂單數分佈。批次載入不收費，五張表約 63.5 MiB，對帳查詢約處理 43 MB。

## 資料契約

三份設定檔就是契約，改設定不用改程式：

| 檔案 | 內容 |
| --- | --- |
| `../live-demo/products.json` | 商品 ID、定價、尺寸、活動與 promotion_id（和 Live Demo 共用） |
| `creatives.json` | 30 則素材：24 則圖片（meta、line）與 6 則搜尋文字廣告，含上線／下檔日、圖片的設計屬性與生圖提示詞，四個屬性在同一受眾內各自平均分配 |
| `ground_truth.json` | 七個植入的訊號與參數，同時是之後分析篇的標準答案 |

## 輸出

| 檔案 | 粒度 | 欄位 |
| --- | --- | --- |
| `raw_creatives.csv` | 素材 | creative_id、channel、utm_campaign、promotion_id、ad_group_id、audience、format、start_date、product_focus、has_person、cta_position、dominant_color、text_density、image_file |
| `raw_ad_daily.csv` | 日 × 素材 | date、creative_id、ad_group_id、channel、utm_campaign、impressions、clicks、cost |
| `raw_events.csv` | 事件 | event_date（YYYYMMDD）、event_timestamp（UTC 微秒）、event_name、user_pseudo_id、ga_session_id、customer_id、utm_source、utm_medium、utm_campaign、creative_id、promotion_id、item_id、item_variant、quantity、value、transaction_id、data_source |
| `raw_orders.csv` | 訂單 | transaction_id、order_ts（台北時間）、order_date、customer_id、user_pseudo_id、item_id、item_variant、quantity、unit_price、revenue、utm_source、utm_medium、utm_campaign、payment_status |
| `raw_customers.csv` | 顧客 | customer_id、name、email、phone、city、first_order_date |
| `ground_truth/customer_segments.csv` | 顧客 | customer_id、segment（答案，分析時不讀） |

`raw_events` 是 GA4 BigQuery 匯出表攤平後的形狀：欄位命名照匯出表（`event_date`、`event_timestamp`、`user_pseudo_id`），但真實匯出表裡 `ga_session_id` 在 `event_params`、商品資料在 `items` 陣列、來源在 `collected_traffic_source`，Day 07 會用 UNNEST 把真實事件攤成同樣形狀再合併，`event_name` 只用 GA4 自動事件（first_visit、session_start）與 Day 04 送出的電子商務事件，`data_source` 固定為 `synthetic`，之後和真實 GA4 事件合併時用來區分。

## 模擬流程

1. **廣告每日成效**：每張素材依通路基準曝光、點擊率、單次點擊成本產生每日數字，點擊率乘上設計屬性效果（S4）與素材疲乏（S3），成本乘上 CPC 異常（S1）
2. **造訪**：點擊中約 90% 真的載入頁面，再加上自然搜尋、直接進站與電子報的造訪
3. **訪客**：每個通路帶來新訪客的比例不同（S6），回訪名單保留近 14 天來過、還沒買的人，但每次只從名單最後 400 筆裡挑回訪者（約為最近幾個小時的訪客，所以首購路徑多半在同一天內走完，見 Day 08 的 attribution/README.md），造訪次數越多成交機率越高
4. **成交**：首購時決定顧客類型（S5），類型決定品項、數量與回購節奏，秋日專案期間專案商品權重提高（S7）
5. **事件**：每次造訪依序展開 session_start → view_item_list／view_promotion → select_item／select_promotion → view_item → begin_checkout → purchase，first_visit、session_start 的時間等於工作階段開始時間，purchase 的時間等於訂單成立時間，S2 當天（台北時間）的 purchase 事件不寫入，但訂單照常成立
6. **時間一致性**：一天內的造訪先抽好時間再依序處理，同一人兩次工作階段至少相隔 31 分鐘（GA4 的工作階段逾時是 30 分鐘），最後一天深夜跨到隔天的事件與訂單會被截掉

## 七個植入的訊號

| 代號 | 訊號 | 預計在哪一天被找回來 |
| --- | --- | --- |
| S1 | meta 重訓襪專案開發新客廣告群組 8/12 起 CPC 翻倍、轉換機率不變（ROAS 理論上腰斬，實際受訂單數少的雜訊影響） | Day 09、24、28 |
| S2 | 8/27 purchase 事件整天沒送出，訂單照常成立 | Day 09、24 |
| S3 | `cr-meta-evg-p1` 點擊率自 6/19 起每週衰退約 8% | Day 09、17 |
| S4 | 圖片有人物 ×1.25、CTA 在右下 ×1.10、暖色系 ×1.10（再行銷受眾 CTR ×1.3 是混淆因素，分析時要控制受眾並排除 S3 素材） | Day 17、18、20 |
| S5 | 四種顧客類型：高頻買襪、浴巾大量一次性、組合包新客、沉睡客（沉睡客不回購） | Day 11、12 |
| S6 | meta 集中在路徑開頭、google 搜尋集中在最後一步 | Day 08 |
| S7 | 9/1–9/16 秋日專案期間專案商品占比上升（包含專案素材帶來的流量與商品權重提高兩個來源） | Day 08、09 |

## validate.py

每項檢查印出 PASS、FAIL 或 SKIP，資料期間不涵蓋某個訊號（例如只跑 7 天）時印 SKIP 不算失敗，統計量與事件量只在預設 90 天時檢查。訊號檢查的門檻從 `ground_truth.json` 推算，S4 在同通路、同受眾內比較素材層級 CTR 並排除 S3 素材。

## 已知簡化

- 一筆訂單只有一個品項，和 Live Demo 的結帳流程一致
- 一個顧客只對應一個 `user_pseudo_id`，不模擬跨裝置
- 每次造訪的事件依序發生，不模擬同一工作階段內多開分頁造成的事件穿插
- 只產生 GA4 自動事件中的 first_visit 與 session_start，沒有 page_view、user_engagement
- 秋日專案的素材 9/16 下檔，用更長的 `--days` 時專案不會延續
- 姓名、email、手機都是假資料，email 一律用保留網域 `example.com`
