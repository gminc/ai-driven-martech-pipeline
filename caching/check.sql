-- Day 10：檢查實測結果
-- new（隱含式）命中幾題不列入檢查：Google 不保證會命中，每次跑的結果可能不同
-- meta-evg-prospecting 只有 3 天資料，不列入答案檢查（Day 09 flash-lite 判過「資料不足」）
-- ok 欄位：OK／DIFF

WITH r AS (
  SELECT * FROM martech_dw.cache_runs WHERE scenario IN ('old', 'new', 'explicit')
),
k AS (
  SELECT 'meta-trn-prospecting' AS entity, '競價變貴' AS answer
  UNION ALL SELECT 'all_site', '追蹤碼失效'
  UNION ALL SELECT 'cr-meta-evg-p1', '素材疲乏'
),
ctx AS (
  SELECT AI.COUNT_TOKENS(context, endpoint => 'gemini-3.5-flash-lite').result AS tokens FROM martech_dw.cache_context
),
s AS (
  SELECT scenario,
    COUNT(*) AS n,
    COUNTIF(status != '') AS api_error,
    COUNTIF(cause IS NULL OR cause NOT IN ('競價變貴', '追蹤碼失效', '素材疲乏', '需求或季節變化', '其他', '資料不足')) AS bad_cause,
    COUNTIF(cached_tokens > 0) AS hits,
    MIN(cached_tokens) AS min_cached
  FROM r GROUP BY scenario
),
w AS (
  SELECT r.scenario, COUNTIF(r.cause != k.answer) AS wrong
  FROM r JOIN k ON SPLIT(r.anomaly_id, '|')[OFFSET(1)] = k.entity
  GROUP BY r.scenario
)
SELECT '0 context_tokens >= 4096' AS check_name, '>=4096' AS expected, CAST(tokens AS STRING) AS actual, IF(tokens >= 4096, 'OK', 'DIFF') AS ok FROM ctx
UNION ALL SELECT CONCAT('1 ', scenario, ' rows'), '12', CAST(n AS STRING), IF(n = 12, 'OK', 'DIFF') FROM s
UNION ALL SELECT CONCAT('2 ', scenario, ' api_error'), '0', CAST(api_error AS STRING), IF(api_error = 0, 'OK', 'DIFF') FROM s
UNION ALL SELECT CONCAT('3 ', scenario, ' bad_cause'), '0', CAST(bad_cause AS STRING), IF(bad_cause = 0, 'OK', 'DIFF') FROM s
UNION ALL SELECT CONCAT('4 ', scenario, ' wrong_answer'), '0', CAST(wrong AS STRING), IF(wrong = 0, 'OK', 'DIFF') FROM w
UNION ALL SELECT '5 old hits', '0', CAST(hits AS STRING), IF(hits = 0, 'OK', 'DIFF') FROM s WHERE scenario = 'old'
UNION ALL SELECT '6 explicit hits', '12', CAST(hits AS STRING), IF(hits = 12, 'OK', 'DIFF') FROM s WHERE scenario = 'explicit'
UNION ALL SELECT '7 explicit min_cached >= 4096', '>=4096', CAST(min_cached AS STRING), IF(min_cached >= 4096, 'OK', 'DIFF') FROM s WHERE scenario = 'explicit'
ORDER BY check_name;
