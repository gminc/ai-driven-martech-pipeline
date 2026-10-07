-- Day 24：報表，六段
-- 分數都是 0、1、2，同一個回答同一種評分方式看最新一列，評分模型只列評滿 16 個回答的
-- 查詢在每月 1 TiB 免費額度內

-- 準備：這一份回答對應的分數
CREATE TEMP TABLE s AS
WITH latest AS (
  SELECT * FROM martech_dw.eval_answers WHERE NOT STARTS_WITH(status, 'error')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY case_id, mode ORDER BY created_at DESC) = 1
),
scores AS (
  SELECT x.case_id, x.mode, x.grader, x.score, x.explanation, l.signal, l.kind
  FROM martech_dw.eval_scores x
  JOIN latest l ON l.case_id = x.case_id AND l.mode = x.mode AND l.run_id = x.answer_run_id
  WHERE x.status = ''
  QUALIFY ROW_NUMBER() OVER (PARTITION BY x.case_id, x.mode, x.grader ORDER BY x.created_at DESC) = 1
)
SELECT * FROM scores
WHERE NOT STARTS_WITH(grader, 'judge:')
   OR grader IN (SELECT grader FROM scores GROUP BY 1 HAVING COUNT(*) = 16);

-- 1. 助理的成績：依題型、有沒有工具分開看，三種評分方式各給幾分（滿分 2）
--    answerable 工具查得到，unanswerable 工具查不到（說查不到才對），none_planted 沒有藏（說沒有才對）
SELECT kind, mode, grader,
  COUNT(*) AS answers,
  ROUND(AVG(score), 2) AS avg_score,
  COUNTIF(score = 2) AS full_marks,
  COUNTIF(score = 1) AS partial,
  COUNTIF(score = 0) AS wrong
FROM s
GROUP BY 1, 2, 3
ORDER BY 1, 2 DESC, 3;

-- 2. 每一題的分數攤開看：人、規則、每個評分模型
SELECT case_id, signal, kind, mode,
  MAX(IF(grader = 'human', score, NULL)) AS human,
  MAX(IF(grader = 'rule', score, NULL)) AS rule_based,
  STRING_AGG(IF(STARTS_WITH(grader, 'judge:'), CONCAT(SUBSTR(grader, 7), '=', CAST(score AS STRING)), NULL), ', ' ORDER BY grader) AS judges
FROM s
GROUP BY 1, 2, 3, 4
ORDER BY 1, 4 DESC;

-- 3. 評分的方式準不準：把人的分數當基準，規則和每個評分模型各有幾題給的分數一模一樣
--    exact＝分數相同，pass_fail＝「滿分或不是滿分」判斷相同，higher／lower＝比人給得高／低的題數
--    只有 16 個回答，一位評分的人，這張表適合拿來找出不一樣的是哪幾題，不適合拿來說哪一種方式的準確率是多少
SELECT x.grader,
  COUNT(*) AS answers,
  COUNTIF(x.score = h.score) AS exact,
  COUNTIF((x.score = 2) = (h.score = 2)) AS pass_fail,
  COUNTIF(x.score > h.score) AS higher,
  COUNTIF(x.score < h.score) AS lower,
  COUNTIF(h.score = 1) AS human_gave_1,
  COUNTIF(h.score = 1 AND x.score = 1) AS agreed_on_1
FROM s x
JOIN s h ON h.case_id = x.case_id AND h.mode = x.mode AND h.grader = 'human'
WHERE x.grader != 'human'
GROUP BY 1
ORDER BY exact DESC, 1;

-- 4. 和人給的分數不一樣的每一筆，附上當時的理由
SELECT x.case_id, x.mode, x.grader, h.score AS human, x.score AS given,
  SUBSTR(x.explanation, 1, 200) AS explanation, SUBSTR(h.explanation, 1, 120) AS human_note
FROM s x
JOIN s h ON h.case_id = x.case_id AND h.mode = x.mode AND h.grader = 'human'
WHERE x.grader != 'human' AND x.score != h.score
ORDER BY 1, 2 DESC, 3;

-- 5. 問題、標準答案與回答原文
SELECT case_id, mode, question, reference, answer, tools_called, status
FROM martech_dw.eval_answers WHERE NOT STARTS_WITH(status, 'error')
QUALIFY ROW_NUMBER() OVER (PARTITION BY case_id, mode ORDER BY created_at DESC) = 1
ORDER BY case_id, mode DESC;

-- 6. 費用：問問題用實際的 Token 算（gemini-3.6-flash global 端點每百萬 Token 輸入 0.75、輸出 3.75 美元，匯率 32）
--    評分模型那一段 evaluation service 不回報 Token，這裡列的是估價上限：輸入是送出前自己數的再多估三成，
--    輸出當成每次都寫滿上限，單價抄 global 端點的（指定地區可能略高），實際金額以帳單為準
SELECT 'answers' AS part, model AS model, COUNT(*) AS calls,
  SUM(prompt_tokens) AS prompt_tokens, SUM(IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0)) AS output_tokens,
  ROUND(SUM(prompt_tokens * 0.75 + (IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0)) * 3.75) / 1e6 * 32, 3) AS cost_twd,
  'measured' AS basis
FROM martech_dw.eval_calls_log WHERE status = ''
GROUP BY 2
UNION ALL
SELECT 'judge', SUBSTR(grader, 7), COUNT(*), SUM(prompt_tokens), SUM(output_tokens_cap),
  ROUND(SUM(prompt_tokens * 1.3 * IF(grader LIKE '%flash-lite', 0.30, 0.75)
          + output_tokens_cap * IF(grader LIKE '%flash-lite', 2.50, 3.75)) / 1e6 * 32, 3),
  'upper bound'
FROM martech_dw.eval_scores WHERE STARTS_WITH(grader, 'judge:')
GROUP BY 2
ORDER BY 1, 2;
