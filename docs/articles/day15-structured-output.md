# 1. 前言：描述是給人讀的，欄位才是給 SQL 用的

Day 14 讓 Gemini 看了三張素材圖，12 段描述的畫面主體和圖上的字全部讀對，但把這 12 段丟進 `GROUP BY` 會得到 12 組，因為沒有兩段是一樣的，我試著用關鍵字硬分，有沒有人物 12 次都對，暖色卻判錯了 5 次，同一張圖第一次寫「燕麥色」沒被判成暖色，第二次寫「米色」就被判成暖色，規則跟著措辭跑，這種資料沒辦法拿來計算。

問題不在 Gemini 看不懂圖，而在我沒有告訴它要交什麼，自由描述適合給人讀，要拿來分組就要先把欄位定下來，有沒有人物只能填是或否，主色只能從幾個選項裡挑，今天做的就是這件事，讓 Gemini 每看一張圖就交出固定的幾個欄位，讓每一張圖變成一列可以查詢、可以分組的資料，順便處理一個 Day 07 留下來的隱患，這批素材的設計規格一直放在分析資料集裡，等於答案和考卷放在同一個抽屜，今天的雲端費用都以 1 美元 32 元換算成新台幣。

今日核心目標：

1. 把素材的設計規格搬進答案資料集 `martech_gt`，分析資料集 `martech_dw` 裡不再有答案
2. 用 `AI.GENERATE` 的 `output_schema` 讓 Gemini 看一張圖就交出五個固定欄位，回來直接是可以 `GROUP BY` 的資料
3. 比較兩種鎖格式的寫法和有沒有判斷標準的差別，用六張圖抽查它答得對不對、每次答得一不一樣

---

# 2. 系統架構全景與設計理念

![圖一：設計規格從分析資料集搬進答案資料集，AI.GENERATE 帶著 output_schema 看圖，每張圖回來一列固定欄位，對答案只在報表這一步發生](https://raw.githubusercontent.com/gminc/ai-driven-martech-pipeline/main/docs/images/day15-structured-output.svg)

| 步驟 | 做什麼 | 產出 |
| --- | --- | --- |
| 搬家 | 四個設計欄位從 `dim_creative` 搬進答案資料集，加上圖上標題 | `martech_gt.gt_creative_design`，24 列 |
| 挑樣本 | 六張圖，四個設計欄位的每一個值都至少出現一次 | `martech_dw.mm_sample`，6 列 |
| 看圖 | 六張圖各跑五輪，每次回來五個欄位 | `martech_dw.mm_structured`，30 列 |
| 對答案 | 只在報表這一步把抽取結果和答案表放在一起 | `report.sql` 第 3、4 段 |

💡 **核心工程理念**：

1. **答案只放一個地方**：抽取用的 SQL 只讀 `martech_dw`，答案表在 `martech_gt`，`run.sh` 會檢查挑圖和看圖的 SQL 沒有碰到答案表，也確認 `dim_creative` 裡已經沒有設計欄位可以 JOIN
2. **型別交給 schema，判斷標準寫進題目**：`output_schema` 能保證回來的是 BOOL 和 STRING，但米白色的背景算不算暖色，要在題目裡講清楚
3. **先抽查再放大**：今天只看六張，看寫法、Token 和答對率，Day 16 放大到 24 張時會順手看答對率，正式的評測在 Day 20

---

# 3. 核心技術深度拆解

## 3.1 先搬家：答案不能放在分析資料集裡

這批素材是合成的，每一張圖都照著一份設計規格畫出來，有沒有人物、按鈕位置、主色、文字多寡，Day 07 建 `dim_creative` 的時候我把這四欄一起放進了 `martech_dw`，當時想的是 Day 16 抽特徵、Day 20 評測要拿它對答案，放在維度表最方便，Day 11 起顧客類型的答案表就放在獨立的 `martech_gt`，Day 11 之後各目錄的 `run.sh` 都會檢查分析用的 SQL 沒有讀到 `martech_gt`，但這四欄不在檢查範圍內，任何一段分析 SQL 只要 JOIN 一下 `dim_creative` 就拿得到答案，檢查也不會擋。

今天第一步就是把它們搬走，`move_design.sql` 從 Day 06 原樣載入的 `raw_creatives` 把四欄抄進 `martech_gt.gt_creative_design`，再用 `ALTER TABLE ... DROP COLUMN IF EXISTS` 從 `dim_creative` 拿掉，答案表另外多一欄 `headline`，是合成素材時照主打商品畫上去的標題文字，之後可以逐字對，主打商品 `product_focus` 是廣告後台本來就有的欄位，留在 `dim_creative`，你在 Day 07 建的 `dim_creative` 跑完今天的搬家會少這四欄，這是刻意的，`warehouse/ddl.sql` 與 `build.sql` 已經同步改掉，重跑 Day 07 也不會再有，Day 14 的報表第 4 段也改成讀答案表，`git pull` 之後想重看 Day 14 的報表，先跑今天的搬家（免費、不呼叫 Gemini），再單獨執行 `multimodal/report.sql` 就好，不用整套重跑，真實的廣告後台本來就沒有這四欄，設計師交圖時不會順手填一張表，這些資訊只能從圖裡讀出來，這正是今天要做的事。

## 3.2 先定欄位再問：五個欄位怎麼來的

Day 14 說要讓每一張圖都有一組可以 `GROUP BY` 的欄位，今天定五個，前四個和設計規格對齊，第五個是圖上的標題：

| 欄位 | 型別 | 選項 |
| --- | --- | --- |
| `has_person` | BOOL | true、false |
| `cta_position` | STRING | center、bottom_right、none |
| `dominant_color` | STRING | warm、cool、neutral |
| `text_density` | STRING | low、high |
| `headline` | STRING | 圖上最大的一行標題，照原文抄 |

選項是刻意收得很緊的，主色只有三種、按鈕位置只有三種，這不是因為廣告圖只有這幾種樣子，而是欄位是為了之後的分析定的，Day 17 要把視覺特徵和點擊率放在一起比，一個欄位如果有二十種值，24 張圖分下去每一組只剩一兩張，什麼都比不出來，所以定欄位的時候要先想清楚之後要怎麼分組，值的數量寧可少，真實專案裡這張表應該由行銷和設計一起定，定完就是規格，圖照著做、AI 照著讀。

## 3.3 兩種鎖法：output_schema 鎖型別，response_schema 鎖選項

BigQuery 有兩種方式規定 Gemini 的回答格式，差別在回來的東西，一種直接是欄位，一種是還要再解析的 JSON 字串，這決定之後每一段 SQL 怎麼寫，第一種是 `AI.GENERATE` 自己的 `output_schema` 參數，寫法和建表的欄位定義一樣，下面是 A 輪的看圖部分，外層寫進結果表的 `INSERT` 拿掉了：

```sql
SELECT creative_id, g.has_person, g.cta_position, g.dominant_color, g.text_density, g.headline
FROM (
  SELECT s.creative_id,
    AI.GENERATE(
      (prompt_a, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.5-flash-lite',
      output_schema => 'has_person BOOL, cta_position STRING, dominant_color STRING, text_density STRING, headline STRING',
      model_params => JSON '{"generation_config": {"max_output_tokens": 256, "thinking_config": {"thinking_budget": 0}}}'
    ) AS g
  FROM martech_dw.obj_creatives o
  JOIN martech_dw.mm_sample s USING (uri)
);
```

`prompt_a` 是題目，用 `DECLARE` 宣告在最前面，回傳的結構裡 `result` 不見了，換成五個欄位，`g.has_person` 就是 BOOL，可以直接 `WHERE g.has_person` 或 `GROUP BY g.dominant_color`，不用解析任何東西，這是它最大的好處，限制是它只能鎖型別，STRING 就是任何字串，沒辦法規定只能填 warm、cool、neutral 三個值之一，選項只能寫在題目裡。

第二種是 Day 09 用過的做法，把 Gemini 的 `response_schema` 放進 `model_params`，今天換到 `AI.GENERATE` 上寫法一樣，這裡可以對 STRING 欄位加 `enum`，模型只能從清單裡挑，回來的是一段 JSON 字串放在 `result` 欄，要再用 `JSON_VALUE(g.result, '$.dominant_color')` 一個一個取出來，BOOL 還要 `SAFE_CAST`，多一層解析但照 Gemini 的規格值只會從清單裡出來，兩種寫法今天各跑，題目一樣、圖一樣，看差在哪裡，完整的五輪 SQL 在 [structured/extract.sql](https://github.com/gminc/ai-driven-martech-pipeline/blob/main/structured/extract.sql)。

題目也分兩版，第一版只列欄位和選項，第二版加上判斷標準，例如按鈕要看有沒有寫著「立即選購」的深色按鈕，主色看背景和大面積的顏色，白、米白、亞麻、淺灰算 neutral，商品本身的顏色不算，文字多寡看標題之外有沒有賣點文字或圓形標籤，這幾條就是 Day 14 關鍵字分組判錯的地方，一次輸入是一張圖 1,104 個 Token 加題目，只列選項的題目 219 個、加判斷標準 381 個，多了 162 個，`response_schema` 再多 69 個。

## 3.4 結果：30 次只錯 1 個欄位，出在只列選項的 A 輪

六張樣本圖是照「四個設計欄位每一個值都至少出現一次」挑的，含 Day 14 的三張，五輪共 30 次呼叫全部成功，每次回來五個欄位都有值，沒有一次填出選項以外的東西，包括只鎖型別的那一輪：

| 輪 | 鎖法 | 題目 | 模型 | 四欄全對 | 錯的地方 |
| --- | --- | --- | --- | --- | --- |
| A | output_schema | 只列選項 | 3.5-flash-lite | 5／6 | r2 的文字多寡答成 low |
| B1 | output_schema | 加判斷標準 | 3.5-flash-lite | 6／6 | 無 |
| B2 | 同 B1 再跑一次 | 加判斷標準 | 3.5-flash-lite | 6／6 | 無，和 B1 五欄全部相同 |
| C | response_schema enum | 加判斷標準 | 3.5-flash-lite | 6／6 | 無 |
| D | 同 C | 加判斷標準 | 3.6-flash | 6／6 | 無 |

唯一的錯在 A 輪，cr-meta-evg-r2 是 Meta 常態活動裡圖上文字最多的那一張，標題之外還有兩行賣點和「新品」「免運」兩個圓形標籤，沒有判斷標準時 flash-lite 說它文字「少」，題目加上「標題之外還有賣點文字或圓形標籤填 high」之後，B1、B2、C 三輪都答對，方向和 Day 09 的經驗一致，「多」和「少」的界線我沒講，模型就自己畫一條，但 A 只跑一次、只錯一格，分不出是沒給界線還是那一次剛好答錯，要到 Day 16 的 24 張才算數。

主色 30 次全對是今天最意外的結果，Day 14 用關鍵字判暖色錯了 5 次，三次是商品本身的米色毛巾被算進暖色，兩次是米白、亞麻的畫面被說成「米色調」「大地色系」，今天題目裡寫明這些算 neutral、商品本身的顏色不算，米白亞麻背景的 p1 和 r2 五輪都答 neutral，標題 30 次逐字全對，「重訓日的厚底毛巾襪」「每天洗臉的純棉毛巾」一個字都沒抄錯，同一張圖問兩次，B1 和 B2 六張五欄完全相同，Day 14 自由描述時同一張圖兩次措辭不同的問題，在這六張上沒有再出現。

enum 在這六張上看不出差別，A 輪沒有 enum 也沒有填出選項外的值，C 輪有 enum，答對率和 B1 一樣，所以今天的資料沒辦法說 enum 讓答案變好，它的價值是 Gemini 規格上的保證，回來的值只會從清單裡出來，這是給 Day 16 處理 24 張時的保險，不是這次觀察到的差異，3.6-flash 這一輪也是全對，六張圖分不出兩個模型的高下，Day 16 放大到 24 張時會順手看答對率，正式的評測（模型對比、單價、延遲）在 Day 20。

要老實說的是這六張圖的條件很好，底圖是 AI 生的、文字和按鈕由程式畫上去、規格本來就只有三種主色三種按鈕位置，挑樣本的時候我也看過規格，真實的廣告圖有漸層、有多個按鈕、有半透明的疊字，六張抽查只能說寫法可行，不能說正確率是 100%。

---

# 4. FinOps 成本防護實踐：三道防線體系

1. **第一道防線：善用 Google Cloud 每月免費額度**：搬家、挑樣本、檢查與報表都是查詢，含在 BigQuery 每月 1 TiB 的查詢免費額度內，物件表和 bucket 沿用 Day 14，沒有新的儲存費
2. **第二道防線：架構層被動成本防護**：會花錢的只有看圖的 30 次，`run.sh` 呼叫前先用最壞情況估價，每次輸入以 1,600 個 Token、輸出以上限 256 個計，約新台幣 1.4 元，看到數字輸入 yes 才會呼叫，實際合計新台幣 0.78 元，輸出只有 36 到 59 個 Token，約是 Day 14 自由描述一百多個的一半，換算成 1,000 張圖，flash-lite 加判斷標準（B1）約 21 元、3.6-flash 加 enum（D）約 48 元
3. **第三道防線：Cloud Billing 預算警報**：沿用 Day 03 由 Terraform 建立的預算警報（新台幣帳戶 NT$ 300／美元帳戶 US$ 10），50%、80%、100% 三段通知，今天的操作不會觸發

單價用的是非 global 端點的價格，`endpoint` 只寫模型名稱時 BigQuery 會把請求送到非 global 的端點，比 global 高一成，3.5-flash-lite 每百萬 Token 輸入 0.33、輸出 2.75 美元，3.6-flash 輸入 0.825、輸出 4.125 美元，Day 09 和 Day 13 發表時用的是 global 單價，這兩篇的金額和程式已經在今天一起更正，Day 10 因為快取只能建在 global，端點寫的是完整網址，單價本來就是對的。

`max_output_tokens` 從 Day 14 的 1,024 降到 256，五個欄位的 JSON 不到 60 個 Token，留四倍的餘裕，`check.sql` 有一項確認沒有任何一次撞到上限，撞到上限的 JSON 會被截斷、解析出來全是空值，`thinking_budget` 一樣設 0。

---

# 5. Cloud Shell 實戰演練：一行指令從搬家到對答案

## 5.1 事前準備

- 先在 `~/ai-driven-martech-pipeline` 執行 `git pull`，取得 Day 15 的程式與 Day 07 更新後的建表腳本
- `gcloud config get-value project` 要印出你的專案 ID
- 已完成 Day 14，`martech_dw` 裡有物件表 `obj_creatives`，bucket 裡有 24 張圖
- 已完成 Day 11，答案資料集 `martech_gt` 存在
- 確認 gcloud 有登入中的帳號，輸入 `gcloud auth list`，帳號前面要有星號

## 5.2 路線 A｜懶人包：一行指令跑完

```bash
cd ~/ai-driven-martech-pipeline && git pull && bash structured/run.sh
```

`run.sh` 先把設計規格搬進答案表、從 `dim_creative` 拿掉四欄，接著挑六張樣本圖、印出最壞費用，輸入 yes 才會呼叫 Gemini，之後依序是 11 項檢查與六段報表，在估價那一步直接按 Enter 就會停下來，搬家已經完成但不會產生 Token 費用，搬家可以重複執行，第二次跑不會出錯。

## 5.3 路線 B｜逐步教學：理解每一個步驟

### 步驟 1：搬家與樣本

```bash
cd ~/ai-driven-martech-pipeline/structured
bq query --nouse_legacy_sql --format=pretty < move_design.sql
bq query --nouse_legacy_sql --format=pretty < sample.sql
```

第一個會印出答案表 24 列、`dim_creative` 剩下的設計欄位 0 欄，第二個印出六張樣本圖。

### 步驟 2：看圖

```bash
bq query --nouse_legacy_sql --format=pretty < extract.sql
```

五輪共 30 次呼叫，最後印出每一輪的成功次數與 Token 合計，這一步會產生約新台幣 0.8 元的費用。

### 步驟 3：檢查與報表

```bash
bq query --nouse_legacy_sql --format=pretty < check.sql
bq query --nouse_legacy_sql --format=pretty --max_rows=100 < report.sql
```

`check.sql` 是 10 項流程檢查，第 11 項由 `run.sh` 用 grep 補上，`report.sql` 六段分別是直接 `GROUP BY` 的結果、超出選項的次數、逐張對答案、各輪答對張數、兩次一不一樣、實際費用，只有第 3、4 段會讀答案表。

## 5.4 驗證成果

- `gt_creative_design` 24 列，`dim_creative` 沒有 `has_person`、`cta_position`、`dominant_color`、`text_density`
- `mm_structured` 30 列、五輪各 6 張、`status` 全部是空字串、五個欄位都有值、沒有值超出選項
- `run.sh` 的 11 項檢查全部通過，其中一項確認挑圖和看圖的 SQL 沒有讀答案表

## 5.5 用完後怎麼處理

```bash
bq rm -f -t martech_dw.mm_sample
bq rm -f -t martech_dw.mm_structured
```

`gt_creative_design` 是 Day 16、17、20 的答案表，留著，`dim_creative` 拿掉的四欄不要加回去。

---

# 6. 工程實務避坑指南

1. **型別對不代表值對**：`output_schema` 只保證 `dominant_color` 是字串，填 warm 還是「暖色」它管不到，選項要寫在題目裡，跑完再用 `report.sql` 第 2 段的 `NOT IN` 數一次有沒有超出選項的值，今天是 0，換一批圖不一定
2. **界線要寫進題目**：多和少、暖和冷的界線模型不知道，這次 30 次唯一的錯就出在沒給界線那一輪，界線要寫成模型看得懂的規則，例如「標題之外還有賣點文字或標籤算 high」
3. **enum 是保險不是答案**：`response_schema` 的 enum 照規格只讓值從清單裡出來，不保證挑對，今天 enum 那一輪和沒 enum 的答對率一樣，輸出被截斷時解析出來是空值，不是清單外的值，所以空值也要數
4. **兩種鎖法選一種**：`output_schema` 回來是欄位、`response_schema` 回來是 JSON 字串，取值的方式不同，今天沒有同時用，要用哪一種先決定，之後的 SQL 都照它寫
5. **輸出上限要留餘裕但不要太大**：JSON 被截斷會解析成空值，`check.sql` 要數有沒有撞到上限，上限也不要照抄 Day 14 的 1,024，最壞估價會跟著虛高
6. **搬家要先確認來源還在**：`DROP COLUMN` 之後資料就不在 `dim_creative` 裡了，要拿回來得從原樣載入的 `raw_creatives` 重抄，所以 `raw_creatives` 不動

---

# 7. 總結與明日預告

今天讓每一張圖變成一列資料，`AI.GENERATE` 帶著 `output_schema` 看圖，回來直接是五個欄位，六張圖五輪 30 次呼叫合計新台幣 0.78 元，唯一的錯出在只列選項沒給判斷標準的那一輪，主色 30 次全對、標題逐字全對、同一張圖問兩次答案完全相同，Day 14 自由描述不能分組的問題在這六張上已經看不到了，但六張抽查只能證明寫法可行，24 張的答對率要等 Day 16，正式的評測要等 Day 20。

回到篇名，AI 乖乖照格式交資料靠的不是一個參數，型別由 schema 鎖住，選項和判斷標準要寫進題目，跑完還要用 SQL 檢查值有沒有超出選項，三件事缺一個，資料就會在某一批圖上開始跑掉，另外今天也把設計規格搬進了答案資料集，四個設計欄位從今天起分析用的 SQL 拿不到，之後 Day 16 抽特徵、Day 17 比點擊率，對答案都只能在報表那一步發生。

**明日預告**：Day 16《讓 AI 一口氣看完所有廣告圖，整理出視覺特徵》，今天的寫法用在六張圖上，明天放大到全部 24 張，一次跑完、存成特徵表，再看 24 張的答對率和低解析度能不能省錢。
