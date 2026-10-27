# Day 27、28：行銷日報流程與 Slack 通知（Cloud Workflows＋Cloud Scheduler＋Secret Manager）

每天早上由 Cloud Scheduler 啟動一個 Workflows 流程，流程依序向 Day 26 的助理服務問三個固定問題，把回答寫進 `martech_dw.daily_reports`，用 `martech_dw.v_daily_report` 讀出當天的日報。Day 28 起同一個流程會把日報、沒有寫完的通知和成效異常送到 Slack，做法見最後一節。

文章：[Day 27｜早上一進辦公室，AI 行銷日報已經自動寫好了](../docs/articles/day27-daily-report-workflows.md)

## 檔案

| 檔案 | 做什麼 | 會不會花錢 |
| --- | --- | --- |
| `daily_report.yaml` | 流程本體：檢查今天有沒有日報、問三題、每題寫一列、送 Slack、決定這次執行算成功還是失敗 | 流程本身不會，助理呼叫模型會 |
| `setup.sql` | 建日報表與 view，Day 28 多了通知紀錄表 `ops_notifications` 與組警報文字的 `v_anomaly_alerts` | 不會 |
| `run.sh` | 手動啟動一次流程，再跑檢查與報表 | `--free`、`--slack-test`、`--report` 不會，今天已經有完整的日報時不帶參數也不會，其他會先印估價 |
| `check.sql` | 22 項檢查，一列一項，只看昨天與今天（第 19、21 項看全部），第 20 到 22 項只是提醒 | 不會 |
| `report.sql` | 五段報表：最新的日報、每次執行、每題的花費、合計、送到 Slack 的通知 | 不會 |
| `../scripts/deploy_daily_report.sh` | 部署流程、建立排程（預設先暫停） | 不會 |

## 三個身分

| 服務帳號 | 用在哪裡 | 權限 |
| --- | --- | --- |
| `martech-scheduler` | Cloud Scheduler 用它啟動流程 | 只有 `roles/workflows.invoker` |
| `martech-pipeline-runner` | 流程用它呼叫助理、寫日報表、寫紀錄 | 流程用到的：助理服務的 `roles/run.invoker`、`martech_dw` 的 `bigquery.dataEditor`、`bigquery.jobUser`、`logging.logWriter`，這個帳號從 Day 03 起還有 `aiplatform.user`、素材儲存庫的 `storage.objectAdmin`，以及 Day 28 要用的 Slack 密鑰讀取權 |
| `martech-assistant` | 助理服務用它查資料與呼叫 Gemini（Day 26） | 見 `agent/README.md` |

排程的身分只能「啟動」，查不到資料也呼叫不了助理，流程的身分呼叫得了助理但不能自己啟動排程，分開的用意是排程那個身分外流時能做的事很少。`martech-pipeline-runner` 是整個系列共用的身分，權限比這個流程需要的多，正式環境建議替日報流程另開一個只有上面前四項的服務帳號。

## 流程的啟動參數

| 參數 | 說明 | 預設 |
| --- | --- | --- |
| `trigger` | 啟動的來源，只能是 `scheduler` 或 `manual`，是啟動的人自己填的標記，不是驗證過的身分 | `manual` |
| `force` | `true` 表示今天已經有完整的日報也重新問一次 | `false` |
| `test_break` | 清單，裡面的題號改打不存在的路徑，用來不花錢地測試失敗的處理，有帶的時候 Slack 訊息會標明【測試】 | `[]` |
| `notify` | `false` 表示這一次不送 Slack | `true` |
| `as_of` | 把哪一天當成今天去看有沒有成效異常，格式 `YYYY-MM-DD`，只影響異常警報，不影響日報 | 資料裡最新的一天 |
| `renotify` | `true` 表示已經通知過的異常也再送一次，對日報沒有作用（日報重送靠 `force`） | `false` |
| `alerts` | `false` 表示這一次不看成效異常，`run.sh --slack-test` 預設就是這樣，免得測試把真的警報送掉 | `true` |

助理的網址、資料集名稱、Slack 密鑰的名稱與版本都不是參數，部署時用環境變數寫進流程（`ASSISTANT_URL`、`DATASET`、`SLACK_SECRET`、`SLACK_SECRET_VERSION`）。流程會替這個網址簽一張 `martech-pipeline-runner` 的身分權杖，網址如果能由啟動的人指定，只有啟動權限的身分就能把權杖送到別的地方。

## 流程怎麼判斷一題算不算答完

助理不管有沒有答出來都回 HTTP 200，結果在回應的 `status` 欄位，流程只把下面四種當成答完，而且回答不能是空的：

- `passed`
- `claims_flagged`（回答後面被附上宣稱用語的提醒）
- `exits_sealed`
- `claims_flagged,exits_sealed`

其他情況都記成 `failed`，`detail` 欄位留下原因：

| detail | 意思 | 流程怎麼做 |
| --- | --- | --- |
| `daily_cap` | 助理今天的額度用完 | 這一題記 `failed`，後面的題目不再問、記成 `skipped` |
| `input_blocked`、`output_blocked`、`safety_blocked` | 被助理的護欄擋下 | 記 `failed`，換下一題 |
| `incomplete`、`error`、`input_cap`、`max_turns` | 助理沒有答完 | 記 `failed`，換下一題 |
| `http_403`、`http_404`、`http_429`、`http_503` 這類 | 助理或 Cloud Run 回了錯誤的 HTTP 狀態（429 與助理自己回的 503 是重試 2 次之後還是一樣） | 記 `failed`，換下一題 |
| `empty_answer` | 助理說答完了但回答是空的 | 記 `failed`，換下一題 |
| `no_status`、`error_unknown` | 回應裡沒有 status，或錯誤認不出來 | 記 `failed`，換下一題 |
| `error_TimeoutError`、`error_ConnectionError` 這類 | 逾時或連線中斷 | 記 `failed`，換下一題，不重試 |

三題沒有全部答完，這次執行會在寫完日報表之後以失敗結束（`raise`），Workflows 的執行清單上是紅色的。Cloud Scheduler 那一邊只知道流程有沒有被啟動，不知道日報完不完整。

## 重試的原則

只有確定助理還沒開始處理的錯誤才重試，最多 2 次，間隔 10 秒、20 秒：

- HTTP 429：Cloud Run 的執行個體都在忙，請求沒有進到程式
- HTTP 503 而且回應內容是助理自己寫的 `unavailable`：程式回報現在不能用，還沒呼叫模型
- `ConnectionFailedError`：連線沒有建立

其他的 503、逾時與連線中斷不重試：Cloud Run 在請求處理到一半時也可能回 503，助理可能已經呼叫過模型，再問一次就是再花一次錢。流程等 310 秒（原本是 150 秒，換成 gemini-3.8-flash 後單次呼叫常超過 20 秒，助理改成一句目標 270 秒（Cloud Run 前排隊或 BigQuery 出狀況時可能超過），流程跟著放寬到比 Cloud Run 的 300 秒長一點）就放棄，真的逾時代表助理那一邊出了狀況，那一題錢可能已經花了，花費只在 `serve_turns` 看得到。這樣取捨的代價是偶發的錯誤會讓那一題空著，要等人手動重跑（`bash workflows/run.sh`，三題會全部重問）。

## 同一天跑兩次

流程一開始會查今天（台北時間）有沒有任何一次執行三題都答完，有就直接結束、不發問，回傳 `skipped_existing`。帶 `force` 才會重問。今天的日報只答完一部分時，不帶 `force` 的重跑會三題全部重問，不是只補缺的那一題。日報表只加不刪，`v_daily_report` 每天只取答完最多題的那一次執行，一樣多就取最新的。

## 已知的限制

- 合成資料停在 2026-09-16，助理把 2026-09-17 當成今天，所以每天的日報內容相同，接上每天更新的資料後內容才會變
- 助理的回答限制在四句話以內，日報是三題各自的回答，不是一篇完整的分析
- 日報和同事的提問共用助理的每日上限（預設新台幣 3 元），額度先被用完的話日報會缺題
- 日報的模型呼叫在共用用量表裡 `day` 是 `Day 26`、`job` 是 `agent/serve.py`（助理服務的標籤是固定的），要分出日報請用對話編號把 `daily_reports` 對回 `serve_turns`（`report.sql` 第 3 段的做法，`caller` 欄位會是 `martech-pipeline-runner`）
- 檢查今天有沒有日報和開始發問之間沒有鎖，兩次執行幾乎同時啟動的話會各問一次
- 寫日報表失敗時這次執行會直接以錯誤結束，後面的題目不會再問，那一題的回答可能不在日報表裡（寫入只是逾時的話之後可能補上），但還在助理自己的 `serve_turns`
- `trigger_source` 是啟動的人自己填的，手動啟動時填 `scheduler` 也會被接受
- 有啟動權限的身分可以帶 `force` 反覆啟動流程，每次最多問三題，花費被助理的每日上限擋住，但當天同事就用不到助理
- `martech-scheduler` 的 `roles/workflows.invoker` 綁在專案層級，專案裡其他流程它也啟動得了，正式環境建議只綁在這一個流程上
- `check.sql` 只看昨天與今天的列（第 19、21 項看全部）

## Day 28：把日報與成效異常送到 Slack

### 送什麼、什麼時候送

| 通知 | 什麼時候送 | 同一件事送幾次 | 會不會呼叫模型 |
| --- | --- | --- | --- |
| 成效異常（`anomaly`） | `as_of` 那一天落在 Day 09 某一筆異常的期間裡，或期間結束後 7 天內 | 每一筆異常只送一次，帶 `renotify` 才重送 | 不會，判讀是 Day 09 算好的 |
| 日報（`daily_report`） | 三題都答完，當天稍後重跑被跳過時如果 Slack 還沒收過也會補送 | 每天一次，帶 `force` 重問才重送 | 日報本身會，送出去這一步不會 |
| 日報沒有寫完（`report_incomplete`） | 三題沒有全部答完 | 每一次沒寫完的執行都送 | 不會 |
| 流程中途出錯（`flow_error`） | 流程丟出沒料到的錯，啟動參數寫錯不算（那一種只會讓執行失敗） | 每一次都送 | 不會 |

每一次通知都在 `martech_dw.ops_notifications` 留一列，送成功是 `sent`，沒送出去是 `failed`。同一件事只通知一次靠的就是這張表，送之前先查同一個 `dedupe_key` 有沒有送成功過。

日報寫完了但有任何一則通知沒送出去，這次執行一樣以失敗結束，執行清單上是紅色的，日報本身還是在日報表裡。帶 `notify: false` 的那一次完全不碰 Secret Manager 與 Slack，也不留通知紀錄。

### Slack 的網址放在哪裡

Slack 的 Incoming Webhook 網址本身就是密鑰，拿到的人可以往那個頻道發訊息，所以：

- 網址只放在 Secret Manager 的密鑰 `slack-webhook-url`（Terraform 建的是空的密鑰，內容要自己放）
- 流程定義、環境變數、BigQuery 的表裡都沒有網址，環境變數放的是密鑰的名稱與版本，流程自己寫的紀錄（`sys.log`）也不寫網址
- 流程每次要送訊息才向 Secret Manager 拿，網址只活在送訊息那個子流程的變數裡
- 只有 `martech-pipeline-runner` 這個服務帳號讀得到這個密鑰（專案擁有者本來就讀得到）
- 部署時把 call logging 關掉（`--call-log-level log-none`），打開之後送 Slack 那一步的請求網址會被寫進 Cloud Logging
- 上面這一條只管得到流程的預設值：有啟動權限的人可以在啟動單一次執行時自己帶 `--call-log-level` 或把執行歷程調成詳細，那一次的網址就可能出現在紀錄或執行歷程裡，所以啟動權限與看紀錄的權限都要當成「看得到網址」來管
- 送失敗時只記在哪一步、哪一種錯（例如 `slack_http_404`、`secret_http_403`），不記錯誤的原文

放網址的做法（不要把網址直接打在指令列上，會留在指令紀錄裡）：

```bash
read -r -s -p 'Webhook 網址：' HOOK && printf '%s' "$HOOK" | gcloud secrets versions add slack-webhook-url --data-file=- ; unset HOOK
```

換網址就是再加一個版本，流程預設讀 `latest`，不用重新部署，舊的版本記得停用。`latest` 指的是最新建立的那個版本，把它停用之後流程不會退回上一版，而是讀不到密鑰（`secret_` 開頭的 detail），要停用的是舊版本。

### 訊息的內容怎麼處理

- 送出去之前把 `&`、`<`、`>` 換成 `&amp;`、`&lt;`、`&gt;`，Slack 的連結與提及整個頻道都靠 `< >`，助理的回答是模型寫的，不能假設裡面沒有這些字
- 日報的三題是助理的回答原文，Day 26 的服務在送出前已經封過一次出口，這裡再換一次是因為兩邊各自負責自己的出口
- 異常警報的文字在 `v_anomaly_alerts` 這個 view 裡組好，流程只挑出該送的列

### 重播過去的日子

合成資料停在 2026-09-16，要看警報長什麼樣子，用 `as_of` 把過去某一天當成今天：

```bash
bash workflows/run.sh --as-of 2026-08-27   # 全站追蹤碼失效那一天
bash workflows/run.sh --as-of 2026-08-12   # meta-trn-prospecting 點擊成本變貴的那一週
```

`as_of` 只影響「看哪一天有沒有異常」，日報還是助理照它自己的今天寫的。警報本身不呼叫模型，但這兩行是一般的跑法：今天還沒有完整的日報時流程會照常問三題（先印估價、輸入 yes 才問），今天已經有日報時才是完全不花錢。只想看警報又不想等日報，可以改用 `bash workflows/run.sh --slack-test --as-of 2026-08-27`，代價是頻道裡會多一則標明【測試】的訊息。不加 `--as-of` 的 `--slack-test` 不看成效異常，只送那一則測試訊息。`as_of` 給了不存在的日子（例如 2026-02-30）時查詢會出錯，流程把它算成一次通知失敗，日報照寫但這次執行以失敗結束。

### Day 28 新增的已知限制

- 排程一天跑一次，所以「第一時間」最慢是隔天早上，要更快得把排程調密，而每跑一次日報就是一次模型的費用
- 異常是 Day 09 的批次算好的，流程不會自己重算，資料更新之後要先重跑 `bash diagnosis/run.sh`
- 通知紀錄寫入失敗時，下一次會以為沒通知過而再送一次
- 送之前查通知紀錄就失敗的話，日報與異常這一次不送、記成失敗（寧可漏送被看見，也不要每天重複送），流程中途出錯的通知不查紀錄、直接送
- 兩次執行幾乎同時啟動的話，同一筆異常可能各送一次
- 流程自己壞到連通知都送不出去的情況（例如密鑰被刪、Slack 的網址失效）只會在執行清單上看到失敗，正式環境建議另外用 Cloud Monitoring 對失敗的執行設警報
- 送到 Slack 的內容離開了 Google Cloud，日報裡有廣告花費與訂單數字，頻道要開給誰看要先想好，這三題不會碰到顧客個資
