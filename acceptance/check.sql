-- Day 13：檢查驗收流程本身有沒有跑完整（ok 欄位：OK／DIFF）
-- 這裡不檢查「找到幾題」，成績是成績、檢查是檢查；盲測是 AI 回答，每次不一定相同，所以只檢查次數、格式、有沒有用到思考
-- run.sh 另外會補兩項：題目與呼叫的 SQL 沒有讀答案表、判準的 commit 時間早於評分時間

WITH
c AS (SELECT COUNT(*) AS n FROM martech_gt.acceptance_criteria),
s AS (
  SELECT COUNT(*) AS n,
    COUNTIF(verdict = '待考') AS pending,
    COUNTIF(verdict = '沒有資料') AS no_data,
    COUNTIF(verdict IN ('找到', '沒找到')) AS judged
  FROM martech_gt.acceptance_scorecard
),
bc AS (SELECT COUNT(*) AS n FROM martech_gt.blind_criteria),
bp AS (SELECT COUNT(*) AS n, COUNT(DISTINCT prompt) AS distinct_prompts FROM martech_dw.blind_prompt),
br AS (
  SELECT COUNT(*) AS n,
    COUNT(DISTINCT model) AS models,
    COUNTIF(status != '') AS api_error,
    COUNTIF(SAFE.PARSE_JSON(raw_result) IS NULL) AS bad_json,
    COUNTIF(SAFE_CAST(JSON_VALUE(statistics, '$.thoughts_token_count') AS INT64) > 0) AS used_thinking
  FROM martech_dw.blind_result
),
bf AS (SELECT COUNT(DISTINCT CONCAT(model, '#', CAST(run_no AS STRING))) AS runs_with_findings FROM martech_dw.blind_findings),
bs AS (SELECT COUNT(*) AS n FROM martech_gt.blind_scorecard)
SELECT '1 criteria rows' AS check_name, '12' AS expected, CAST(n AS STRING) AS actual, IF(n = 12, 'OK', 'DIFF') AS ok FROM c
UNION ALL SELECT '2 scorecard rows', '12', CAST(n AS STRING), IF(n = 12, 'OK', 'DIFF') FROM s
UNION ALL SELECT '3 scorecard pending (S4)', '1', CAST(pending AS STRING), IF(pending = 1, 'OK', 'DIFF') FROM s
UNION ALL SELECT '4 scorecard no data', '0', CAST(no_data AS STRING), IF(no_data = 0, 'OK', 'DIFF') FROM s
UNION ALL SELECT '5 scorecard judged', '11', CAST(judged AS STRING), IF(judged = 11, 'OK', 'DIFF') FROM s
UNION ALL SELECT '6 blind criteria rows', '4', CAST(n AS STRING), IF(n = 4, 'OK', 'DIFF') FROM bc
UNION ALL SELECT '7 blind prompt rows', '3', CAST(n AS STRING), IF(n = 3, 'OK', 'DIFF') FROM bp
UNION ALL SELECT '8 blind prompt identical', '1', CAST(distinct_prompts AS STRING), IF(distinct_prompts = 1, 'OK', 'DIFF') FROM bp
UNION ALL SELECT '9 blind result rows', '6', CAST(n AS STRING), IF(n = 6, 'OK', 'DIFF') FROM br
UNION ALL SELECT '10 blind models', '2', CAST(models AS STRING), IF(models = 2, 'OK', 'DIFF') FROM br
UNION ALL SELECT '11 blind api_error', '0', CAST(api_error AS STRING), IF(api_error = 0, 'OK', 'DIFF') FROM br
UNION ALL SELECT '12 blind bad_json', '0', CAST(bad_json AS STRING), IF(bad_json = 0, 'OK', 'DIFF') FROM br
UNION ALL SELECT '13 blind used_thinking', '0', CAST(used_thinking AS STRING), IF(used_thinking = 0, 'OK', 'DIFF') FROM br
UNION ALL SELECT '14 runs with findings', '6', CAST(runs_with_findings AS STRING), IF(runs_with_findings = 6, 'OK', 'DIFF') FROM bf
UNION ALL SELECT '15 blind scorecard rows', '24', CAST(n AS STRING), IF(n = 24, 'OK', 'DIFF') FROM bs
ORDER BY SAFE_CAST(SPLIT(check_name, ' ')[OFFSET(0)] AS INT64);
