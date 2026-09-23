-- Day 09：檢查 AI 的回答能不能直接拿來用
-- status 是空字串只代表 API 呼叫成功，不代表回答完整，所以另外檢查 JSON 解析、原因是否在清單內、信心分數範圍
-- ok 欄位：OK／DIFF

WITH s AS (SELECT COUNT(*) AS n FROM martech_dw.diag_summary),
d AS (
  SELECT model,
    COUNT(*) AS n,
    COUNTIF(status != '') AS api_error,
    COUNTIF(SAFE.PARSE_JSON(raw_result) IS NULL) AS bad_json,
    COUNTIF(cause IS NULL OR cause NOT IN ('競價變貴', '追蹤碼失效', '素材疲乏', '需求或季節變化', '其他', '資料不足')) AS bad_cause,
    COUNTIF(confidence IS NULL OR confidence < 0 OR confidence > 1) AS bad_confidence,
    COUNTIF(evidence IS NULL OR evidence = '') AS no_evidence,
    COUNTIF(SAFE_CAST(JSON_VALUE(statistics, '$.thoughts_token_count') AS INT64) > 0) AS used_thinking
  FROM martech_dw.mart_diagnosis
  GROUP BY model
)
SELECT 'summary_rows' AS check_name, '>0' AS expected, CAST(n AS STRING) AS actual, IF(n > 0, 'OK', 'DIFF') AS ok FROM s
UNION ALL SELECT 'models', '2', CAST((SELECT COUNT(*) FROM d) AS STRING), IF((SELECT COUNT(*) FROM d) = 2, 'OK', 'DIFF')
UNION ALL SELECT CONCAT(model, ' rows'), CAST(s.n AS STRING), CAST(d.n AS STRING), IF(d.n = s.n, 'OK', 'DIFF') FROM d, s
UNION ALL SELECT CONCAT(model, ' api_error'), '0', CAST(api_error AS STRING), IF(api_error = 0, 'OK', 'DIFF') FROM d
UNION ALL SELECT CONCAT(model, ' bad_json'), '0', CAST(bad_json AS STRING), IF(bad_json = 0, 'OK', 'DIFF') FROM d
UNION ALL SELECT CONCAT(model, ' bad_cause'), '0', CAST(bad_cause AS STRING), IF(bad_cause = 0, 'OK', 'DIFF') FROM d
UNION ALL SELECT CONCAT(model, ' bad_confidence'), '0', CAST(bad_confidence AS STRING), IF(bad_confidence = 0, 'OK', 'DIFF') FROM d
UNION ALL SELECT CONCAT(model, ' no_evidence'), '0', CAST(no_evidence AS STRING), IF(no_evidence = 0, 'OK', 'DIFF') FROM d
UNION ALL SELECT CONCAT(model, ' used_thinking'), '0', CAST(used_thinking AS STRING), IF(used_thinking = 0, 'OK', 'DIFF') FROM d
ORDER BY check_name;
