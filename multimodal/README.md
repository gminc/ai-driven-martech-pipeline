# multimodal：讓 BigQuery 看得到素材圖（Day 14）

Day 14 把 24 張圖片素材放進 Cloud Storage、在 BigQuery 建物件表，再用 `AI.GENERATE` 讓 Gemini 直接看圖、自由描述，看圖片能不能變成查得到的資料。
這一天只做自由描述，結構化輸出留給 Day 15，素材屬性和點擊率的關係留給 Day 17。

## 檔案

| 檔案 | 做什麼 | 收費 | 讀答案表 |
| --- | --- | --- | --- |
| `object_table.sql` | 建物件表 `obj_creatives`，只記錄 bucket 裡每張圖的路徑、大小、類型、更新時間 | 免費額度內 | 否 |
| `demo.sql` | 挑三張示範圖存成 `mm_demo` | 免費額度內 | 否 |
| `describe.sql` | 三張圖各問四輪，共 12 次，存成 `mm_describe` | Gemini Token 費 | 否 |
| `check.sql` | 10 項流程檢查（`run.sh` 再補 1 項） | 免費額度內 | 否 |
| `report.sql` | 五段報表：點擊率、描述並排、Token、能不能分組、費用 | 免費額度內 | 否 |
| `run.sh` | 依序執行，呼叫 Gemini 前先印最壞費用並要求輸入 yes | — | — |

`dim_creative` 裡的 `has_person`、`cta_position`、`dominant_color`、`text_density` 是合成資料才有的設計規格（素材圖照 `synthesizer/creatives.json` 畫出來，Day 16 抽特徵、Day 20 評測拿它當標準答案），真實的廣告後台沒有這幾欄，`report.sql` 第 4 段只拿它們檢查描述準不準。

## 前置

1. 先 `git pull` 取得 Day 14 的程式與 Terraform 設定
2. Terraform 已建立素材 bucket `<專案 ID>-martech-assets`（us-central1），並把 BigQuery 連線 `us.vertex_ai_conn` 的服務帳號加上這個 bucket 的 `roles/storage.objectViewer`（`terraform/main.tf` 的 `bq_connection_assets_viewer`，Day 14 新增，Day 13 以前建好的環境要在 `terraform/` 再 `terraform apply` 一次，權限生效可能要等幾分鐘）
3. 上傳素材圖：

```bash
cd ~/ai-driven-martech-pipeline && gcloud storage cp creatives/images/*.jpg gs://$(gcloud config get-value project)-martech-assets/creatives/
```

4. bucket 在 Day 03 設了生命週期規則，現行物件 90 天後刪除，素材圖也適用，過期後重跑要再上傳一次

## 單獨建物件表

`object_table.sql` 裡的 bucket 寫成 `PROJECT_ID`，`run.sh` 會自動換成目前的專案，自己執行時在 `multimodal/` 底下：

```bash
sed "s/PROJECT_ID/$(gcloud config get-value project)/" object_table.sql | bq query --nouse_legacy_sql --format=pretty
```

## 看圖的寫法

```sql
SELECT
  AI.GENERATE(
    ('這是一張電商廣告圖，請用繁體中文描述它……', ref),
    connection_id => 'us.vertex_ai_conn',
    endpoint => 'gemini-3.5-flash-lite',
    model_params => JSON '{"generation_config": {"max_output_tokens": 1024, "thinking_config": {"thinking_budget": 0}}}'
  ) AS g
FROM martech_dw.obj_creatives
JOIN martech_dw.mm_demo USING (uri);  -- 只看三張示範圖，拿掉就會對 24 張各呼叫一次
```

- 題目寫成一個括號包起來的組合，文字和物件表的 `ref` 欄並列，BigQuery 透過連線去 bucket 讀圖交給 Gemini，不用自己產生簽署網址
- 回傳的 `g.result` 是文字、`g.full_response` 是完整回應（Token 用量在 `$.usage_metadata`）、`g.status` 空字串代表成功
- `endpoint` 與 `model_params` 只能寫常數，所以 `describe.sql` 四輪各寫一段
- 低解析度：`generation_config` 加 `"media_resolution": "MEDIA_RESOLUTION_LOW"`

## 2026-09-27 實測

| 模型 | 解析度 | 每次輸入 Token | 平均輸出 | 12 次裡的次數 | 新台幣 |
| --- | --- | --- | --- | --- | --- |
| gemini-3.5-flash-lite | 預設 | 1,144 | 120 | 6 | 0.123 |
| gemini-3.5-flash-lite | 低 | 316 | 118 | 3 | 0.037 |
| gemini-3.6-flash | 預設 | 1,144 | 121 | 3 | 0.126 |

- 1200×628 的圖在預設解析度算 1,104 個 Token、低解析度 276 個，題目文字約 40 個
- 12 次合計新台幣 0.29 元（1 美元＝32 元，單價 3.5-flash-lite 輸入 0.30／輸出 2.50、3.6-flash 0.75／3.75 美元每百萬 Token）
- `run.sh` 11 項檢查全部通過

## 清理

```bash
bq rm -f -t martech_dw.mm_demo
bq rm -f -t martech_dw.mm_describe
```

物件表 `obj_creatives` 和 bucket 裡的圖 Day 15–20 還會用，先留著。
