# AI-Driven MarTech：用 Google Cloud + Vertex AI 打造端對端廣告歸因與多模態素材分析系統

[![2026 iThome 鐵人賽](https://img.shields.io/badge/2026_iThome-鐵人賽_Build_on_Google_AI-blue.svg)](https://ithelp.ithome.com.tw/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

本專案為 2026 iThome 鐵人賽【Build on Google AI】組參賽作品之官方開源程式碼倉庫。
核心宗旨為整合 Google Cloud 現代資料倉儲與 Vertex AI（現為 Gemini Enterprise Agent Platform）多模態模型，實現現代 MarTech 的全自動資料與決策流程。

## 30 天目錄對照

程式大致一篇一個目錄，目錄下的 `README.md` 寫完整參數與執行方式，文章原文放在 `docs/articles/`，表格裡的資料表都在 BigQuery 的 `martech_dw` 資料集。

| Day | 文章 | 目錄 | 主要產出 |
| --- | --- | --- | --- |
| 01 | [AI MarTech 架構全景圖](https://ithelp.ithome.com.tw/articles/10410394) | （只有文章） | 整體架構與 30 天規劃 |
| 02 | [為何選 Google Cloud + Vertex AI](https://ithelp.ithome.com.tw/articles/10411597) | （只有文章） | 技術選型與成本比較 |
| 03 | [Terraform 輕鬆建置 GCP 環境](https://ithelp.ithome.com.tw/articles/10412025) | `terraform/`、`scripts/quickstart.sh` | 資料集 `martech_dw`、服務帳號、BigQuery 連線、預算警報 |
| 04 | [極簡 Live Demo 站與電商事件追蹤](https://ithelp.ithome.com.tw/articles/10413094) | `live-demo/`、`scripts/deploy_live_demo.sh` | Cloud Run 展示站、GA4 事件、綠界測試金流 |
| 05 | [電商大數據合成器](https://ithelp.ithome.com.tw/articles/10413608) | `synthesizer/` | 90 天合成資料、藏好的標準答案 `ground_truth.json` |
| 06 | [90 天 50 萬筆灌入 BigQuery 與分佈驗證](https://ithelp.ithome.com.tw/articles/10414309) | `synthesizer/bigquery/` | `raw_events`、`raw_orders` 等五張 raw 表 |
| 07 | [廣告成效星狀綱要設計](https://ithelp.ithome.com.tw/articles/10414882) | `warehouse/` | `fct_events`、`fct_orders`、`fct_ad_daily` 與維度表 |
| 08 | [客人看了三支廣告才下單，功勞到底該算誰的？](https://ithelp.ithome.com.tw/articles/10415538) | `attribution/` | `mart_attribution` |
| 09 | [廣告成效突然跳水？直接在 SQL 裡叫 AI 找出原因](https://ithelp.ithome.com.tw/articles/10415974) | `diagnosis/` | `diag_summary`、`mart_diagnosis` |
| 10 | [同一份資料問 AI 十次，不用付十次錢的快取機制](https://ithelp.ithome.com.tw/articles/10416349) | `caching/` | `cache_runs` |
| 11 | [讓資料自己分組，才發現你的顧客其實只有這幾種人](https://ithelp.ithome.com.tw/articles/10417187) | `segmentation/` | `mart_customer_segment` |
| 12 | [哪種客人值得多投廣告？讓機器學習預測顧客的長期價值](https://ithelp.ithome.com.tw/articles/10417521) | `ltv/` | `mart_customer_ltv` |
| 13 | [先把答案藏好再來考 AI，看它能找回幾個](https://ithelp.ithome.com.tw/articles/10417941) | `acceptance/` | `blind_findings`、`blind_result` |
| 14 | [點擊率看不出來的秘密，全都藏在廣告圖裡](https://ithelp.ithome.com.tw/articles/10418373) | `multimodal/`、`creatives/` | 物件表 `obj_creatives`、`mm_describe` |
| 15 | [讓 AI 看完廣告圖，乖乖照格式交出結構化資料](https://ithelp.ithome.com.tw/articles/10418503) | `structured/` | `mm_structured` |
| 16 | [讓 AI 一口氣看完所有廣告圖再整理出視覺特徵](https://ithelp.ithome.com.tw/articles/10419209) | `features/` | `mart_creative_features`、用量表 `ops_llm_usage` |
| 17 | [什麼樣的廣告圖比較會賣？](https://ithelp.ithome.com.tw/articles/10419572) | `lift/` | `mart_creative_lift` |
| 18 | [靈感卡關時，讓 Gemini 根據成效幫你打下一版素材草稿](https://ithelp.ithome.com.tw/articles/10419997) | `drafts/` | `mart_creative_drafts` |
| 19 | [廣告說一套、網站寫一套？叫 AI 幫你抓出來](https://ithelp.ithome.com.tw/articles/10420166) | `consistency/` | `mart_ad_page_gaps` |
| 20 | [便宜的輕量模型到底夠不夠用？直接實測來看](https://ithelp.ithome.com.tw/articles/10420638) | `benchmark/` | `mart_bench_features`、`mart_bench_gaps` |
| 21 | [教 AI 自己去查資料庫免得它在那邊瞎猜](https://ithelp.ithome.com.tw/articles/10421383) | `agent/ask.py`、`agent/tools.py` | `mart_fc_score` |
| 22 | [不用寫 SQL，跟 AI 聊天就能查出上週哪支廣告最貴](https://ithelp.ithome.com.tw/articles/10421560) | `agent/chat.py` | `chat_turns` |
| 23 | [別讓你的 AI 助理被惡意指令套出個資或亂講話](https://ithelp.ithome.com.tw/articles/10421944) | `agent/guard.py` | `guard_runs` |
| 24 | [AI 給的分析到底能信幾分？](https://ithelp.ithome.com.tw/articles/10422258) | `evaluation/` | `eval_scores` |
| 25 | [每天用了多少 Token？打開儀表板一目了然](https://ithelp.ithome.com.tw/articles/10422690) | `monitoring/` | 單價表 `ref_llm_price`、`v_llm_usage_daily` |
| 26 | [把 AI 助理部署上線，讓全團隊都能直接用](https://ithelp.ithome.com.tw/articles/10422941) | `agent/serve.py`、`scripts/deploy_assistant.sh` | Cloud Run 助理服務、`serve_turns` |
| 27 | [早上一進辦公室，AI 行銷日報已經自動寫好了](https://ithelp.ithome.com.tw/articles/10423358) | `workflows/`、`scripts/deploy_daily_report.sh` | Workflows 流程、`daily_reports` |
| 28 | [廣告出狀況時，讓 Slack 機器人第一時間通知你](https://ithelp.ithome.com.tw/articles/10423581) | `workflows/` | Slack 通知、`ops_notifications` |
| 29 | [做完一套 AI 行銷系統後我踩到的坑與心路歷程](https://ithelp.ithome.com.tw/articles/10423920) | （只有文章） | 踩坑整理、`gemini-3.6-flash` 停用前的檢查 |
| 30 | [整套系統開源交付之後，MarTech 還能怎麼走？](https://ithelp.ithome.com.tw/articles/10424186) | （只有文章） | 儲存庫用法、規劃與實際的對照、接上真實資料要換的三塊 |

## 模型停用提醒

`gemini-3.6-flash` 於 2026-11-19 停用，之後的請求會回 HTTP 404，找出用到它的地方與替代模型見 [Day 29](https://ithelp.ithome.com.tw/articles/10423920) 第 5 章。程式已經換成 `gemini-3.8-flash`（Flash 模型由環境變數 `GEMINI_MODEL_FLASH` 決定，沒設就是 `gemini-3.8-flash`），2026-10 在全新專案實跑確認過，結果見下一節。`gemini-3.8-flash` 從 2027-01-01 起單價加倍（global 端點每百萬 Token 輸入 1.50、輸出 7.50 美元），屆時要更新 `agent/tools.py` 的 `PRICES` 與單價表 `ref_llm_price`。

## 2026-10 實跑確認

2026-10-20 到 10-27 在全新的測試專案 `martech-release-2026`，用 `accept/final` 分支、Flash 模型 `gemini-3.8-flash` 從 Day 01 照順序重跑到 Day 28，跑完照 Day 30 第 5.5 節把資源全部刪掉。

| 天 | 結果 |
|---|---|
| Day 01–08 | 通過；Day 03 的 Plan 是 34 to add，Day 04 綠界測試付款流程和文章不同，Day 07 的一致項數與 GA4 列數依讀者自己的 GA4 資料而異 |
| Day 09–13 | 通過；判讀結論與文章相同，信心分數、`with_campaign` 等每次跑會變，Day 10 第一次 `cache.sh create` 可能回 403，重跑即可 |
| Day 14–18 | 通過；Day 14 要先上傳素材圖並先跑 Day 15 的 `move_design.sql`，Day 18 誇大用語命中數變少 |
| Day 19–20 | 通過；3.8-flash 截圖與文字都 21/21，簡單題改用 enum 補問後 95/95 |
| Day 21–25 | 通過；3.8-flash 偶爾 429，Day 24 換模型後先把舊的人工評分檔改名再匯出 |
| Day 26 | 通過；七句 16 項檢查全過，查過廣告再要顧客資料被程式拒絕，偶爾一句遇到 429 |
| Day 27 | 部署與 22 項檢查通過；正式日報常因 429 或模型太慢只答出 2/3（第 1 題「上週花費」），需要隔天排程或手動重跑 |
| Day 28 | 通過；Slack 測試、異常警報（含 2026-08-27 全站追蹤碼失效重播）與密鑰讀不到的失敗路徑都實測過 |
| Day 29–30 | 只有文章；Day 30 第 5.5 節的關閉步驟照做一次，34 項 Terraform 資源與 Terraform 管不到的服務、存放區、儲存桶、資料集都刪掉了 |

已知限制：

- `gemini-3.8-flash` 會間歇回 429 RESOURCE_EXHAUSTED（配額不足），助理服務遇到時那一句回「出了狀況」、不重試，用量照最壞值記帳（429 實際應不收費，以帳單為準）
- 日報第 1 題拿到兩次廣告花費查詢的結果後，下一次模型呼叫常超過 45 秒或回 429，所以日報可能只答出 2/3，這次實跑決定接受，不再改程式
- `agent/run.sh`、`consistency/run.sh`、`benchmark/run.sh`、`evaluation/run.sh` 每次執行會把當下的 commit、有沒有未 commit 的修改與 Flash 模型寫進 `martech_dw.ops_run_versions`（`scripts/run_version.sh`），查得到每一份結果是哪一版程式跑出來的

