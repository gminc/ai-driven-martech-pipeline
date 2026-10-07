# evaluation：拿預先藏好的標準答案考助理，再考評分的方式（Day 24）

同一批 16 個回答（8 個問題在有工具、沒有工具各問一次）用三種方式評分：規則、人、Gen AI evaluation service 的評分模型，分數都是 0、1、2，放在同一張表比對。

文章：[Day 24｜AI 給的分析到底能信幾分？拿預先藏好的標準答案來考考它](../docs/articles/day24-evaluation.md)

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `eval_run.py` | 題目、標準答案、規則、評分標準都寫死在這裡，五個步驟：answers、rules、export、human、judge |
| `run.sh` | 入口，檢查環境與 git 狀態之後呼叫 `eval_run.py`，最後跑檢查與報表 |
| `check.sql` | 12 項流程檢查 |
| `report.sql` | 六段報表：助理的成績、逐題分數、和人的一致情況、不一致的理由、回答原文、費用 |
| `answers_to_label.md` | 2026-10-07 這一次匯出給人評分的 16 則（順序打亂） |
| `human_labels.csv` | 2026-10-07 這一次人的分數，在呼叫評分模型之前 commit |

## 用法

```bash
bash evaluation/run.sh answers          # 問 16 次 → 規則評分 → 匯出給人評分的表（會花錢，先印估價）
bash evaluation/run.sh human            # 把填好的 human_labels.csv 寫進評分表
bash evaluation/run.sh judge --one      # 每個評分模型先試一筆，印出原始回應
bash evaluation/run.sh judge            # 跑完評分 → 檢查 → 報表（會花錢，先印估價）
bash evaluation/run.sh report           # 只跑檢查與報表
python3 evaluation/eval_run.py selftest # 規則的自我檢查，不連線
```

`answers` 與 `judge` 可以加 `--dry` 只做到估價為止，要自己重跑的話，先把儲存庫裡的 `human_labels.csv` 和 `answers_to_label.md` 改名，做法見文章 5.1。

## BigQuery 的表

| 表 | 一列是什麼 |
| --- | --- |
| `eval_answers` | 一個問題在一種情況問一次 |
| `eval_calls_log` | 問問題時呼叫一次模型 |
| `eval_scores` | 一個回答被一種評分方式評一次，grader 是 rule、human 或 judge:模型名稱 |

## 這一次的結果（2026-10-07）

- 有工具 8 個回答全部 2 分，沒有工具平均 0.38 分，8 題裡 6 題 0 分
- 和人的分數相同的回答數：規則 12 / 16、gemini-3.6-flash 15 / 16、gemini-3.5-flash-lite 14 / 16
- 問問題實際約新台幣 1.27 元，評分模型的估價上限約 2.77 元（evaluation service 不回報 Token，實際以帳單為準）

## 限制

- 人的分數是 AI 助手（Claude）先照評分標準打草稿，Jimmy 逐則審過定案，只改了一則（e2 沒有工具，由 1 分改 0 分），不是完全獨立於模型的基準
- 只有 16 個回答，每題只問一次，評分模型每筆只抽樣一次，其中一個評分模型和助理是同一個模型，一致的比例不能拿來比較誰比較準
- 規則只看字面，講對了但換一種句型就可能不認得，題目裡出現過的字不能當關鍵事實
- 評分模型的端點與模型路徑要用 global，us-central1 在 2026-10-07 對這兩個模型回 404
- gemini-3.6-flash 於 2026-11-19 停用，之後要改用官方建議的替代模型並更新單價
