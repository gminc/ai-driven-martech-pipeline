-- Day 10 第四步：三種做法的對照表
-- 單價（gemini-3.5-flash-lite，global，美元／百萬 Token，2026-09 官方價目表）：
--   一般輸入 0.30、快取命中的輸入 0.03（打一折）、輸出 2.50
--   明確快取另收：建立那次的輸入照原價 0.30，儲存費每百萬 Token 每小時 1.00
-- 新台幣以 1 美元約 32 元換算

-- ① 每一輪的 Token 與費用
WITH r AS (
  SELECT
    scenario, round,
    COUNT(*) AS calls,
    COUNTIF(cached_tokens > 0) AS hit_calls,
    SUM(prompt_tokens) AS input_tokens,
    SUM(cached_tokens) AS cached_tokens,
    SUM(output_tokens) AS output_tokens
  FROM martech_dw.cache_runs
  WHERE scenario IN ('old', 'new', 'explicit')
  GROUP BY scenario, round
)
SELECT
  scenario, round, calls, hit_calls,
  input_tokens, cached_tokens,
  ROUND(SAFE_DIVIDE(cached_tokens, input_tokens) * 100, 1) AS cached_pct,
  output_tokens,
  ROUND(((input_tokens - cached_tokens) * 0.30 + cached_tokens * 0.03 + output_tokens * 2.50) / 1e6 * 32, 3) AS twd
FROM r
ORDER BY CASE scenario WHEN 'old' THEN 1 WHEN 'new' THEN 2 ELSE 3 END, round;

-- ② 三種做法合計（explicit 另外要加建立一次與儲存費，run.sh 會依快取實際存活時間另外印出）
SELECT
  scenario,
  COUNT(*) AS calls,
  COUNTIF(cached_tokens > 0) AS hit_calls,
  SUM(prompt_tokens) AS input_tokens,
  SUM(cached_tokens) AS cached_tokens,
  SUM(output_tokens) AS output_tokens,
  ROUND(((SUM(prompt_tokens) - SUM(cached_tokens)) * 0.30 + SUM(cached_tokens) * 0.03) / 1e6 * 32, 3) AS input_twd,
  ROUND(SUM(output_tokens) * 2.50 / 1e6 * 32, 3) AS output_twd
FROM martech_dw.cache_runs
WHERE scenario IN ('old', 'new', 'explicit')
GROUP BY scenario
ORDER BY CASE scenario WHEN 'old' THEN 1 WHEN 'new' THEN 2 ELSE 3 END;

-- ③ 明確快取要問幾次才划得來
-- 每題省下固定內容 × (0.30 − 0.03)，要付出固定內容 × (0.30 建立 ＋ 1.00 × 存活小時)
-- 兩邊的「固定內容 Token 數」會互相抵銷，所以兩平次數只跟存活時間有關（固定內容仍需 ≥ 4,096 Token 才建得起來）
SELECT
  ttl_minutes,
  ROUND((0.30 + 1.00 * ttl_minutes / 60) / 0.27, 1) AS breakeven_calls
FROM UNNEST([10, 30, 60, 360, 1440]) AS ttl_minutes
ORDER BY ttl_minutes;
