# monitoring：把 Token 用量表變成成本儀表板（Day 25）

Day 16 起每一次拿得到用量的模型呼叫都寫進 `martech_dw.ops_llm_usage`，這裡用一張單價表和兩個 view 把它換算成費用，給 Data Studio（原 Looker Studio）當儀表板的資料來源，全程不呼叫模型。

文章：[Day 25｜每天被 AI 扣了多少 Token？打開儀表板一目了然](../docs/articles/day25-token-cost-dashboard.md)

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `price.sql` | 單價對照表 `ref_llm_price`，一列是一個模型在一種端點、一段期間的每百萬 Token 美元單價 |
| `views.sql` | `v_llm_usage_calls`（一列一次呼叫，加上台北日期、單價與費用）、`v_llm_usage_daily`（儀表板接這個） |
| `check.sql` | 12 項檢查：view 有沒有把用量表原樣帶出來、單價期間有沒有重疊、有沒有對不到單價的呼叫 |
| `report.sql` | 四段報表：每一篇、每一天、每個模型與端點、對不到單價的呼叫 |
| `probe.sql` | 先看用量表裡實際有哪些模型與端點，再決定單價表要列什麼 |
| `run.sh` | 入口，依序跑單價表、view、檢查、報表 |

## 用法

```bash
bash monitoring/run.sh
```

檢查沒過也會先把報表印出來，最後才回報失敗，第 07 項不通過代表用量表裡有單價表沒列到的模型，到 `price.sql` 補一列再跑一次。

## 儀表板

Data Studio 沒有可以從零建立報表的 API，用 Linking API 的網址建立報表與資料來源，圖表要在瀏覽器裡拖拉完成，網址裡的資料來源參數不要帶別名（寫 `ds.connector`，不是 `ds.ds0.connector`）。

```text
https://datastudio.google.com/reporting/create?r.reportName=MarTech%20AI%20Token%20Cost&ds.connector=bigQuery&ds.type=TABLE&ds.projectId=你的專案ID&ds.datasetId=martech_dw&ds.tableId=v_llm_usage_daily&ds.billingProjectId=你的專案ID
```

## 儀表板看不到的

- 不是用 Token 計費的呼叫（Day 18 的 Veo 影片按秒計費），費用是空值，只會出現在 `unpriced_calls`
- 不回報用量的服務（Day 24 的評分模型），根本沒有寫進用量表
- Day 16 建用量表之前的呼叫
- 模型以外的費用，實際金額以 Cloud Billing 的帳單為準

## 單價

`price.sql` 的單價是 2026-10-08 從官方定價頁查的，gemini-3.6-flash 到 2026-12-31 是導入期價格，官方另外公告這個模型 2026-11-19 停用，單價與模型都會變，照做之前請自己再查一次。
