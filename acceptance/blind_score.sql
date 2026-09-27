-- Day 13：AI 盲測評分，把每一項發現對照 blind_criteria.sql 寫死的三組關鍵字
-- 一項發現同時命中某個訊號的三組關鍵字，那一次呼叫就算找到那個訊號
-- 讀 martech_dw.blind_findings（回答）與 martech_gt.blind_criteria（判準），只有這裡會把兩邊放在一起

CREATE OR REPLACE TABLE martech_gt.blind_scorecard
OPTIONS(description = 'Day 13 AI 盲測成績：一列＝模型 × 第幾次 × 訊號，found＝那次回答裡有一項發現同時命中三組關鍵字') AS
WITH
findings AS (
  SELECT model, run_no, finding_no,
    CONCAT(IFNULL(target, ''), '｜', IFNULL(period, ''), '｜', IFNULL(observation, ''), '｜', IFNULL(likely_cause, '')) AS txt
  FROM martech_dw.blind_findings
),
runs AS (
  SELECT DISTINCT model, run_no FROM martech_dw.blind_result
),
hit AS (
  SELECT c.signal_id, f.model, f.run_no, f.finding_no
  FROM martech_gt.blind_criteria c
  JOIN findings f
    ON REGEXP_CONTAINS(f.txt, c.must_1)
   AND REGEXP_CONTAINS(f.txt, c.must_2)
   AND REGEXP_CONTAINS(f.txt, c.must_3)
)
SELECT
  r.model, r.run_no, c.signal_id, c.rule,
  COUNT(h.finding_no) > 0 AS found,
  ARRAY_AGG(h.finding_no IGNORE NULLS ORDER BY h.finding_no) AS matched_findings,
  CURRENT_TIMESTAMP() AS scored_at
FROM runs r
CROSS JOIN martech_gt.blind_criteria c
LEFT JOIN hit h
  ON h.model = r.model AND h.run_no = r.run_no AND h.signal_id = c.signal_id
GROUP BY r.model, r.run_no, c.signal_id, c.rule;

SELECT model, signal_id, COUNTIF(found) AS runs_found, COUNT(*) AS runs
FROM martech_gt.blind_scorecard
GROUP BY model, signal_id
ORDER BY model, signal_id;
