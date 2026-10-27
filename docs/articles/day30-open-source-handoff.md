# 1. 前言：30 天走完了

> 2026-10-27 實跑更新（全新專案、換成 gemini-3.8-flash 重跑）：
> - 第 7 章答應的全新專案重跑已完成（2026-10-20 到 10-27）
> - 第 5.5 節的關閉步驟照做一次：排程本來就是 PAUSED，兩個 Cloud Run 服務、流程與排程刪除成功，`terraform destroy` 刪除 34 項（API 設了 `disable_on_destroy = false`，不會被停用，所以第 4 步不受影響），`cloud-run-source-deploy`（asia-east1）、兩個 `run-sources-` 儲存桶（asia-east1 是 Day 04、us-central1 是 Day 26 原始碼部署建的）、`martech_gt` 與 `analytics_` 資料集也刪除了
> - 刪完只剩 Google 自動建立的預設 Compute 服務帳號與已啟用的 API，第 2 步的指令沒加 `--quiet` 時每一行都會要求確認，GA4 的 BigQuery 連結要另外到 GA4 管理介面取消

9 月 15 日發 Day 01 的時候，手上只有一張架構圖和一份目錄骨架，30 天後這套系統從 Terraform 建環境開始，一路做到每天早上自己寫好行銷日報再推進 Slack，中間每一天都要讓程式真的跑過數字也對過才敢發文，有好幾個晚上是在等 BigQuery 跑完再對完答案才寫得下去，走完最大的感覺是鬆一口氣，很怕中間做不到就斷掉，這套系統的每一個結果都有一張表可以回頭查，也都能知道它在哪裡會出錯，之後要回頭繼續使用都沒問題。

最後一天不再加新功能，照昨天的預告分享三件事。

今日核心目標：

1. 交代這個儲存庫怎麼用，不同需求的讀者各從哪裡開始
2. 對照 Day 01 規劃的樣子和最後完成的樣子差在哪裡，以及為什麼改
3. 整理這套系統接上真實資料時要換掉哪幾塊，以及 MarTech 接下來還能往哪裡走

---

# 2. 系統架構全景與設計理念

Day 01 的目錄骨架是照模組分的，Day 07 到 13 放在 `data-pipeline/`，Day 14 到 20 放在 `vertex-ai/`，Day 21 到 25 放在 `agent/`，Day 26 到 28 放在 `deployment/`，實際做下來變成大致一篇一個目錄，`attribution/` 是 Day 08 的歸因，`lift/` 是 Day 17 的素材成效比較，分析與 AI 那幾天的目錄裡都有自己的 `README.md` 和執行腳本還有檢查用的 SQL。

![圖一：左邊是 Day 01 規劃的四個模組目錄，右邊是最後一篇一個目錄的實際結構，中間的線標出每一天搬到哪裡](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day30-plan-vs-actual.svg)

改成一篇一個目錄是因為每一篇文章都要讓讀者只跑那一天的 `run.sh` 就能重現，如果照模組放，同一個目錄裡會有好幾天的程式混在一起，讀者很難分辨哪支是今天要跑的，這樣分的另一個好處是出問題時範圍很清楚，Day 29 整理 `gemini-3.6-flash` 要換的地方，12 個檔案分在 9 個目錄，除了助理相關的 `agent/` 之外每個目錄只對應一篇文章，找到檔案就知道要回去看哪一天。

這樣分的缺點是共用的東西要有固定的家，這個系列的做法是共用的東西都放在 BigQuery 而不是程式裡，Day 07 的事實表和 Day 16 起的用量表 `ops_llm_usage` 還有 Day 25 的單價表 `ref_llm_price` 都在 `martech_dw` 資料集，各天的程式大多只讀表，少數例外像 Day 24 的評測直接沿用 Day 21 的 `agent/ask.py`，所以今天也在儲存庫根目錄的 `README.md` 補上一天一列的對照表，列出每一天的文章、目錄和產出的資料表。

---

# 3. 核心技術深度拆解

## 3.1 這個儲存庫的三種用法

第一種是只讀文章的行銷人，不需要開 Cloud Shell，建議從 Day 08 的歸因和 Day 17 的素材成效比較開始讀，再看 Day 29 的踩坑整理，這三篇講的是行銷判斷，程式只是用來算數字的工具，讀完可以拿去檢查自己團隊的報表有沒有同樣的問題。

第二種是想從零重現整套系統的工程師，起點是 Day 03 的 `scripts/quickstart.sh`，接著 Day 04 把 GA4 連結到 BigQuery 匯出，Day 05 和 Day 06 產生合成資料並載入 BigQuery，Day 07 會先檢查 GA4 已經有每日匯出表才開始建倉儲，之後照根目錄的對照表一天一天跑，會呼叫模型的那幾天 `run.sh` 都會先印出估價再問要不要繼續，這個系列實際花掉並有逐次紀錄的費用約新台幣 34 元，其中包含試跑與重問，讀者重跑的費用會在這個數字附近。

第三種是只想帶走一個模組，Day 07 之後的目錄主要依賴 `martech_dw` 裡的表，要對答案的那幾天另外讀答案資料集 `martech_gt`，例如只想要 Day 23 的護欄，帶走 `agent/guard.py` 再換成自己的禁用詞表就能用，只想要 Day 25 的成本儀表板，帶走 `monitoring/` 的單價表與兩個 view，再讓自己的程式把每次呼叫的 Token 寫進同一個格式的用量表就好，用量表的欄位定義在 `features/extract.sql` 開頭。

## 3.2 規劃的樣子和完成的樣子差在哪裡

主題順序大致照 Day 01 的五個模組走，最後證明最有用的是三篇檢查用的文章，Day 13 是途中把原本的資料引擎複盤改成先把答案藏好再考 AI，Day 24 和 Day 25 雖然在規劃裡，實際做成拿標準答案評測助理的回答和把 Token 用量換算成費用的儀表板，這三篇都不是新功能而是檢查前面做出來的東西對不對，Day 05 設計合成器時就把要找回來的訊號寫進 `ground_truth.json`，後面才有標準答案可以對。

延伸段的部分，Day 18 的 Veo 照計畫渲染了一支 4 秒的短片，沒做到的是 Day 20 原本想加的一組在 Colab 上跑開源 Gemma 4 的對照組，腳本寫到可以印出原文與速度，最後沒有實際試跑，所以文章維持三個 Gemini 等級的比較，腳本留在 `benchmark/` 裡標成選配。

另外 Day 01 規劃 Day 26 是把 Agent 容器化，實際做成把 Day 22 的聊天助理和 Day 23 的護欄合成一個 Cloud Run 服務，只開給指定的 Google 帳號，因為 Day 04 已經做過一次容器部署，重複一次對讀者沒有新東西，助理上線之後 Day 27 的日報和 Day 28 的 Slack 通知才有服務可以呼叫。

## 3.3 接上真實資料時要換掉的三塊

![圖二：合成資料換成真實資料時，左邊的資料來源換掉三塊，中間的倉儲與分析大多沿用，右邊多出實驗對照與個資控管](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day30-real-data.svg)

第一塊是資料來源，合成器產生的五張 raw 表要換成三個真實來源，網站行為用 GA4 的 BigQuery 匯出，標準版資源每天的匯出上限是 100 萬個事件，流量大的網站要先篩事件，串流匯出雖然沒有量的限制，但新使用者的來源與媒介要等每日匯出才有，廣告成效用 BigQuery Data Transfer Service 的連接器，Google Ads 和 Facebook Ads 都有，訂單則從電商後台或 ERP 每天匯出，Day 07 的星狀綱要就是為了這一步設計的，事實表的欄位不變，只要改 `warehouse/build.sql` 裡讀 raw 表的那幾段。

第二塊是標準答案，合成資料最大的好處是知道答案，Day 13 和 Day 24 都靠 `ground_truth.json` 才考得出分數，真實資料沒有藏好的答案，要改成自己製造答案，最直接的做法是增量實驗，挑一部分地區或受眾停投廣告當對照組，兩組的差就是廣告真正帶來的業績，這個數字可以拿來檢查 Day 08 的歸因和 Day 09 的 AI 診斷有沒有說錯。

第三塊是個資與同意，合成資料裡的姓名和手機是假的，真實資料裡的每一筆都受個資法管，Day 23 的遮蔽要在資料進到模型之前做，而且要先確認網站的 Cookie 同意設定，沒有同意的使用者在 GA4 匯出裡的資料會不完整，這會直接影響 Day 08 歸因的樣本。

## 3.4 MarTech 還能往哪裡走

第一個方向是增量實驗，歸因模型只能分配已經發生的轉換，沒辦法回答沒投這支廣告會不會照樣成交，增量實驗是目前最直接的答案，Google 推出的 Meridian GeoX 就是用地區實驗的結果去校正下一段要講的行銷組合模型。

第二個方向是行銷組合模型，Google 開源的 Meridian 不需要使用者層級的資料，用每週的廣告花費和業績就能估算每個通路的貢獻，正好補上 Cookie 越來越少之後歸因看不到的部分，不過官方建議分地區的模型至少要有兩年的每週資料，這個系列的合成資料只有 90 天不夠用，接上真實資料之後把每天的花費與訂單累積成每週的表，等資料夠長再接 Meridian。

這兩個方向的共同點是從找出誰拿到功勞走向證明廣告真的有用，這也是這 30 天一直在做的事，結果要能被驗證才算數。

---

# 4. FinOps 成本防護實踐：三道防線體系

1. **第一道防線：善用免費額度**：系統放著不動時，BigQuery 兩個資料集合計約 0.14 GB，兩個映像檔存放區合計約 145 MB，加上 us-central1 的儲存桶與 Secret Manager 還有暫停中的排程都在免費額度內，只有 Day 04 放在台灣區域的原始碼儲存桶不在 Cloud Storage 的免費區域，約 5 MB，Cloud Run 沒人用時縮到 0 個執行個體不收閒置費用
2. **第二道防線：架構層被動成本防護**：日報排程預設暫停，啟用後一份約新台幣 0.5 元，助理服務每天的花費上限是新台幣 3 元，手動跑的腳本在呼叫模型前都會先印估價，服務與排程則靠每天的上限
3. **第三道防線：Cloud Billing 預算警報**：Day 03 建的預算警報在 Terraform 裡，關服務的時候先留著它，最後執行 `terraform destroy` 才會一起刪除

整個系列有逐次紀錄的費用約新台幣 34 元，加上 Day 18 的 Veo 短片和 Day 24 評分服務的估計約 38 到 43 元，實際金額以帳單為準，看完不打算繼續用的話，第 5 章的 5.5 整理了怎麼把會花錢的東西關掉。

---

# 5. Cloud Shell 實戰演練：取得儲存庫並找到要跑的那一天

## 5.1 事前準備

- 一個有綁帳單的 Google Cloud 專案，以及可以開 Cloud Shell 的帳號
- 照 Day 03 建好環境的讀者直接在 `~/ai-driven-martech-pipeline` 執行 `git pull`

## 5.2 路線 A｜一行指令取得儲存庫

```bash
cd ~ && git clone https://github.com/gminc/ai-driven-martech-pipeline.git && cd ai-driven-martech-pipeline && sed -n '/## 30 天目錄對照/,$p' README.md
```

最後一段會印出根目錄 `README.md` 的對照表，一天一列，找到要跑的那一天再進到對應的目錄看它的 `README.md`。

## 5.3 路線 B｜依需求挑起點

- 從零重現：`bash scripts/quickstart.sh`，接著照 Day 04 連結 GA4 匯出，再照 Day 05 和 Day 06 的步驟載入合成資料
- 只要某一天：先確認 `martech_dw` 裡有那一天需要的表，對照表的主要產出欄位寫的就是前面幾天產生的表
- 只要一個模組：複製那個目錄，把 SQL 裡的 `martech_dw` 換成自己的資料集

## 5.4 驗證：確認目前的環境有哪些東西在雲端

```bash
gcloud run services list && gcloud workflows list --location us-central1 && gcloud scheduler jobs list --location us-central1
```

照著系列做到 Day 28 的話，會看到 `martech-assistant` 與 `martech-live-demo` 兩個服務，一個流程 `martech-daily-report`，以及狀態是 `PAUSED` 的排程 `martech-daily-report-morning`，這四個都不在 Terraform 裡，關的時候要自己處理。

## 5.5 不用了怎麼關

依序做，前兩步做完就不會再有呼叫模型與運算的費用，剩下的是儲存：

1. 暫停日報排程：`gcloud scheduler jobs pause martech-daily-report-morning --location us-central1`
2. 刪除不在 Terraform 裡的兩個 Cloud Run 服務與日報的流程和排程，指令列在下方
3. 回到 `terraform/` 執行 `terraform destroy`，資料集與儲存桶連同裡面的資料，加上服務帳號和映像檔儲存庫還有 Slack 密鑰與預算警報會一起刪除，執行前可以先用 `terraform plan -destroy` 看清單
4. Terraform 管不到的東西要自己刪，Day 04 原始碼部署留下的 `cloud-run-source-deploy` 映像檔存放區和 `run-sources-` 開頭的儲存桶照 Day 04 第 5 章的指令刪除，還有兩個資料集：答案資料集 `martech_gt` 和 GA4 匯出的 `analytics_` 開頭資料集，GA4 的匯出要先在 GA4 管理介面取消 BigQuery 連結，不然隔天又會寫進新的資料

步驟 2 的指令：

```bash
gcloud run services delete martech-assistant --region us-central1
gcloud run services delete martech-live-demo --region asia-east1
gcloud workflows delete martech-daily-report --location us-central1
gcloud scheduler jobs delete martech-daily-report-morning --location us-central1
```

完全不會再用的話，也可以直接在主控台關閉整個專案，30 天內還能復原。

---

# 6. 工程實務避坑指南

1. **先對帳再接分析**：GA4 匯出和廣告平台與後台訂單三邊的營收一定對不起來，接上第一天先把差距記下來，之後每天看差距有沒有變大
2. **匯出上限先算好**：GA4 標準版每天 100 萬個事件，超過要先篩事件，不然分析的就是不完整的資料
3. **欄位對應寫成表**：真實資料的 UTM 命名會亂，活動名稱和素材 ID 的對應要放在 BigQuery 的一張表裡維護，不要寫死在 SQL
4. **個資在進模型前就遮掉**：回答前的檢查擋得住外流，但個資一旦送進模型就已經離開自己的資料庫，Day 23 的遮蔽要放在送出之前
5. **留一組對照**：沒有藏好的答案就自己做答案，每一次大規模調整預算都留一部分不動當對照組

---

# 7. 總結與完賽

這 30 天從一張架構圖做到一套每天會自己寫日報的系統，程式和文章都放在 GitHub 上，大致一篇一個目錄，從哪一天開始讀都可以，接上真實資料要換的是資料來源、標準答案和個資控管三塊，倉儲與分析大多可以沿用，接下來 MarTech 值得投入的是增量實驗和行銷組合模型，兩者都是在回答廣告到底有沒有用。

最後再提醒一次，`gemini-3.6-flash` 在 2026 年 11 月 19 日停用，之後照著這個系列重做的讀者會在 12 個程式檔遇到錯誤，Day 29 第 5 章有找出這些地方的指令，完賽之後我會開一個全新的專案從 Day 03 照文章重跑一次，把模型換成 `gemini-3.8-flash` 並實跑確認後更新到儲存庫。

謝謝一路讀到最後的讀者，30 天完賽！
