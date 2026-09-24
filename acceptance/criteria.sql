-- Day 13：考卷的判準，先寫死、先 commit，再跑 scorecard.sql 看成績
-- 每一題「怎樣算找到」都寫成數字門檻，看完成績不能回頭改；要改就另開一版並在 README 記錄原因
-- 答案（gt_signals）與判準都放在 martech_gt，分析用的 martech_dw 裡沒有答案
-- S4（圖片屬性對 CTR 的影響）Day 17 才分析，這次標「Day 17 再考」

CREATE OR REPLACE TABLE martech_gt.acceptance_criteria
OPTIONS(description = 'Day 13 驗收判準：每個訊號的檢查項目與門檻，跑成績前寫死') AS
SELECT * FROM UNNEST([
  STRUCT(
    'S1' AS signal_id, 'S1a' AS check_id, 'Day 09' AS found_by_day, 'SQL' AS method,
    'meta-trn-prospecting 8/12 起的點擊成本是之前的幾倍（答案 2.0）' AS rule,
    1.6 AS lower_bound, 2.4 AS upper_bound),
  ('S1', 'S1b', 'Day 09', 'AI',
    'flash-lite 對 meta-trn-prospecting 的判讀是「競價變貴」（1＝是）', 1.0, 1.0),
  ('S2', 'S2a', 'Day 09', 'SQL',
    '8/27 追蹤到的 purchase 事件數÷後台訂單數（答案 0：整天沒送出）', 0.0, 0.1),
  ('S2', 'S2b', 'Day 09', 'AI',
    'flash-lite 對全站 8/27 的判讀是「追蹤碼失效」（1＝是）', 1.0, 1.0),
  ('S3', 'S3a', 'Day 09', 'SQL',
    'cr-meta-evg-p1 每週點擊率的變化倍數，依週次做對數線性迴歸（答案 0.92）', 0.88, 0.96),
  ('S3', 'S3b', 'Day 09', 'AI',
    'flash-lite 對 cr-meta-evg-p1 的判讀是「素材疲乏」（1＝是）', 1.0, 1.0),
  ('S5', 'S5a', 'Day 11', 'ML',
    '觀察 ≥ 30 天的顧客分群後，四種類型各自有多少比例落在「自己是多數」的群，取四種裡最低的一個', 0.6, 1.0),
  ('S5', 'S5b', 'Day 12', 'ML',
    '驗證集裡高頻買襪客的平均預測 30 天回購營收÷其他三種類型的平均預測（高頻買襪客應該最高）', 1.5, 99.0),
  ('S6', 'S6a', 'Day 08', 'SQL',
    '首購且回溯完整的訂單，meta 第一次接觸功勞÷最後接觸功勞（答案：meta 集中在路徑開頭）', 1.2, 99.0),
  ('S6', 'S6b', 'Day 08', 'SQL',
    '同上，google/cpc 最後接觸功勞÷第一次接觸功勞（答案：google 搜尋集中在最後一步）', 1.2, 99.0),
  ('S7', 'S7a', 'Day 09', 'SQL',
    '專案期間專案商品件數占比－專案前三週占比（百分點，答案：占比上升）', 5.0, 99.0),
  ('S4', 'S4a', 'Day 17', '—',
    '圖片屬性對點擊率的乘數，Day 17 再考', NULL, NULL)
]);

SELECT signal_id, check_id, found_by_day, method, lower_bound, upper_bound
FROM martech_gt.acceptance_criteria
ORDER BY check_id;
