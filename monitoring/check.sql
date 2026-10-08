-- Day 25：檢查，一列＝一項，ok 欄位是 OK 或 DIFF
-- 重點是「view 有沒有把用量表原封不動帶出來」，以及「有沒有呼叫對不到單價」
-- 查詢在每月 1 TiB 免費額度內

WITH
raw AS (SELECT * FROM martech_dw.ops_llm_usage),
calls AS (SELECT * FROM martech_dw.v_llm_usage_calls),
daily AS (SELECT * FROM martech_dw.v_llm_usage_daily),
checks AS (
  SELECT '01 usage table has rows' AS check_name, 'true' AS expected,
    CAST((SELECT COUNT(*) > 0 FROM raw) AS STRING) AS actual
  -- 單價表同一個模型、端點的期間重疊的話，JOIN 會把一次呼叫變成兩列、費用算兩次
  UNION ALL SELECT '02 calls view rows = usage rows', 'true',
    CAST((SELECT COUNT(*) FROM calls) = (SELECT COUNT(*) FROM raw) AS STRING)
  UNION ALL SELECT '03 daily calls = usage rows', 'true',
    CAST((SELECT IFNULL(SUM(calls), 0) FROM daily) = (SELECT COUNT(*) FROM raw) AS STRING)
  UNION ALL SELECT '04 daily input tokens = usage input tokens', 'true',
    CAST((SELECT IFNULL(SUM(prompt_tokens), 0) FROM daily) = (SELECT IFNULL(SUM(prompt_tokens), 0) FROM raw) AS STRING)
  UNION ALL SELECT '05 daily output tokens = usage output tokens', 'true',
    CAST((SELECT IFNULL(SUM(output_tokens), 0) FROM daily) = (SELECT IFNULL(SUM(output_tokens), 0) FROM raw) AS STRING)
  -- 同一個模型、同一種端點的任兩列期間有交集（包含起始日相同、整列重複）
  UNION ALL SELECT '06 price periods overlapping', '0',
    CAST((SELECT COUNT(*) FROM
            (SELECT *, ROW_NUMBER() OVER (ORDER BY model, endpoint_type, valid_from, valid_to) AS rn FROM martech_dw.ref_llm_price) a
          JOIN
            (SELECT *, ROW_NUMBER() OVER (ORDER BY model, endpoint_type, valid_from, valid_to) AS rn FROM martech_dw.ref_llm_price) b
          ON a.model = b.model AND a.endpoint_type = b.endpoint_type AND a.rn < b.rn
         AND a.valid_from <= b.valid_to AND b.valid_from <= a.valid_to) AS STRING)
  -- 有 Token 卻對不到單價的呼叫：費用會是 NULL，儀表板的合計會少算，要補單價
  -- 不是用 Token 計費的（Veo）不在這一項，看第 11 項
  UNION ALL SELECT '07 calls with tokens but no price', '0',
    CAST((SELECT COUNT(*) FROM calls WHERE NOT priced AND prompt_tokens + output_tokens > 0) AS STRING)
  UNION ALL SELECT '08 endpoint_type outside global / non-global', '0',
    CAST((SELECT COUNT(*) FROM raw WHERE endpoint_type NOT IN ('global', 'non-global') OR endpoint_type IS NULL) AS STRING)
  UNION ALL SELECT '09 negative or null cost on priced calls', '0',
    CAST((SELECT COUNT(*) FROM calls WHERE priced AND (cost_twd IS NULL OR cost_twd < 0)) AS STRING)
  UNION ALL SELECT '10 rows without a day label', '0',
    CAST((SELECT COUNT(*) FROM raw WHERE day IS NULL OR day = '') AS STRING)
  UNION ALL SELECT '11 daily unpriced calls = calls without a price', 'true',
    CAST((SELECT IFNULL(SUM(unpriced_calls), 0) FROM daily) = (SELECT COUNT(*) FROM calls WHERE NOT priced) AS STRING)
  UNION ALL SELECT '12 input cost + output cost = cost', 'true',
    CAST((SELECT ABS(IFNULL(SUM(cost_in_twd), 0) + IFNULL(SUM(cost_out_twd), 0) - IFNULL(SUM(cost_twd), 0)) < 0.0001 FROM daily) AS STRING)
)
SELECT check_name, expected, actual, IF(expected = actual, 'OK', 'DIFF') AS ok
FROM checks
ORDER BY check_name;
