-- Day 17：把 AI 讀出來的視覺特徵和點擊率、轉換率放在一起比
-- 特徵來自 Day 16 的 mart_creative_features（Gemini 看圖讀出來的），不是設計規格，規格在 martech_gt，這支 SQL 不讀
-- 只讀 martech_dw，run.sh 會用 grep 確認沒有出現 martech_gt、gt_、raw_（raw_creatives 還留著規格欄位）、gs:// 與 EXECUTE
-- 查詢在每月 1 TiB 免費額度內，不呼叫 Gemini，可以重複執行
--
-- 算法沿用 Day 06 synthesizer/bigquery/verify.sql 的 S4：
--   1. 排除 cr-meta-evg-p1（Day 09 找到的素材疲乏，點擊率每週往下掉，會拖低它所在那一組）
--   2. 在同通路、同受眾裡比較（再行銷受眾本來就比較會點，不分層會把受眾的差別算成設計的差別）
--   3. 點擊率：每張圖一個點擊率，組內取幾何平均相除，各組依 ny×nn÷(ny+nn) 加權合併
--   4. 轉換率（verify.sql 沒有這一段，今天新加）：每張圖的成交太少（秋日素材只上線 16 天），組內先把工作階段和成交合計再相除，
--      各組依成交數加權 1÷(1÷成交_有＋1÷成交_沒有)，成交少的組權重小，另外算出 95% 信賴區間，看這個樣本量分得出多大的差別
-- 8/27 的 purchase 事件整天沒送出（Day 09 找到的追蹤碼失效），那天開始的工作階段不算進轉換率

-- ① 每張圖一列：特徵、曝光、點擊、工作階段、成交
CREATE OR REPLACE TABLE martech_dw.mart_creative_perf
OPTIONS (description = 'Day 17 素材成效與 AI 視覺特徵，一列＝一張圖片素材（排除素材疲乏的 cr-meta-evg-p1）') AS
WITH
img AS (
  SELECT d.creative_id, d.channel, d.audience, d.utm_campaign,
    f.has_person                     AS f_person,
    f.cta_position = 'bottom_right'  AS f_cta,
    f.dominant_color = 'warm'        AS f_warm,
    f.text_density = 'high'          AS f_text
  FROM martech_dw.dim_creative d
  JOIN martech_dw.mart_creative_features f USING (creative_id)
  WHERE d.format = 'image'
    AND d.creative_id != 'cr-meta-evg-p1'
),
ad AS (
  SELECT creative_id, SUM(impressions) AS impressions, SUM(clicks) AS clicks
  FROM martech_dw.fct_ad_daily
  WHERE data_source = 'synthetic'
  GROUP BY creative_id
),
sess AS (
  SELECT user_pseudo_id, ga_session_id, ANY_VALUE(creative_id) AS creative_id
  FROM martech_dw.fct_events
  WHERE event_dt BETWEEN '2026-06-01' AND '2026-09-16'
    AND event_dt != '2026-08-27'
    AND data_source = 'synthetic'
    AND event_name = 'session_start'
    AND creative_id IS NOT NULL AND creative_id != ''
  GROUP BY 1, 2
),
buy AS (
  SELECT DISTINCT user_pseudo_id, ga_session_id
  FROM martech_dw.fct_events
  WHERE event_dt BETWEEN '2026-06-01' AND '2026-09-17'
    AND data_source = 'synthetic'
    AND event_name = 'purchase'
),
conv AS (
  SELECT s.creative_id, COUNT(*) AS sessions, COUNT(b.ga_session_id) AS converted
  FROM sess s
  LEFT JOIN buy b USING (user_pseudo_id, ga_session_id)
  GROUP BY s.creative_id
)
SELECT
  i.*,
  a.impressions, a.clicks,
  SAFE_DIVIDE(a.clicks, a.impressions) AS ctr,
  c.sessions, c.converted,
  SAFE_DIVIDE(c.converted, c.sessions) AS cvr
FROM img i
JOIN ad a USING (creative_id)
LEFT JOIN conv c USING (creative_id)
WHERE a.clicks > 0;   -- 點擊率要取對數，0 次點擊的圖會少一列，check.sql 第 2 項會抓到

-- ② 每個特徵 × 點擊率／轉換率一列：分層倍數，另附不分層的倍數對照
CREATE OR REPLACE TABLE martech_dw.mart_creative_lift
OPTIONS (description = 'Day 17 視覺特徵對點擊率、轉換率的倍數，同通路同受眾分層比較，一列＝一個特徵 × 一個指標') AS
WITH
long AS (
  SELECT channel, audience, 'person' AS attr, f_person AS flag, ctr, sessions, converted FROM martech_dw.mart_creative_perf
  UNION ALL SELECT channel, audience, 'cta',  f_cta,  ctr, sessions, converted FROM martech_dw.mart_creative_perf
  UNION ALL SELECT channel, audience, 'warm', f_warm, ctr, sessions, converted FROM martech_dw.mart_creative_perf
  UNION ALL SELECT channel, audience, 'text', f_text, ctr, sessions, converted FROM martech_dw.mart_creative_perf
),
strata AS (
  SELECT attr, channel, audience,
    COUNTIF(flag) AS ny, COUNTIF(NOT flag) AS nn,
    EXP(AVG(IF(flag, LN(ctr), NULL))) / EXP(AVG(IF(NOT flag, LN(ctr), NULL))) AS ctr_ratio,
    SUM(IF(flag, converted, 0)) AS cy, SUM(IF(NOT flag, converted, 0)) AS cn,
    SAFE_DIVIDE(SUM(IF(flag, converted, 0)), SUM(IF(flag, sessions, 0)))
      / NULLIF(SAFE_DIVIDE(SUM(IF(NOT flag, converted, 0)), SUM(IF(NOT flag, sessions, 0))), 0) AS cvr_ratio
  FROM long
  GROUP BY 1, 2, 3
  HAVING COUNTIF(flag) > 0 AND COUNTIF(NOT flag) > 0
),
naive AS (
  SELECT attr,
    EXP(AVG(IF(flag, LN(ctr), NULL))) / EXP(AVG(IF(NOT flag, LN(ctr), NULL))) AS ctr_naive,
    SAFE_DIVIDE(SUM(IF(flag, converted, 0)), SUM(IF(flag, sessions, 0)))
      / NULLIF(SAFE_DIVIDE(SUM(IF(NOT flag, converted, 0)), SUM(IF(NOT flag, sessions, 0))), 0) AS cvr_naive,
    COUNTIF(flag) AS images_yes, COUNTIF(NOT flag) AS images_no,
    SUM(IF(flag, converted, 0)) AS converted_yes, SUM(IF(NOT flag, converted, 0)) AS converted_no
  FROM long
  GROUP BY attr
),
pooled AS (
  SELECT attr,
    COUNT(*) AS strata_used,
    EXP(SUM(LN(ctr_ratio) * ny * nn / (ny + nn)) / SUM(ny * nn / (ny + nn))) AS ctr_est,
    -- 轉換率：某一組有一邊成交數是 0 時倍數沒有意義，那一組不進合併（check.sql 會數有幾組被跳過）
    EXP(SUM(IF(cy > 0 AND cn > 0, LN(cvr_ratio) / (1 / cy + 1 / cn), NULL))
        / SUM(IF(cy > 0 AND cn > 0, 1 / (1 / cy + 1 / cn), NULL))) AS cvr_est,
    1 / SQRT(SUM(IF(cy > 0 AND cn > 0, 1 / (1 / cy + 1 / cn), NULL))) AS cvr_log_se,
    COUNTIF(NOT (cy > 0 AND cn > 0)) AS cvr_strata_skipped
  FROM strata
  GROUP BY attr
)
SELECT p.attr, metric,
  IF(metric = 'ctr', p.ctr_est, p.cvr_est)   AS stratified,
  IF(metric = 'ctr', n.ctr_naive, n.cvr_naive) AS naive,
  p.strata_used,
  IF(metric = 'cvr', p.cvr_strata_skipped, 0) AS strata_skipped,
  IF(metric = 'cvr', p.cvr_est * EXP(-1.96 * p.cvr_log_se), NULL) AS ci95_low,
  IF(metric = 'cvr', p.cvr_est * EXP(1.96 * p.cvr_log_se), NULL)  AS ci95_high,
  n.images_yes, n.images_no,
  IF(metric = 'cvr', n.converted_yes, NULL) AS converted_yes,
  IF(metric = 'cvr', n.converted_no, NULL)  AS converted_no
FROM pooled p
JOIN naive n USING (attr)
CROSS JOIN UNNEST(['ctr', 'cvr']) AS metric;

SELECT metric, attr, ROUND(stratified, 3) AS stratified, ROUND(naive, 3) AS naive,
  ROUND(ci95_low, 2) AS ci95_low, ROUND(ci95_high, 2) AS ci95_high, strata_used, images_yes, images_no
FROM martech_dw.mart_creative_lift
ORDER BY metric, attr;
