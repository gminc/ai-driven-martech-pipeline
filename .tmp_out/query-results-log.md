# Day 15 實測紀錄（2026-09-28 23:2x–23:3x 台北，Cloud Shell ~/wt-prep 分支 prep/day15 c8cde3d，`bash structured/run.sh 2>&1 | tee ~/day15_run.log`）

完整輸出 ~/day15_run.log（377 行）在 Cloud Shell，之後上傳 Drive Day15 資料夾

## move_design.sql

- gt_creative_design 24 列、missing_headline 0、dim_creative 剩下的設計欄位 0（ALTER TABLE DROP COLUMN IF EXISTS 四欄成功）

## sample.sql（六張）

| pick | creative_id | channel | ad_group | product | size |
| --- | --- | --- | --- | --- | --- |
| 1 | cr-line-trn-p1 | line | line-trn-prospecting | sock-towel-training | 127,206 |
| 2 | cr-line-trn-p2 | line | line-trn-prospecting | sock-crew-daily | 133,158 |
| 3 | cr-meta-evg-r2 | meta | meta-evg-retargeting | towel-face-cotton | 148,073 |
| 4 | cr-meta-trn-p1 | meta | meta-trn-prospecting | sock-towel-training | 122,853 |
| 5 | cr-meta-aut-r2 | meta | meta-aut-retargeting | towel-face-cotton | 99,491 |
| 6 | cr-meta-trn-r1 | meta | meta-trn-retargeting | sock-towel-training | 164,684 |

## 費用估價（run.sh 印出）

30 次（flash-lite 24、3.6-flash 6），每次輸入 1,600、輸出 256 → 最壞 US$ 0.0438 ≈ NT$ 1.40，Jimmy 事前同意後輸入 yes

## extract.sql 結果（30/30 成功，status 全空）

| 輪 | 鎖法 | 模型 | 張 | ok | 輸入 Token 合計 | 輸出 Token 合計 | 每次輸入 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | output_schema | 3.5-flash-lite | 6 | 6 | 7,938 | 345 | 1,323 |
| B1 | output_schema＋判斷標準 | 3.5-flash-lite | 6 | 6 | 8,910 | 345 | 1,485 |
| B2 | 同 B1 | 3.5-flash-lite | 6 | 6 | 8,910 | 345 | 1,485 |
| C | response_schema enum＋判斷標準 | 3.5-flash-lite | 6 | 6 | 9,324 | 345 | 1,554 |
| D | 同 C | 3.6-flash | 6 | 6 | 9,324 | 311 | 1,554 |

- 一張圖 1,104 Token（Day 14 實測）＋題目：A 的題目約 219、B 的題目約 381（判斷標準多 162）、response_schema 再多 69
- 每次輸出 56–59 個 Token（3.6-flash 36–59），max_output_tokens 256 沒有一次撞到

## 逐張結果（30 列）

| 輪 | creative_id | has_person | cta | color | density | headline | out |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | cr-line-trn-p1 | false | center | neutral | low | 重訓日的厚底毛巾襪 | 57 |
| A | cr-line-trn-p2 | true | none | cool | low | 天天穿的純棉短襪 | 56 |
| A | cr-meta-aut-r2 | true | bottom_right | cool | low | 每天洗臉的純棉毛巾 | 59 |
| A | cr-meta-evg-r2 | false | none | neutral | **low**（規格 high） | 每天洗臉的純棉毛巾 | 57 |
| A | cr-meta-trn-p1 | true | bottom_right | warm | high | 重訓日的厚底毛巾襪 | 59 |
| A | cr-meta-trn-r1 | false | center | warm | high | 重訓日的厚底毛巾襪 | 57 |
| B1 | 六張 | 全對 | 全對 | 全對 | 全對（r2 改答 high） | 全對 | 56–59 |
| B2 | 六張 | 全對，和 B1 五欄全部相同 | | | | | 56–59 |
| C | 六張 | 全對 | | | | | 56–59 |
| D | 六張 | 全對 | | | | | 36–59 |

## check.sql：11 項全部通過

1 design columns left in dim_creative 0、2 sample images 6、3 structured rows 30、4 rounds 5、5 every round 6 images 0 bad、6 api_error 0、7 missing field 0、8 off-option (enum rounds) 0、9 missing token usage 0、10 hit output cap 256 0、11 no answer table in extract SQL none

## report.sql

- 第 1 段：A 輪直接 GROUP BY dominant_color → cool 2、neutral 2、warm 2
- 第 2 段：五輪的 cta／color／density 超出選項都是 0（連只鎖型別的 A 也是 0）、missing_field 0、輸出 min 36 max 59
- 第 4 段（各欄答對張數，滿分 6）：A：person 6、cta 6、color 6、density 5、headline 6、四欄全對 5。B1、B2、C、D：全部 6
- 第 5 段：B1 對 B2 六張五欄全部相同
- 第 6 段實際費用（非 global 單價）：A 0.114、B1 0.124、B2 0.124、C 0.129、D 0.287 → 合計 US$ 0.02436 ≈ **NT$ 0.78**

## 觀察

- 30 次裡只有 1 個欄位錯：A 輪（沒有判斷標準）把 cr-meta-evg-r2 的文字多寡答成 low，這張圖有標題、兩行賣點、兩個圓形標籤，加上判斷標準（B）之後三輪都答 high
- Day 14 關鍵字判暖色錯 5/12 的問題，改成固定欄位後 30 次的主色全對，米白亞麻背景的 p1、r2 都答 neutral
- enum 在這 6 張上看不出差別：A 沒有 enum 也沒有填出選項外的值，enum 的價值是保證而不是這次觀察到的差異，文章要老實寫
- 標題 30 次逐字全對（含「重訓日的厚底毛巾襪」「每天洗臉的純棉毛巾」）
- response_schema 讓每次輸入多 69 個 Token（Day 09 的 schema 較大，多 150）
