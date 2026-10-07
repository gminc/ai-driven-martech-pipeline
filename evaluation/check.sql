-- Day 24：流程檢查，一列＝一項，ok 欄位是 OK 或 DIFF
-- 檢查的是「考試有沒有照設計考完、評分的順序對不對」，助理答得好不好、哪一種評分方式準在 report.sql 看
-- 查詢在每月 1 TiB 免費額度內

WITH
latest AS (
  SELECT * FROM martech_dw.eval_answers WHERE NOT STARTS_WITH(status, 'error')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY case_id, mode ORDER BY created_at DESC) = 1
),
calls AS (
  SELECT c.* FROM martech_dw.eval_calls_log c JOIN latest l USING (run_id, case_id, mode)
),
-- 同一個回答同一種評分方式看最新一列，而且評的要是現在這一份回答
scores AS (
  SELECT s.* FROM martech_dw.eval_scores s
  JOIN latest l ON l.case_id = s.case_id AND l.mode = s.mode AND l.run_id = s.answer_run_id
  WHERE s.status = ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY s.case_id, s.mode, s.grader ORDER BY s.created_at DESC) = 1
),
per_judge AS (
  SELECT j.grader, COUNT(s.score) AS n
  FROM (SELECT DISTINCT grader FROM martech_dw.eval_scores WHERE STARTS_WITH(grader, 'judge:')) j
  LEFT JOIN scores s USING (grader)
  GROUP BY 1
),
checks AS (
  SELECT '01 answered (tools/none)' AS check_name, '8/8' AS expected,
    CONCAT(CAST((SELECT COUNT(*) FROM latest WHERE mode = 'tools') AS STRING), '/',
           CAST((SELECT COUNT(*) FROM latest WHERE mode = 'none') AS STRING)) AS actual
  UNION ALL SELECT '02 tool calls without tools', '0',
    CAST((SELECT IFNULL(SUM(tool_calls), 0) FROM latest WHERE mode = 'none') AS STRING)
  UNION ALL SELECT '03 model calls <= 4 and input tokens <= 4000', 'true',
    CAST((SELECT IFNULL(MAX(model_calls), 0) <= 4 FROM latest)
     AND (SELECT IFNULL(MAX(prompt_tokens), 0) <= 4000 FROM calls) AS STRING)
  UNION ALL SELECT '04 rule scores', '16',
    CAST((SELECT COUNT(*) FROM scores WHERE grader = 'rule') AS STRING)
  UNION ALL SELECT '05 human scores', '16',
    CAST((SELECT COUNT(*) FROM scores WHERE grader = 'human') AS STRING)
  -- 人的分數要在第一次呼叫評分模型之前寫進表（更強的證據是 human_labels.csv 的 commit 時間，run.sh 會擋沒有 commit 的情況）
  UNION ALL SELECT '06 human scored before any judge call', 'true',
    CAST(IFNULL((SELECT MAX(created_at) FROM scores WHERE grader = 'human')
              < (SELECT MIN(created_at) FROM martech_dw.eval_scores WHERE STARTS_WITH(grader, 'judge:')), FALSE) AS STRING)
  UNION ALL SELECT '07 judges that scored all 16 (>= 1)', 'true',
    CAST((SELECT COUNT(*) FROM per_judge WHERE n = 16) >= 1 AS STRING)
  -- 只要呼叫過（回了 200）的評分模型都要評滿 16 個，報表的一致率只算評滿的
  UNION ALL SELECT '08 judges with partial scores', '0',
    CAST((SELECT COUNT(*) FROM per_judge WHERE n != 16) AS STRING)
  UNION ALL SELECT '09 scores outside 0-2', '0',
    CAST((SELECT COUNT(*) FROM scores WHERE score IS NULL OR score NOT IN (0, 1, 2)) AS STRING)
  -- 題目、標準答案、規則、評分標準的指紋：回答和每一種評分都要是同一版
  UNION ALL SELECT '10 spec versions across answers and scores', '1',
    CAST((SELECT COUNT(DISTINCT spec) FROM (SELECT spec FROM latest UNION ALL SELECT spec FROM scores)) AS STRING)
  -- 模型有回應但沒有給出文字的題次（步數用完、輸出被截斷），不是 0 的話報表要分開看
  UNION ALL SELECT '11 answers without text', '0',
    CAST((SELECT COUNT(*) FROM latest WHERE status != '' OR IFNULL(answer, '') = '') AS STRING)
  UNION ALL SELECT '12 usage rows = successful call rows', 'true',
    CAST((SELECT COUNT(*) FROM martech_dw.ops_llm_usage WHERE job = 'evaluation/eval_run.py')
       = (SELECT COUNT(*) FROM martech_dw.eval_calls_log WHERE status = '') AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
