-- Day 14：檢查看圖流程本身有沒有跑完整（ok 欄位：OK／DIFF）
-- 描述是 AI 自由寫的，每次不一定相同，所以這裡不檢查「描述得對不對」，只檢查次數、有沒有錯誤、有沒有記到 Token 用量、低解析度是不是真的比較省
-- run.sh 另外會補一項：看圖用的 SQL 沒有讀答案表

WITH
o AS (SELECT COUNT(*) AS n, COUNTIF(content_type = 'image/jpeg') AS jpeg FROM martech_dw.obj_creatives),
d AS (SELECT COUNT(*) AS n, COUNT(DISTINCT uri) AS uris FROM martech_dw.mm_demo),
m AS (
  SELECT COUNT(*) AS n,
    COUNT(DISTINCT FORMAT('%s|%s|%d', model, resolution, run_no)) AS rounds,
    COUNTIF(status != '') AS api_error,
    COUNTIF(description IS NULL OR CHAR_LENGTH(description) < 20) AS empty_desc,
    COUNTIF(prompt_tokens IS NULL) AS no_usage
  FROM martech_dw.mm_describe
),
per_round AS (
  SELECT COUNTIF(images != 3) AS bad_rounds
  FROM (SELECT model, resolution, run_no, COUNT(DISTINCT creative_id) AS images
        FROM martech_dw.mm_describe GROUP BY 1, 2, 3)
),
res AS (
  SELECT COUNT(*) AS pairs, COUNTIF(l.prompt_tokens < h.prompt_tokens) AS low_cheaper
  FROM martech_dw.mm_describe l
  JOIN martech_dw.mm_describe h
    ON h.creative_id = l.creative_id AND h.model = l.model AND h.run_no = 1 AND h.resolution = 'default'
  WHERE l.resolution = 'low'
)
SELECT '1 object table images' AS check_name, '24' AS expected, CAST(n AS STRING) AS actual, IF(n = 24, 'OK', 'DIFF') AS ok FROM o
UNION ALL SELECT '2 object table all jpeg', '24', CAST(jpeg AS STRING), IF(jpeg = 24, 'OK', 'DIFF') FROM o
UNION ALL SELECT '3 demo images', '3', CAST(uris AS STRING), IF(n = 3 AND uris = 3, 'OK', 'DIFF') FROM d
UNION ALL SELECT '4 describe rows', '12', CAST(n AS STRING), IF(n = 12, 'OK', 'DIFF') FROM m
UNION ALL SELECT '5 describe rounds', '4', CAST(rounds AS STRING), IF(rounds = 4, 'OK', 'DIFF') FROM m
UNION ALL SELECT '6 every round 3 images', '0', CAST(bad_rounds AS STRING), IF(bad_rounds = 0, 'OK', 'DIFF') FROM per_round
UNION ALL SELECT '7 api_error', '0', CAST(api_error AS STRING), IF(api_error = 0, 'OK', 'DIFF') FROM m
UNION ALL SELECT '8 empty description', '0', CAST(empty_desc AS STRING), IF(empty_desc = 0, 'OK', 'DIFF') FROM m
UNION ALL SELECT '9 missing token usage', '0', CAST(no_usage AS STRING), IF(no_usage = 0, 'OK', 'DIFF') FROM m
UNION ALL SELECT '10 low resolution cheaper', '3', CAST(low_cheaper AS STRING), IF(pairs = 3 AND low_cheaper = 3, 'OK', 'DIFF') FROM res;
