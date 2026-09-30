-- Day 17：報表，六段
-- ① 每張圖的特徵與成效  ② 分層與不分層的倍數  ③ 點擊率逐組拆開  ④ 每次拿掉一張圖，倍數會變多少
-- ⑤ S4 補考成績  ⑥ 揭曉：AI 讀的特徵換成設計規格、不加雜訊的期望值、合成器設定的答案，四個放在一起
-- ①–④ 只讀 martech_dw，⑤ 讀判準與成績，⑥ 讀規格與答案，查詢在每月 1 TiB 免費額度內

-- ① 每張圖的特徵與成效（23 張，已排除素材疲乏的 cr-meta-evg-p1）
SELECT channel, audience, creative_id,
  f_person, f_cta, f_warm, f_text,
  impressions, clicks, ROUND(100 * ctr, 2) AS ctr_pct,
  sessions, converted, ROUND(100 * cvr, 2) AS cvr_pct
FROM martech_dw.mart_creative_perf
ORDER BY channel, audience, ctr DESC;

-- ② 分層與不分層的倍數
SELECT metric, attr, ROUND(stratified, 3) AS stratified, ROUND(naive, 3) AS naive,
  ROUND(ci95_low, 2) AS ci95_low, ROUND(ci95_high, 2) AS ci95_high, strata_used, strata_skipped, images_yes, images_no, converted_yes, converted_no
FROM martech_dw.mart_creative_lift
ORDER BY metric, attr;

-- ③ 點擊率逐組拆開：每一組（通路 × 受眾）裡有、沒有這個特徵各幾張，幾何平均相除是多少
WITH long AS (
  SELECT channel, audience, 'person' AS attr, f_person AS flag, ctr FROM martech_dw.mart_creative_perf
  UNION ALL SELECT channel, audience, 'cta',  f_cta,  ctr FROM martech_dw.mart_creative_perf
  UNION ALL SELECT channel, audience, 'warm', f_warm, ctr FROM martech_dw.mart_creative_perf
  UNION ALL SELECT channel, audience, 'text', f_text, ctr FROM martech_dw.mart_creative_perf
)
SELECT attr, channel, audience, COUNTIF(flag) AS ny, COUNTIF(NOT flag) AS nn,
  ROUND(100 * EXP(AVG(IF(flag, LN(ctr), NULL))), 2) AS ctr_yes_pct,
  ROUND(100 * EXP(AVG(IF(NOT flag, LN(ctr), NULL))), 2) AS ctr_no_pct,
  ROUND(EXP(AVG(IF(flag, LN(ctr), NULL))) / EXP(AVG(IF(NOT flag, LN(ctr), NULL))), 3) AS ratio
FROM long
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ④ 每次拿掉一張圖重算分層倍數（點擊率），看結果是不是被某一張圖撐起來的
WITH
drops AS (SELECT creative_id AS dropped FROM martech_dw.mart_creative_perf),
long AS (
  SELECT d.dropped, p.channel, p.audience, attr,
    CASE attr WHEN 'person' THEN p.f_person WHEN 'cta' THEN p.f_cta WHEN 'warm' THEN p.f_warm ELSE p.f_text END AS flag,
    p.ctr
  FROM drops d
  JOIN martech_dw.mart_creative_perf p ON p.creative_id != d.dropped
  CROSS JOIN UNNEST(['person', 'cta', 'warm', 'text']) AS attr
),
strata AS (
  SELECT dropped, attr, channel, audience, COUNTIF(flag) AS ny, COUNTIF(NOT flag) AS nn,
    EXP(AVG(IF(flag, LN(ctr), NULL))) / EXP(AVG(IF(NOT flag, LN(ctr), NULL))) AS r
  FROM long
  GROUP BY 1, 2, 3, 4
  HAVING COUNTIF(flag) > 0 AND COUNTIF(NOT flag) > 0
),
est AS (
  SELECT dropped, attr, EXP(SUM(LN(r) * ny * nn / (ny + nn)) / SUM(ny * nn / (ny + nn))) AS est
  FROM strata
  GROUP BY 1, 2
)
SELECT attr,
  ROUND(MIN(est), 3) AS min_est,
  ROUND(MAX(est), 3) AS max_est,
  ARRAY_AGG(dropped ORDER BY est LIMIT 1)[OFFSET(0)] AS drop_for_min,
  ARRAY_AGG(dropped ORDER BY est DESC LIMIT 1)[OFFSET(0)] AS drop_for_max
FROM est
GROUP BY attr
ORDER BY attr;

-- ⑤ S4 補考成績（判準在 lift.sql 之前 commit）
SELECT check_id, rule, lower_bound, upper_bound, actual, verdict, scored_at
FROM martech_gt.acceptance_scorecard_s4
ORDER BY check_id;

-- ⑥ 揭曉：同一套算法把 AI 讀的特徵換成設計規格，再和合成器設定的答案放在一起
--    no_noise：每張圖的點擊率只照答案的乘數算（不加任何雜訊），再套同一套分層算法，看算法本身會算出多少
--    gt_signals.spec 載入時是 JSON 字串還是物件不確定，兩種都讀得到
WITH
answer AS (
  SELECT
    SAFE_CAST(JSON_VALUE(s, '$.has_person') AS FLOAT64) AS m_person,
    SAFE_CAST(JSON_VALUE(s, '$.cta_bottom_right') AS FLOAT64) AS m_cta,
    SAFE_CAST(JSON_VALUE(s, '$.dominant_color_warm') AS FLOAT64) AS m_warm
  FROM (
    SELECT COALESCE(SAFE.PARSE_JSON(JSON_VALUE(spec)), spec) AS s
    FROM martech_gt.gt_signals
    WHERE signal_id = 'S4'
  )
),
spec AS (
  SELECT p.creative_id, p.channel, p.audience, p.ctr,
    g.has_person AS f_person,
    g.cta_position = 'bottom_right' AS f_cta,
    g.dominant_color = 'warm' AS f_warm,
    g.text_density = 'high' AS f_text,
    IF(g.has_person, a.m_person, 1) * IF(g.cta_position = 'bottom_right', a.m_cta, 1)
      * IF(g.dominant_color = 'warm', a.m_warm, 1) AS ideal
  FROM martech_dw.mart_creative_perf p
  JOIN martech_gt.gt_creative_design g USING (creative_id)
  CROSS JOIN answer a
),
long AS (
  SELECT channel, audience, 'person' AS attr, f_person AS flag, ctr, ideal FROM spec
  UNION ALL SELECT channel, audience, 'cta',  f_cta,  ctr, ideal FROM spec
  UNION ALL SELECT channel, audience, 'warm', f_warm, ctr, ideal FROM spec
  UNION ALL SELECT channel, audience, 'text', f_text, ctr, ideal FROM spec
),
strata AS (
  SELECT attr, channel, audience, COUNTIF(flag) AS ny, COUNTIF(NOT flag) AS nn,
    EXP(AVG(IF(flag, LN(ctr), NULL))) / EXP(AVG(IF(NOT flag, LN(ctr), NULL))) AS r,
    EXP(AVG(IF(flag, LN(ideal), NULL))) / EXP(AVG(IF(NOT flag, LN(ideal), NULL))) AS r_ideal
  FROM long
  GROUP BY 1, 2, 3
  HAVING COUNTIF(flag) > 0 AND COUNTIF(NOT flag) > 0
),
spec_est AS (
  SELECT attr,
    EXP(SUM(LN(r) * ny * nn / (ny + nn)) / SUM(ny * nn / (ny + nn))) AS spec_est,
    EXP(SUM(LN(r_ideal) * ny * nn / (ny + nn)) / SUM(ny * nn / (ny + nn))) AS no_noise
  FROM strata GROUP BY attr
),
diff AS (
  SELECT STRING_AGG(p.creative_id, ', ') AS ids, COUNT(*) AS n
  FROM martech_dw.mart_creative_perf p
  JOIN martech_gt.gt_creative_design g USING (creative_id)
  WHERE p.f_person != g.has_person
     OR p.f_cta != (g.cta_position = 'bottom_right')
     OR p.f_warm != (g.dominant_color = 'warm')
     OR p.f_text != (g.text_density = 'high')
)
SELECT l.attr,
  ROUND(l.stratified, 3) AS ai_features,
  ROUND(s.spec_est, 3) AS spec_features,
  ROUND(s.no_noise, 3) AS no_noise,
  CASE l.attr WHEN 'person' THEN a.m_person WHEN 'cta' THEN a.m_cta WHEN 'warm' THEN a.m_warm ELSE 1.0 END AS answer,
  d.n AS flag_differs_images, d.ids AS flag_differs_ids
FROM martech_dw.mart_creative_lift l
JOIN spec_est s USING (attr)
CROSS JOIN answer a
CROSS JOIN diff d
WHERE l.metric = 'ctr'
ORDER BY l.attr;
