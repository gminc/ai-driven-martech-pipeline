# Day 01 | AI MarTech 架構全景圖 —— 告別數據孤島，用 Google Cloud + Vertex AI 重塑資料驅動行銷循環

## 1. 前言：現代 MarTech 面臨的三大結構性斷層

在數位行銷與廣告投放的日常中，行銷人員與資料工程團隊經常陷入以下困境：

- **歸因斷層（The Attribution Gap）**：依賴傳統的 Last-Click（最終點擊）歸因，忽略消費者在搜尋、社群與影音通路的多觸點歷程，導致上層漏斗（Top of Funnel）的品牌價值被嚴重低估，廣告預算配置失真。
- **素材黑箱（The Creative Black Box）**：廣告報表能精確記錄 CTR、CPC、ROAS 等結構化指標，但對於「廣告圖文素材」這種非結構化資產，系統只視為一組冷冰冰的圖片 URL。素材的色調、排版、主標題情緒、代言人神情與 CTA 按鈕位置，往往無法量化，更無法與轉換成效形成科學關聯。
- **決策延遲與維運孤島（Operational Silos）**：從數據分析、洞察歸納到調整下一代素材，跨部門溝通長達數週；等發現 ROAS 崩跌時，行銷預算早已消耗殆盡。

本系列文《**AI-Driven MarTech：用 Google Cloud + Vertex AI 打造全自動廣告歸因與多模態素材分析系統**》，旨在打破業務邏輯與技術工程的邊界，建立一套兼具企業級深度與實戰價值的端對端解決方案。

> 📌 **名稱說明**：Google 已於 2026 年 4 月將 Vertex AI 更名為 **Gemini Enterprise Agent Platform**，官方說明 API、SDK 與端點皆維持不變。本系列沿用報名時的「Vertex AI」名稱，文中兩者指的是同一個平台。

---

## 2. 核心架構：雙軌資料管線（Dual-Track Pipeline）

為了同時驗證「即時性與真實性」並支撐「大數據分析深度」，我們設計了企業級的**雙軌資料管線**：

- **軌道 A（即時驗證軌 - Live Demo）**：建置極簡且真實運作的電商展示介面（部署於 Firebase / Cloud Run），串接真實 GA4 追蹤與 Stripe Test Mode 交易事件。每次讀者點擊與結帳，皆能即時送入資料管線，證明系統真實暢通。
- **軌道 B（歷史規模軌 - Data Synthesizer）**：透過自研的 Python 合成管線，注入符合真實電商統計指標（CTR 1.5–3.5%、CVR 1.8–2.5%、客單價常態分佈）的 **90 天、50 萬筆跨通路日誌**，讓 BigQuery 多觸點歸因、顧客分群與 AI 模型擁有具說服力的大樣本基底。

---

## 3. 系統總體架構全景圖

整個專案由數據採集、倉儲建模、多模態特徵工程到自動化 AI 代理，構成完整的數據循環：

![AI-Driven MarTech 系統總體架構全景圖](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/architecture-overview.svg)

### 架構分層核心技術一覽

| 架構分層 | 核心技術 / 服務 | 核心任務 |
| :--- | :--- | :--- |
| **前端展示與事件** | Firebase Hosting, GA4, Stripe API | 承載 Live Demo、發送真實用戶互動與轉換事件 |
| **資料倉儲與建模** | BigQuery, BigQuery ML, Cloud Storage | 跨通路日誌清洗、多觸點歸因計算、分區分群最佳化 |
| **AI 核心引擎** | Vertex AI（Agent Platform）, Gemini 3.x（Flash-Lite / Flash / Pro） | SQL 遠端直接診斷、素材視覺特徵結構化解析、Context Caching 降本 |
| **自動化與 AI 代理** | Function Calling, Cloud Run, Cloud Workflows | 自然語言查報表、異常指標自動巡檢、Slack 警報全流程整合 |
| **維運與安全防護** | Terraform, Cloud Monitoring, Safety Settings | 基礎設施程式碼化 (IaC)、Token 成本防爆、Prompt 護欄 |

---

## 4. 30 天連載實戰地圖

整個參賽旅程將依序推進五大核心模組：

1. **模組一：環境建置、範例網站與雙軌資料工程（Day 01–07）**
   - 從 Terraform 一鍵部署、Live Demo 範例網站搭建，到寫出符合統計分佈的電商日誌合成器與 BigQuery 星狀綱要建模。
2. **模組二：大數據歸因與 BigQuery × AI 深度整合（Day 08–13）**
   - 實作多觸點歸因（MTA）演算法；直接在 BigQuery 裡用 SQL 遠端呼叫 Gemini 進行 ROAS 異常診斷，並實測 Context Caching 對重複輸入 Token 的降本效果。
3. **模組三：Gemini 3.x 視覺多模態解構廣告素材（Day 14–20）**
   - 告別主觀審美！用 Gemini 批次抽取素材色調、文字位置、神情表情，透過 Structured Outputs 轉化為特徵向量，與轉換率進行交叉回歸分析。
4. **模組四：行銷 Agent 打造與安全合規治理（Day 21–25）**
   - 利用 Function Calling 打造能看懂報表與素材的行銷 Agent；建立企業級 Prompt 護欄、PII 去識別化與 Vertex AI 評測機制。
5. **模組五：無伺服器部署、全自動工作流與完整交付（Day 26–30）**
   - 將 Agent 封裝上 Cloud Run，用 Cloud Workflows 串接每日排程，在 Slack 自動推播異常診斷與最佳化建議，並交付完整 GitHub 開源專案。

---

## 5. 開發環境與開源骨架：基於 Cloud Shell 的「零設定」體驗

為了讓所有讀者都能「**零門檻完整重現**」，本專案完全摒棄複雜的本機環境安裝。我們全程採用 Google Cloud 內建的 **Cloud Shell & Cloud Shell Editor**（瀏覽器版 VS Code）作為核心開發環境：

- **免安裝 SDK**：預載 gcloud、git、terraform、docker 與 python3，省去數小時的環境設定。
- **5GB 永久儲存**：程式碼安全存放在 Cloud Shell 家目錄，關閉瀏覽器也不會遺失。
- **雲端完整 IDE**：提供如桌面端 VS Code 般的樹狀目錄、語法上色與終端機整合。

### 專案模組目錄骨架

整個 30 天實戰程式碼，嚴格按照功能模組劃分，保持簡潔清晰：

> 💡 **工程規範亮點：Docs as Code 雙軌版控**  
> 為了確保 30 天連載內容與程式碼完全同步、杜絕誤刪並提供最純粹的開源體驗，本專案實踐「Docs as Code」哲學：所有文章 Markdown 原始檔均同步存放於 `docs/articles/`，讀者在 GitHub 上也能隨時以 Markdown 離線閱讀或查看修訂歷程。

```text
ai-driven-martech-pipeline/
├── .env.example             # 環境變數設定範本（GCP Project ID、Region、模型 ID 等）
├── .gitignore               # 嚴密排除金鑰、Terraform 狀態與暫存檔
├── LICENSE                  # MIT 開源授權協議
├── README.md                # 專案說明與架構總覽
├── terraform/               # Day 03: 基礎設施即程式碼 (IaC)
├── live-demo/               # Day 04: 極簡電商展示介面 (Firebase / GA4 / Stripe)
├── data-pipeline/           # Day 05-13: 50萬筆日誌生成器與 BigQuery MTA 歸因
│   ├── synthetic/           # 電商數據合成器 (synthetic_pipeline.py)
│   ├── schemas/             # 星狀綱要 DDL
│   └── sql/                 # 多觸點歸因與 ML 語法
├── vertex-ai/               # Day 14-20: Gemini 3.x 視覺多模態與特徵工程
│   ├── vision_extractor/    # 廣告圖文特徵抽取腳本
│   ├── schemas/             # Structured Outputs 結構化定義
│   └── caching/             # Context Caching 實測降本
├── agent/                   # Day 21-25: 決策中樞、資安防護與評測
│   ├── tools/               # Function Calling 工具定義
│   ├── guardrails/          # PII 去識別化與 Prompt 護欄
│   └── evaluation/          # Vertex AI 評測管線
├── deployment/              # Day 26-28: Cloud Run 容器化與 Workflows 排程
│   ├── cloud-run/           # Dockerfile 與服務設定
│   ├── workflows/           # 工作流 YAML
│   └── slack-bot/           # Slack Webhook 自動推播
└── docs/                    # 專案架構圖與 Docs-as-Code 文檔
    ├── articles/            # 30 天文章 Markdown 原文同步版控 (Docs as Code)
    └── images/              # 架構圖與成效視覺化圖檔
```

---

## 6. 開源專案與互動宣告

本專案堅持「**程式碼完全開源、架構可完整重現、理論有數據佐證**」的原則：

- 專案程式碼倉庫：https://github.com/gminc/ai-driven-martech-pipeline（隨進度同步釋出）
- 線上範例網站預告：Day 04 將正式釋出 Live Demo 範例網站連結供大家點擊測試。

**明日預告**：Day 02《技術評估：為何選 Google Cloud + Vertex AI？從生態整合到成本效益的深度剖析》，我們明天見！
