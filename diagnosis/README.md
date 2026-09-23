# 成效異常診斷（Day 09）

先用 SQL 把「哪裡變了」算成一張異常摘要表，再透過 BigQuery 遠端模型與 `AI.GENERATE_TEXT` 請 Gemini 判讀原因，結果寫進 `martech_dw.mart_diagnosis`。

## 執行

```bash
bash diagnosis/run.sh              # 在儲存庫根目錄執行，會先印出預估費用，輸入 yes 才呼叫 Gemini
AUTO_YES=1 bash diagnosis/run.sh   # 跳過確認
```

需要先完成 Day 03 的 Terraform（連線 `us.vertex_ai_conn`，服務帳號要有 Vertex AI User 角色）與 Day 07 的 `warehouse/build.sh`。

| 檔案 | 內容 | 會呼叫 Gemini |
| --- | --- | --- |
| `summary.sql` | 建立 `diag_summary`：三種角度的異常，群組與素材只留第一次超過門檻的那週，全站逐日判斷 | 否 |
| `prompt.sql` | 建立檢視表 `diag_prompt`：把每一列異常寫成題目 | 否 |
| `cost.sql` | 用 `AI.COUNT_TOKENS` 數題目長度，估算兩個模型各跑一輪的最壞情況費用 | 否（只數 Token） |
| `diagnose.sql` | 建立兩個遠端模型，用 flash-lite 與 3.6-flash 各跑一輪，寫進 `mart_diagnosis` | 是，8 次 |
| `check.sql` | 檢查回答能不能直接使用，16 項 OK／DIFF（含兩個模型都有跑） | 否 |
| `report.sql` | 兩段報表：兩個模型並排、flash-lite 的理由與下一步 | 否 |
| `experiment.sql` | 3.4 的小實驗：拿掉關鍵欄位，比較有沒有「資料不足」選項，結果寫進 `diag_experiment` | 是，8 次 |
| `promo.sql` | 秋日專案前後的專案商品占比，純 SQL | 否 |
| `run.sh` | 依序執行 summary → prompt → cost →（確認）→ diagnose → check → report | |

## 異常的定義

| level | 比較方式 | 門檻 | 為什麼這樣比 |
| --- | --- | --- | --- |
| `adgroup_week` | 廣告群組這週和前四週的點擊成本、點擊率 | 點擊成本變動 ≥ 30%（漲跌都算）或點擊率下降 ≥ 20%，需要至少 2 週基期、這週至少 3 天 | 群組每週追蹤到的購買只有 2–13 筆，ROAS 雜訊太大，點擊成本與點擊率每週有數百到一千多次點擊撐著 |
| `creative_week` | 素材這週和它在資料裡最早 14 天的點擊率 | 下降 ≥ 25%，滿 14 天後才開始比，這週至少 3 天 | 疲乏是慢慢累積的，和上週比永遠不會超過門檻 |
| `site_day` | 全站每天網站追蹤到的購買、後台訂單，各自和前七天平均比（以有投廣告的日子為主表，零訂單的日子也會留下） | 任一項 ≤ 一半，需要至少 5 天基期 | 兩個來源並排才分得出追蹤壞掉和真的沒生意 |

門檻寫在 `summary.sql` 的 WHERE 條件裡（0.30、-0.20、-0.25、0.5），調整後重跑即可；群組與素材每個對象只留第一次超過門檻的那週，全站每一天各自判斷。

## 題目與回答格式

- 題目只放數字與六個候選原因（競價變貴、追蹤碼失效、素材疲乏、需求或季節變化、其他、資料不足），不寫「什麼數字代表什麼原因」的判斷規則
- `AI.GENERATE_TEXT` 的輸入欄位一定要叫 `prompt`，其他欄位會原樣帶到輸出；輸出是 `result`、`statistics`（Token 數）、`status`（空字串＝呼叫成功）等欄位
- `model_params` 用 `response_schema` 鎖成 JSON：`cause`（enum）、`evidence`、`confidence`、`next_check`
- `max_output_tokens` 512、`thinking_budget` 0

## 2026-09-23 實測

| 對象 | 答案表 | flash-lite | 3.6-flash |
| --- | --- | --- | --- |
| meta-trn-prospecting 8/10 週（點擊成本 7.55→13.42 元） | S1 競價變貴 | 競價變貴 0.90 | 競價變貴 0.90 |
| 全站 8/27（追蹤購買 0、後台訂單 37） | S2 追蹤碼失效 | 追蹤碼失效 0.95 | 追蹤碼失效 0.95 |
| cr-meta-evg-p1 7/20 週（點擊率 −31%） | S3 素材疲乏 | 素材疲乏 0.85 | 素材疲乏 0.85 |
| meta-evg-prospecting 9/14 週（點擊率 −21%，只有 3 天） | S3 所在群組 | 資料不足 0.90 | 素材疲乏 0.80 |

- `AI.COUNT_TOKENS` 數出 4 題共 1,178 個 Token，實際計費輸入 1,779 個，每題多約 150 個是 `response_schema`
- flash-lite 一輪：輸入 1,779、輸出 418 個 Token，約 US$0.0016；3.6-flash 一輪：輸入 1,779、輸出 514 個 Token，約 US$0.0033（單價依 2026-09 官方價目表，global 區域，us 多區域端點略高）
- `cost.sql` 估的最壞情況：flash-lite US$0.0057＋3.6-flash US$0.0090＝US$0.0147，實際約 US$0.0049
- `check.sql` 16 項全部通過
- 以上是合成資料、每個模型只跑一次的結果，訊號比真實資料乾淨；flash-lite 那一輪執行時沒有帶 `thinking_config`（statistics 顯示思考 Token 為 0），`diagnose.sql` 現在統一設 `thinking_budget` 0

## 已知限制與注意事項

- `gemini-3.6-flash` 預設會思考，思考 Token 算在 `max_output_tokens` 裡：不設 `thinking_budget` 時每題思考約 488 個，512 的上限只剩 5–10 個給答案，JSON 被截斷但 `status` 仍是空字串；`thinking_level` 目前會被 BigQuery 的參數檢查擋下（Found invalid JSON model params），要用 `thinking_budget`
- AI 的回答每次執行可能略有不同，`diagnose.sql` 會整張重建 `mart_diagnosis`，每跑一次就重新計費一次，要保留舊結果請先另存
- 答案表（`synthesizer/ground_truth.json`）只用來在事後比對，SQL 與題目都沒有讀取
