# drafts：靈感卡關時，讓 Gemini 根據成效幫你打下一版素材草稿（Day 18）

Day 17 算出了哪些設計特徵讓點擊率變高（人物、右下按鈕、暖色），Day 18 把這張倍數表連同原圖交給 Gemini，替新客受眾裡點擊率最低的三張圖打下一版素材草稿，再用同一份題目「有沒有加品牌規則」兩版對照，看規則擋掉了什麼。

## 檔案

| 檔案 | 做什麼 | 費用 |
| --- | --- | --- |
| `facts.sql` | 商品事實 `ref_product_facts`（照抄 live-demo/products.json）與不能寫進廣告的詞 `ref_claim_terms`（功效、醫療、絕對用語，Day 23 沿用） | 查詢 |
| `generate.sql` | 3 張圖 × 2 版題目（free／rules）× 各 2 次，AI.GENERATE 的 response_schema 規定草稿欄位、enum 鎖住選項，記進 `mm_drafts_log` 與共用的 `ops_llm_usage` | Gemini |
| `mart.sql` | 整理成 `mart_creative_drafts`，算好照成效改了沒、引用的倍數對不對、冒出哪些不能寫的詞 | 查詢 |
| `check.sql` | 12 項流程檢查（`run.sh` 再補 2 項，共 14 項） | 查詢 |
| `report.sql` | 八段：對象、草稿一覽、照成效改了沒、引用的倍數、不能寫的詞、預期效果原文、費用、看完草稿才找到的詞 | 查詢 |
| `run.sh` | 一行跑完，呼叫 Gemini 前先印出最壞情況的費用 | — |
| `veo.sh` | 延伸段：把一份草稿的畫面描述交給 Veo 3.1 Lite，渲染一支 4 秒短片 | Veo |

## 兩版題目

兩版都給同樣的商品事實、這張圖的現況（Day 16 AI 讀出來的特徵）與 Day 17 的倍數表，也都有「寫出最有說服力的文案，可以多強調機能」這句。rules 版只在最後多四條規則：

1. 只寫商品資料裡有的事實，不寫功效、醫療與絕對用語
2. 引用的倍數照表格抄
3. 轉換率區間包含 1 的特徵，不能說會讓轉換率、成交或銷售增加
4. 標題 14 字、副標 20 字以內

## 為什麼用 response_schema 不用 output_schema

第一次試跑用 output_schema（只鎖型別），free 版 6 份都合格，rules 版 6 份只有 3 份合格：一份寫到 4,081 個 Token 被截斷，兩份把推理過程寫進了 text_density 欄位。改用 response_schema 的 enum 把選項鎖住之後兩版重跑，第一次的紀錄留在 `mm_drafts_log`（method 是空的那幾筆），費用照算。

## 前置

1. 先 `git pull`
2. 已完成 Day 14（`obj_creatives`）、Day 16（`mart_creative_features`）、Day 17（`mart_creative_perf`、`mart_creative_lift`）
3. `gcloud auth list` 有星號的帳號、`gcloud config get-value project` 印出專案 ID

## 執行

```bash
cd ~/ai-driven-martech-pipeline && git pull && bash drafts/run.sh
bash drafts/veo.sh   # 延伸段，另外確認費用
```

## 費用

- 打草稿：12 次 gemini-3.6-flash，最壞情況約新台幣 7.3 元（輸入以 2,600、輸出含思考以 4,096 Token 計），跑過的組合不重跑
- 影片：Veo 3.1 Lite 一支 4 秒、720p、不含音軌，官方定價頁沒有列 Lite，用 Veo 3 Fast 每秒 US$ 0.10 估最壞約新台幣 12.8 元，同一份草稿有影片就不再呼叫

## 實測結果（2026-10-01）

- 第一次用 output_schema：free 6 份合格，rules 6 份只有 3 份合格（1 份寫到 4,081 個 Token 被截斷，2 份把推理過程寫進 text_density），12 次新台幣 1.82 元
- 第二次用 response_schema 的 enum：12 份全部合格，沒有被截斷，每次輸入約 2,200 到 2,400、輸出約 270 到 360 個 Token，新台幣 1.23 元，第二次執行呼叫 0 次，14 項檢查全部通過
- 12 份草稿都加了人物、都把按鈕移到右下，引用的都是人物的點擊率倍數 1.28，改成暖色 free 6/6、rules 4/6
- 38 個詞的詞庫兩版都抓到 0 個，看完草稿才找到的誇大用語（極致、強效、黃金、日本級）free 6 份有 5 份、rules 0 份，預期效果寫 1.28 倍的 free 5 份、rules 2 份
- Veo 3.1 Lite：rules 版 cr-meta-evg-p2 第 1 份草稿，1280 × 720、24 fps、4 秒、無音軌，約 0.9 MB，官方定價頁沒有列 Lite，以第三方每秒 US$ 0.03 估約新台幣 4 元
