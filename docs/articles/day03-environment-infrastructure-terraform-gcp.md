Day 03 | 環境基礎建設：Terraform 輕鬆建置 GCP 環境 —— 從 IAM 最小權限、BigQuery 倉儲到 Vertex AI 遠端連線全自動配置

# 1. 前言：告別「人工點擊」，為什麼現代雲端架構必須堅持 IaC？

在探索生成式 AI 或建置資料架構的過程中，許多工程師與行銷團隊最常採取的起步方式，就是打開 Google Cloud Console 控制台，憑著直覺在網頁上一路「下一步」：手動點選建立 BigQuery 資料集、手動新增 Cloud Storage 儲存庫、在 IAM 頁面反覆搜尋並指派權限。

然而，這種看似快捷的「ClickOps（網頁點擊維運）」在邁向企業級系統時，往往會引發三大災難性痛點：

- **環境配置漂移（Configuration Drift）**：今天在測試專案手動勾選了某個權限，明天要部署正式專案時卻遺漏了關鍵步驟，導致「明明測試環境正常，正式環境卻出現 Permission Denied」的靈異現象。
- **維運黑箱與除錯困難**：當跨服務連線失敗時，沒有任何版本紀錄能追溯到底是哪位成員在何時修改了服務帳號角色，權限盤點如同大海撈針。
- **開源難以重現**：本專案《**AI-Driven MarTech：用 Google Cloud + Vertex AI 打造全自動廣告歸因與多模態素材分析系統**》的核心精神之一，是「全架構 100% 程式碼開源」。如果環境建置依賴冗長的網頁截圖教學，讀者將難以在自己的 GCP 帳號中輕鬆重現。

為此，我們在連載的第 3 天，正式引入業界標準的**基礎設施即程式碼（Infrastructure as Code, IaC）**工具 —— **Terraform**。透過宣告式（Declarative）的程式碼，我們將整個 MarTech 系統所需的 API 啟用、資料倉儲、素材儲存庫、服務帳號、IAM 權限，以及最關鍵的「BigQuery 遠端連線（Remote Connection）」，全部封裝為單一可重複執行的自動化腳本。只要幾個步驟，5 分鐘內即可完成企業級基礎建設的標準化建置！

---

# 2. Terraform 基礎建設部署拓撲全景

在動手編寫程式碼之前，我們先透過系統全景架構圖，綜觀本次 Terraform 所要建置的雲端資源藍圖：

![Terraform 基礎設施即程式碼 (IaC) 雲端資源部署全景圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day03-terraform-iac-architecture.svg)

💡 **核心工程理念**：
我們將整個 GCP 基礎架構拆分為清晰的三層設計：
1. **配置宣告層**：於本機或 Cloud Shell 定義宣告檔，透過 Terraform 引擎進行狀態比對與依賴解析。
2. **原生雲端資源層**：自動啟用 10 項核心 API，並建置位於 us-central1（愛荷華）的 BigQuery 資料倉儲、具備 90 天自動清理生命週期的 Cloud Storage 素材庫，以及專屬服務帳號。
3. **跨服務連線與治理層**：建立 BigQuery 連接 Vertex AI 的專用橋樑，並綁定 NT$ 300 預算防護警報。

---

# 3. 核心 Terraform 程式碼深度拆解

本專案的所有 Terraform 腳本均存放於專案儲存庫的 `terraform/` 目錄下。以下我們逐一拆解四大關鍵模組的設計細節與架構考量。

## 3.1 參數化宣告與在地化設定 (variables.tf)

為了確保腳本具備高度的可移植性，所有可變參數（如專案 ID、區域、儲存庫名稱等）一律抽離至 `variables.tf` 中，並提供合理的預設值：

- `project_id`：Google Cloud 專案 ID（必填，請於 `terraform.tfvars` 填入自己的專案 ID）
- `region`：核心區域預設 `us-central1`（愛荷華），可適用 Cloud Storage 每月 5GB 免費額度，也是 Vertex AI Gemini 模型支援最完整的區域
- `dataset_id`：`martech_dw`
- `dataset_description`：AI-Driven MarTech 資料倉儲：廣告日誌、多觸點歸因分析與多模態素材特徵庫
- `storage_bucket_name`：留空時自動使用「專案ID-martech-assets」，避免與其他讀者的儲存庫重名
- `billing_account_id`：帳單帳戶 ID，留空時自動略過預算警報
- `budget_amount_twd`：300（NT$ 300 預算警報基準）
- `budget_currency`：TWD，必須與帳單帳戶幣別一致

## 3.2 啟用專案必要 Google Cloud API 服務 (main.tf)

在全新建立的 GCP 專案中，許多服務 API 預設處於關閉狀態。我們透過 `google_project_service` 資源進行批次啟用 10 項關鍵服務：

1. `bigquery.googleapis.com`：BigQuery API
2. `bigqueryconnection.googleapis.com`：BigQuery Connection API（SQL 呼叫遠端模型關鍵）
3. `aiplatform.googleapis.com`：Vertex AI API（Gemini 多模態推論）
4. `storage.googleapis.com`：Cloud Storage API
5. `run.googleapis.com`：Cloud Run API
6. `workflows.googleapis.com`：Cloud Workflows API
7. `cloudbuild.googleapis.com`：Cloud Build API
8. `monitoring.googleapis.com`：Cloud Monitoring API
9. `billingbudgets.googleapis.com`：Cloud Billing Budget API
10. `iam.googleapis.com`：IAM 身分驗證與存取授權 API

## 3.3 廣告圖文素材儲存庫與自動清理生命週期

廣告分析需要處理大量的橫幅圖片、文案截圖與暫存日誌。在 Cloud Storage 儲存庫中實裝生命週期管理規則（Lifecycle Rules）：

- **統一儲存庫層級存取控制（UBLA）**：關閉傳統細粒度的物件 ACL，完全統一由 Cloud IAM 管理。
- **90 天自動清理**：暫存的測試日誌與過期素材在 90 天後自動刪除，搭配 us-central1 區域每月 5GB 的 Cloud Storage 免費額度，讓教學與測試階段的儲存費用幾乎為零。

## 3.4 現代化資料倉儲核心：BigQuery Dataset

BigQuery 是整個 MarTech 系統的「資料心臟」。在此建立廣告成效的星狀綱要資料集 `martech_dw`，設定位置為 `us-central1`，並綁定環境與參賽專案標籤。

## 3.5 關鍵核心：BigQuery 遠端連線與 Vertex AI 零金鑰授權

在傳統架構中，若想讓 SQL 呼叫 AI 模型，往往需要手動產生 Service Account JSON 金鑰並寫入環境變數，存在外洩風險。Google Cloud 原生提供了 BigQuery Cloud Resource Connection 解決方案：

![BigQuery 與 Vertex AI 跨服務 IAM 連線與零信任授權架構圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day03-bq-vertex-iam-flow.svg)

1. 宣告 `google_bigquery_connection`（`connection_id = "vertex_ai_conn"`），GCP 自動配發受管服務帳號。
2. 透過 `google_project_iam_member` 將該服務帳號賦予 `roles/aiplatform.user` 角色。
3. 日後執行 `ML.GENERATE_TEXT` 時，BigQuery 在 Google 內部專用骨幹網路內直連 Vertex AI，全程不產生、不暴露任何 JSON 密鑰，兼具資安零信任與次秒級極速推論。

## 3.6 資料管線專用服務帳號與最小權限綁定

配置 `martech-pipeline-runner` 服務帳號，嚴格奉行最小權限原則，僅授予四項專屬角色：

- `roles/bigquery.dataEditor`：資料寫入
- `roles/bigquery.jobUser`：查詢作業提交
- `roles/storage.objectAdmin`：素材存取
- `roles/aiplatform.user`：Gemini API 呼叫

---

# 4. FinOps 成本防護實踐：三道防線架構

![AI MarTech 專案 FinOps 成本防護與三道防線架構圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day03-finops-budget-defense.svg)

我們透過三道防線構築完整的成本護欄：

1. **第一道防線：善用 Google Cloud 每月免費額度**（BigQuery 每月 10 GiB 儲存與 1 TiB 查詢、Cloud Run 每月 200 萬次請求、Cloud Storage 於 us-central1、us-east1、us-west1 三個美國區域每月 5GB 標準儲存），教學與開發階段的基礎資源費用幾乎為零；Vertex AI Gemini 呼叫則依用量計費，由第二、三道防線把關。
2. **第二道防線：架構層被動成本防護**（GCS 90 天過期清理、Gemini 2.0 Flash / 3.5 Flash-Lite 優先、Context Caching 降低約 75% 費用、嚴禁批次開啟 Thinking Tokens）。
3. **第三道防線：Cloud Billing 預算警報**（NT$ 300 預算：50% 早期預警、80% 警戒通知、100% 超支警告）。預算警報會以 Email 通知帳單管理員，但不會自動停止服務，收到通知後請及時檢查用量。

---

# 5. Cloud Shell 實戰演練：5 分鐘一鍵建置

前面我們拆解了每一段 Terraform 程式碼設計考量，這一節要帶大家實際把環境建置起來。即使平常較少接觸終端機也不用擔心，所有操作都在瀏覽器中完成，不需要在自己的電腦安裝任何軟體。

Google Cloud 提供的 **Cloud Shell** 是一台免費的線上 Linux 環境，已預先安裝好 gcloud、bq 與 Terraform 等工具，並附有 5GB 的永久儲存空間，非常適合作為本專案的標準操作環境。

我們準備了兩種路線，請依照自己的需求選擇：

- **路線 A｜懶人包**：一行指令完成全部建置，適合想先看到成果的讀者
- **路線 B｜逐步教學**：一步一步執行並理解每個指令的用途，適合想掌握 Terraform 操作流程的讀者

兩種路線建置出來的環境完全相同，也可以先用路線 A 跑起來，再回頭閱讀路線 B 了解背後原理。

## 5.1 事前準備（約 2 分鐘，只需做一次）

開始之前，請先確認以下三件事：

- **Google Cloud 帳號與帳單**：需已綁定帳單帳戶。新帳號可使用免費試用額度，本專案也設有 NT$ 300 預算警報協助把關。
- **專案 ID**：在 Console 左上角的專案選單中可以看到，格式類似 `my-martech-123456`。請注意，專案 ID 不一定等於專案名稱。
- **帳單帳戶 ID（選填）**：前往 Console「帳單」→「帳戶管理」查看，格式類似 `XXXXXX-XXXXXX-XXXXXX`。建立預算警報需要帳單帳戶管理員權限，若沒有權限請留空，Terraform 會自動跳過預算警報的建置，不影響其他資源。

💡 下方指令中出現的 `YOUR_PROJECT_ID`，請一律替換成你自己的專案 ID。

## 5.2 路線 A｜懶人包：一行指令完成建置

點選 Google Cloud Console 右上角的「啟用 Cloud Shell」圖示（`>_`），畫面下方會開啟終端機視窗。先指定要使用的專案：

```bash
gcloud config set project YOUR_PROJECT_ID
```

接著貼上下面這一行並按下 Enter：

```bash
cd ~ && if [ -d ai-driven-martech-pipeline/.git ]; then git -C ai-driven-martech-pipeline pull --ff-only; else git clone https://github.com/gminc/ai-driven-martech-pipeline.git; fi && bash ai-driven-martech-pipeline/scripts/quickstart.sh
```

這支 `quickstart.sh` 腳本會自動幫你完成以下工作：

- **偵測專案與帳單**：讀取目前的專案 ID，檢查帳單是否已啟用；若具備帳單帳戶管理員權限，會自動設定預算警報並對齊帳戶幣別（TWD 或 USD），否則自動略過
- **產生設定檔**：從 `terraform.tfvars.example` 複製出 `terraform.tfvars`，並自動填入上述資訊
- **預覽變更**：執行 `terraform init` 與 `terraform plan`，列出即將建立的所有資源
- **確認後才建置**：等你輸入 yes 後才真正執行；若遇到 API 剛啟用尚未生效，會自動等待 60 秒重試一次
- **自動驗證**：建置完成後檢查 BigQuery 與 Vertex AI 的遠端連線，並列出所有輸出資訊

看到畫面出現「🎉 建置完成！」就代表成功了，可以直接跳到 5.4 確認成果。

## 5.3 路線 B｜逐步教學：理解每一個指令

### 步驟 1：開啟 Cloud Shell 並指定專案

點選 Console 右上角的「啟用 Cloud Shell」圖示（`>_`），在終端機輸入：

```bash
gcloud config set project YOUR_PROJECT_ID
```

第一次執行時可能會跳出「授權 Cloud Shell」視窗，按下「授權」即可。

- ✅ **成功的樣子**：看到 `Updated property [core/project].`

### 步驟 2：下載專案程式碼

```bash
git clone https://github.com/gminc/ai-driven-martech-pipeline.git
cd ~/ai-driven-martech-pipeline/terraform
```

第一行把開源專案複製到你的 Cloud Shell 中，第二行進入存放 Terraform 腳本的資料夾。

- ✅ **成功的樣子**：輸入 `ls` 後，可以看到 `main.tf`、`variables.tf`、`outputs.tf` 等檔案

### 步驟 3：建立並填寫設定檔

```bash
cp terraform.tfvars.example terraform.tfvars
cloudshell edit terraform.tfvars
```

第一行複製一份設定範本，第二行用 Cloud Shell 內建的編輯器開啟它。請依需求修改以下欄位後存檔：

- `project_id`：你的專案 ID（必填）
- `billing_account_id`：你的帳單帳戶 ID（選填，留空即略過預算警報；需具備帳單帳戶管理員權限）
- `budget_currency`：預算幣別，必須與帳單帳戶一致（預設 TWD；若帳戶為美元請改為 USD，並將 `budget_amount_twd` 調整為 10）

其餘參數皆有預設值，例如區域預設為 `us-central1`、素材儲存庫名稱會自動使用「專案ID-martech-assets」，避免與其他讀者重名。

🔒 `terraform.tfvars` 已列入 `.gitignore`，填寫的帳單資訊不會被推上 GitHub。

### 步驟 4：初始化與預覽（這一步還不會建立任何資源）

```bash
terraform init
terraform plan
```

- `terraform init`：下載 Terraform 所需的 Google Cloud 外掛，每個資料夾第一次使用時執行即可
- `terraform plan`：就像施工前的藍圖確認，列出接下來要建立哪些資源，不會真的動到雲端

- ✅ **成功的樣子**：畫面最後出現 `Plan: X to add, 0 to change, 0 to destroy.`

### 步驟 5：正式建置

```bash
terraform apply
```

Terraform 會再次列出變更內容，並詢問 `Enter a value:`。確認無誤後輸入 `yes` 並按下 Enter，接下來約 2 到 3 分鐘，Terraform 會依序完成 API 啟用、BigQuery 資料集、Cloud Storage 儲存庫、服務帳號與 IAM 權限的建置。

- ✅ **成功的樣子**：看到綠色的 `Apply complete! Resources: X added, 0 changed, 0 destroyed.`
- ⚠️ **遇到錯誤怎麼辦**：若第一次執行出現 `SERVICE_DISABLED` 或 `API has not been used in project` 等訊息，通常是 API 剛啟用、還在生效中；若出現 `Service account ... does not exist`，則是遠端連線的服務帳號剛配發、尚未同步。這兩種情況都只要稍等 1 到 2 分鐘，再執行一次 `terraform apply` 即可（原因詳見第 6 節）。

## 5.4 驗證建置成果

### 確認 BigQuery 遠端連線

```bash
bq show --connection YOUR_PROJECT_ID.us-central1.vertex_ai_conn
```

- ✅ **成功的樣子**：看到連線資訊，其中包含一組系統自動配發的服務帳號。這正是後續章節讓 SQL 直接呼叫 Gemini 的關鍵橋樑。

### 查看所有建置資訊

```bash
terraform output
```

畫面會列出資料集 ID、素材儲存庫網址、遠端連線 ID 與服務帳號等資訊，後續章節會陸續用到。也可以回到 Console 的 BigQuery 頁面，確認左側已出現 `martech_dw` 資料集。

## 5.5 不用了？一行指令全部清除

```bash
cd ~/ai-driven-martech-pipeline/terraform && terraform destroy
```

輸入 `yes` 後，Terraform 會移除本次建立的資料集、儲存庫、服務帳號、權限與預算警報，不會留下持續計費的項目（已啟用的 API 會保留，啟用本身不收費）。這正是 IaC 的一大優勢：建置與清除都一樣簡單，隨時可以重新來過。

## 5.6 常用指令速查

- `gcloud config set project 專案ID`：切換目前使用的專案
- `gcloud config get-value project`：查看目前使用的專案
- `terraform init`：下載 Terraform 所需外掛，每個資料夾第一次使用時執行
- `terraform plan`：預覽將建立或變更的資源，不會真的動到雲端
- `terraform apply`：依照程式碼建置資源，需輸入 yes 確認
- `terraform output`：查看建置完成後的輸出資訊
- `terraform destroy`：移除本次建立的所有資源
- `bq ls`：列出目前專案中的 BigQuery 資料集
- `gcloud services list --enabled`：列出已啟用的 API

---

# 6. 工程實務避坑指南（Gotchas & Best Practices）

1. **API 啟用非同步問題**：使用 `depends_on` 強制鎖定資源相依性；若首次 apply 仍遇到 API 尚未生效，稍候重新執行即可（`quickstart.sh` 已內建自動重試機制）。
2. **地理位置一致性**：BigQuery Connection 與 Dataset 必須皆駐留在同一區域（本專案為 `us-central1`），避免跨區域查詢失敗。
3. **Billing 權限降級相容**：使用條件式宣告 `count = var.billing_account_id != "" ? 1 : 0`，未提供帳單帳戶 ID 時優雅略過，不影響核心資源建置；`quickstart.sh` 會先檢查帳單管理員權限，沒有權限時自動留空。

---

# 7. 總結與明日預告

今日已成功利用 Terraform 建立高合規、高安全且隨時可重現的 GCP 雲端環境。

**明日預告**：Day 04《即時驗證軌：極簡 Live Demo 站與事件追蹤埋設》，我們將搭建微型電商展示介面，並串接 GA4 與 Stripe 測試金流，驗證即時事件資料處理流程！
