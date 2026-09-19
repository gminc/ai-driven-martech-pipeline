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
2. **原生雲端資源層**：自動啟用 10 項核心 API，並建置位於 US 多區域的 BigQuery 資料倉儲、位於 us-central1（愛荷華）且具備自動清理生命週期的 Cloud Storage 素材庫，以及專屬服務帳號。
3. **跨服務連線與治理層**：建立 BigQuery 呼叫 Gemini 模型的專用橋樑，並綁定預算防護警報（新台幣帳戶 NT$ 300／美元帳戶 US$ 10）。

---

# 3. 核心 Terraform 程式碼深度拆解

本專案的所有 Terraform 腳本均存放於專案儲存庫的 `terraform/` 目錄下。以下我們逐一拆解四大關鍵模組的設計細節與架構考量。

## 3.1 參數化宣告與在地化設定 (variables.tf)

為了確保腳本具備高度的可移植性，所有可變參數（如專案 ID、區域、儲存庫名稱等）一律抽離至 `variables.tf` 中，並提供合理的預設值：

- `project_id`：Google Cloud 專案 ID（必填且無預設值，請於 `terraform.tfvars` 填入自己的專案 ID）
- `region`：Cloud Storage 等區域型資源預設 `us-central1`（愛荷華），可適用 Cloud Storage 每月 5GB 免費額度
- `bq_location`：BigQuery Dataset 與遠端連線的位置，預設 `US` 多區域。BigQuery 生成式 AI 函式對 Gemini 3.x 新模型的支援以 US／EU 多區域為主，選 `US` 可避免日後呼叫新模型時找不到模型
- `dataset_id`：`martech_dw`
- `dataset_description`：AI-Driven MarTech 資料倉儲：廣告日誌、多觸點歸因分析與多模態素材特徵庫
- `storage_bucket_name`：留空時自動使用「專案ID-martech-assets」，避免與其他讀者的儲存庫重名
- `billing_account_id`：帳單帳戶 ID，留空時自動略過預算警報
- `budget_amount`：預算警報基準金額，預設 300（新台幣帳戶填 300、美元帳戶填 10）
- `budget_currency`：預設 TWD，必須與帳單帳戶幣別一致
- `allow_destroy_with_data`：`terraform destroy` 時是否連同資料一併刪除，教學環境預設 `true`，正式環境請改為 `false`

## 3.2 啟用專案必要 Google Cloud API 服務 (main.tf)

在全新建立的 GCP 專案中，許多服務 API 預設處於關閉狀態。我們透過 `google_project_service` 資源進行批次啟用 10 項關鍵服務：

1. `bigquery.googleapis.com`：BigQuery API
2. `bigqueryconnection.googleapis.com`：BigQuery Connection API（SQL 呼叫遠端模型關鍵）
3. `aiplatform.googleapis.com`：Vertex AI API（現為 Gemini Enterprise Agent Platform，服務名稱不變；Gemini 多模態推論）
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
- **版本控管與雙層清理**：開啟物件版本控管以防誤刪；現行物件 90 天後自動刪除，刪除後留下的非現行版本再過 7 天永久清除，並關閉儲存庫預設的 7 天虛刪除（Soft Delete）保留，避免舊版本與已刪除物件默默累積儲存費用。搭配 us-central1 區域每月 5GB 的 Cloud Storage 免費額度，讓教學與測試階段的儲存費用幾乎為零。

## 3.4 現代化資料倉儲核心：BigQuery Dataset

BigQuery 是整個 MarTech 系統的「資料心臟」。在此建立廣告成效的星狀綱要資料集 `martech_dw`，設定位置為 `US` 多區域，並綁定環境與參賽專案標籤。

## 3.5 關鍵核心：BigQuery 遠端連線與 Vertex AI 零金鑰授權

在傳統架構中，若想讓 SQL 呼叫 AI 模型，往往需要手動產生 Service Account JSON 金鑰並寫入環境變數，存在外洩風險。Google Cloud 原生提供了 BigQuery Cloud Resource Connection 解決方案：

![BigQuery 與 Vertex AI 跨服務 IAM 連線與零信任授權架構圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day03-bq-vertex-iam-flow.svg)

1. 宣告 `google_bigquery_connection`（`connection_id = "vertex_ai_conn"`），GCP 自動配發受管服務帳號。
2. 透過 `google_project_iam_member` 將該服務帳號賦予 `roles/aiplatform.user` 角色（Agent Platform User）。
3. 日後執行 `AI.GENERATE_TEXT` 等生成式 AI 函式時，BigQuery 會以這個託管服務帳號呼叫 Gemini，全程不產生、不暴露任何 JSON 金鑰。

## 3.6 資料管線專用服務帳號與最小權限綁定

配置 `martech-pipeline-runner` 服務帳號，奉行最小權限原則，除了授予必要角色，也盡量把授權範圍縮小到單一資源：

- `roles/bigquery.dataEditor`：資料寫入，**只授予在 `martech_dw` 資料集層級**
- `roles/storage.objectAdmin`：素材存取，**只授予在素材儲存庫層級**
- `roles/bigquery.jobUser`：查詢作業提交（此角色需授予在專案層級）
- `roles/aiplatform.user`：Gemini 模型呼叫（專案層級）

這樣即使專案內之後新增其他資料集或儲存庫，這個服務帳號也碰不到。

---

# 4. FinOps 成本防護實踐：三道防線架構

![AI MarTech 專案 FinOps 成本防護與三道防線架構圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day03-finops-budget-defense.svg)

我們透過三道防線構築完整的成本護欄：

1. **第一道防線：善用 Google Cloud 每月免費額度**（BigQuery 每月 10 GiB 儲存與 1 TiB 查詢、Cloud Run 每月 200 萬次請求、Cloud Storage 於 us-central1、us-east1、us-west1 三個美國區域每月 5GB 標準儲存），教學與開發階段的基礎資源費用幾乎為零；Vertex AI Gemini 呼叫則依用量計費，由第二、三道防線把關。
2. **第二道防線：架構層被動成本防護**（GCS 90 天過期清理與非現行版本 7 天清除、Gemini 3.5 Flash-Lite 優先、Context Caching 快取命中的輸入 Token 約以原價一成計費、批次處理時將 `thinking_level` 設為 `minimal` 或 `low`）。
3. **第三道防線：Cloud Billing 預算警報**（新台幣帳戶 NT$ 300／美元帳戶 US$ 10：50% 早期預警、80% 警戒通知、100% 超支警告）。預算警報會以 Email 通知帳單管理員，但不會自動停止服務，收到通知後請及時檢查用量。

---

# 5. Cloud Shell 實戰演練：5 分鐘一鍵建置

前面我們拆解了每一段 Terraform 程式碼設計考量，這一節要帶大家實際把環境建置起來。即使平常較少接觸終端機也不用擔心，所有操作都在瀏覽器中完成，不需要在自己的電腦安裝任何軟體。

Google Cloud 提供的 **Cloud Shell** 是一台免費的線上 Linux 環境，已預先安裝好 gcloud 與 bq 等工具，並附有 5GB 的永久儲存空間，非常適合作為本專案的標準操作環境。

要注意的是 Cloud Shell 自 2026/6/20 起不再預設內建 Terraform，需要自己安裝一次，裝在家目錄的 `~/bin` 就會跟著永久儲存空間保留下來，路線 A 的懶人包會自動處理，路線 B 則在步驟 3 手動完成。

我們準備了兩種路線，請依照自己的需求選擇：

- **路線 A｜懶人包**：一行指令完成全部建置，適合想先看到成果的讀者
- **路線 B｜逐步教學**：一步一步執行並理解每個指令的用途，適合想掌握 Terraform 操作流程的讀者

兩種路線建置出來的環境完全相同，也可以先用路線 A 跑起來，再回頭閱讀路線 B 了解背後原理。

## 5.1 事前準備（約 2 分鐘，只需做一次）

開始之前，請先確認以下三件事：

- **Google Cloud 帳號與帳單**：需已綁定帳單帳戶。新帳號可使用免費試用額度；若你的帳號具備建立預算的權限，本專案也會自動建立預算警報協助把關。
- **專案 ID**：在 Console 左上角的專案選單中可以看到，格式類似 `my-martech-123456`。請注意，專案 ID 不一定等於專案名稱。
- **帳單帳戶 ID（選填）**：前往 Console「帳單」→「帳戶管理」查看，格式類似 `XXXXXX-XXXXXX-XXXXXX`。建立預算警報需要可建立預算的權限（例如帳單帳戶管理員），若沒有權限請留空，Terraform 會自動跳過預算警報的建置，不影響其他資源。

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

- **確認 Terraform**：找不到 `terraform` 時自動下載 HashiCorp 官方版本，核對 SHA256 後安裝到 `~/bin`
- **偵測專案與帳單**：讀取目前的專案 ID，檢查帳單是否已啟用；若目前帳號具備建立預算的權限，會依帳戶幣別自動設定預算警報（TWD 帳戶 NT$ 300、USD 帳戶 US$ 10），否則自動略過
- **產生設定檔**：依照 `terraform.tfvars.example` 的欄位，自動產生 `terraform.tfvars` 並填入上述資訊
- **預覽變更**：執行 `terraform init` 與 `terraform plan`，列出即將建立的所有資源
- **確認後才建置**：等你輸入 yes 後才真正執行；若遇到 API 剛啟用尚未生效，會自動等待 60 秒重試一次（重試時沿用你剛才的確認，不會再次詢問）
- **自動驗證**：建置完成後檢查 BigQuery 遠端連線，並列出所有輸出資訊

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

### 步驟 3：安裝 Terraform（只需做一次）

```bash
TF_VERSION=1.16.3
cd ~ && curl -fsSLO https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip \
  && curl -fsSLO https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_SHA256SUMS \
  && grep " terraform_${TF_VERSION}_linux_amd64.zip$" terraform_${TF_VERSION}_SHA256SUMS | sha256sum -c - \
  && mkdir -p ~/bin && unzip -o -q terraform_${TF_VERSION}_linux_amd64.zip terraform -d ~/bin \
  && rm terraform_${TF_VERSION}_linux_amd64.zip terraform_${TF_VERSION}_SHA256SUMS
grep -qF 'export PATH="$HOME/bin:$PATH"' ~/.bashrc || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/bin:$PATH"
cd ~/ai-driven-martech-pipeline/terraform && terraform version
```

這段指令從 HashiCorp 官方下載 Terraform，先用官方公布的 SHA256 核對檔案沒有被竄改，再解壓到 `~/bin` 並加進 PATH，之後重開 Cloud Shell 也不用重裝，版本號可以換成[官方下載頁](https://releases.hashicorp.com/terraform/)上的最新穩定版。

- ✅ **成功的樣子**：先看到 `terraform_1.16.3_linux_amd64.zip: OK`，最後一行顯示 `Terraform v1.16.3`
- 💡 **已經有 Terraform 的話**：輸入 `terraform version` 有顯示版本就可以跳過這一步
- ⚠️ **看到 `FAILED` 的話**：代表下載的檔案和官方雜湊對不上，不要繼續，先執行 `rm -f ~/terraform_*` 刪掉下載的檔案再重跑一次

### 步驟 4：建立並填寫設定檔

```bash
cp terraform.tfvars.example terraform.tfvars
cloudshell edit terraform.tfvars
```

第一行複製一份設定範本，第二行用 Cloud Shell 內建的編輯器開啟它。請依需求修改以下欄位後存檔：

- `project_id`：你的專案 ID（必填）
- `billing_account_id`：你的帳單帳戶 ID（選填，留空即略過預算警報；需具備建立預算的權限）
- `budget_currency`：預算幣別，必須與帳單帳戶一致（預設 TWD；若帳戶為美元請改為 USD，並將 `budget_amount` 調整為 10）

其餘參數皆有預設值，例如 Cloud Storage 區域預設為 `us-central1`、BigQuery 位置預設為 `US`、素材儲存庫名稱會自動使用「專案ID-martech-assets」，避免與其他讀者重名。

🔒 `terraform.tfvars` 已列入 `.gitignore`，填寫的帳單資訊不會被推上 GitHub。

### 步驟 5：初始化與預覽（這一步還不會建立任何資源）

```bash
terraform init
terraform plan
```

- `terraform init`：下載 Terraform 所需的 Google Cloud 外掛，每個資料夾第一次使用時執行即可
- `terraform plan`：就像施工前的藍圖確認，列出接下來要建立哪些資源，不會真的動到雲端

- ✅ **成功的樣子**：畫面最後出現 `Plan: X to add, 0 to change, 0 to destroy.`

### 步驟 6：正式建置

```bash
terraform apply
```

Terraform 會再次列出變更內容，並詢問 `Enter a value:`。確認無誤後輸入 `yes` 並按下 Enter，接下來約 2 到 3 分鐘，Terraform 會依序完成 API 啟用、BigQuery 資料集、Cloud Storage 儲存庫、服務帳號與 IAM 權限的建置。

- ✅ **成功的樣子**：看到綠色的 `Apply complete! Resources: X added, 0 changed, 0 destroyed.`
- ⚠️ **遇到錯誤怎麼辦**：若第一次執行出現 `SERVICE_DISABLED` 或 `API has not been used in project` 等訊息，通常是 API 剛啟用、還在生效中；若出現 `Service account ... does not exist`，則是遠端連線的服務帳號剛配發、尚未同步。這兩種情況都只要稍等 1 到 2 分鐘，再執行一次 `terraform apply` 即可；IAM 權限生效偶爾需要更久（官方說明可能長達 7 分鐘以上），原因詳見第 6 節。

## 5.4 驗證建置成果

### 確認 BigQuery 遠端連線

```bash
bq show --connection YOUR_PROJECT_ID.us.vertex_ai_conn
```

- ✅ **成功的樣子**：看到連線資訊，其中包含一組系統自動配發的服務帳號。這正是後續章節讓 SQL 直接呼叫 Gemini 的關鍵橋樑。

### 查看所有建置資訊

```bash
export PATH="$HOME/bin:$PATH"
cd ~/ai-driven-martech-pipeline/terraform && terraform output
```

畫面會列出資料集 ID、素材儲存庫名稱、遠端連線 ID 與服務帳號等資訊，後續章節會陸續用到。也可以回到 Console 的 BigQuery 頁面，確認左側已出現 `martech_dw` 資料集。

## 5.5 不用了？一行指令全部清除

```bash
cd ~/ai-driven-martech-pipeline/terraform && terraform destroy
```

輸入 `yes` 後，Terraform 會移除本次建立的資料集、儲存庫、服務帳號、權限與預算警報，不會留下持續計費的項目（已啟用的 API 會保留，啟用本身不收費）。教學環境預設 `allow_destroy_with_data = true`，即使資料集或儲存庫裡已有資料也能一併清除；若用於正式環境，請改為 `false` 以防誤刪。這正是 IaC 的一大優勢：建置與清除都一樣簡單，隨時可以重新來過。

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
2. **地理位置一致性**：BigQuery Connection 與 Dataset 必須位於同一位置（本專案為 `US` 多區域），避免跨區域查詢失敗；Cloud Storage 則可獨立放在 us-central1 以適用免費額度。
3. **Billing 權限降級相容**：使用條件式宣告 `count = var.billing_account_id != "" ? 1 : 0`，未提供帳單帳戶 ID 時優雅略過，不影響核心資源建置；`quickstart.sh` 會先以 testIamPermissions 確認帳號是否具備 `billing.budgets.create` 權限，沒有權限時自動留空。
4. **預算警報的 quota project**：在 Cloud Shell 以個人帳號（User ADC）建立預算時，Billing Budget API 需要指定 quota project，否則會出現 quota project 相關錯誤。本專案另外宣告一個 `google.billing` Provider（設定 `billing_project` 與 `user_project_override = true`），只給預算警報資源使用。
5. **heredoc 變數展開**：用 `cat << 'EOF'`（加引號）時變數不會展開，寫入設定檔的會是字面上的 `${VAR}`；需要帶入變數時要改用不加引號的 `cat << EOF`。

---

# 7. 總結與明日預告

今日已成功利用 Terraform 建立高合規、高安全且隨時可重現的 GCP 雲端環境。

**明日預告**：Day 04《即時驗證軌：極簡 Live Demo 站與電商事件追蹤》，我們將搭建微型電商展示介面，並串接 GA4 與綠界 ECPay 測試金流，驗證即時事件資料處理流程！
