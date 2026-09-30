-- Day 17：S4 補考評分，lift.sql 算出來的倍數對照 criteria_v2 寫死的門檻
-- 這是今天第一支讀 martech_gt 的 SQL，只讀判準表，不讀規格，run.sh 在 lift.sql 跑完之後才執行它
-- 查詢在每月 1 TiB 免費額度內

CREATE OR REPLACE TABLE martech_gt.acceptance_scorecard_s4
OPTIONS(description = 'Day 17 S4 補考成績，一列＝一個檢查項目，判準來自 acceptance_criteria_v2') AS
WITH
lift AS (SELECT attr, metric, stratified FROM martech_dw.mart_creative_lift),
measured AS (
  SELECT 'S4a' AS check_id, stratified AS actual FROM lift WHERE metric = 'ctr' AND attr = 'person'
  UNION ALL SELECT 'S4b', stratified FROM lift WHERE metric = 'ctr' AND attr = 'cta'
  UNION ALL SELECT 'S4c', stratified FROM lift WHERE metric = 'ctr' AND attr = 'warm'
  UNION ALL SELECT 'S4d', stratified FROM lift WHERE metric = 'ctr' AND attr = 'text'
  -- 三個特徵裡離 1 最遠的那一個，保留原本的倍數（不取絕對值），報表才看得出是偏高還是偏低
  UNION ALL SELECT 'S4e', ARRAY_AGG(stratified IGNORE NULLS ORDER BY ABS(LN(stratified)) DESC LIMIT 1)[SAFE_OFFSET(0)]
    FROM lift WHERE metric = 'cvr' AND attr IN ('person', 'cta', 'warm')
)
SELECT
  c.signal_id, c.check_id, c.found_by_day, c.method, c.rule,
  c.lower_bound, c.upper_bound,
  ROUND(m.actual, 3) AS actual,
  CASE
    WHEN m.actual IS NULL THEN '沒有資料'
    WHEN m.actual BETWEEN c.lower_bound AND c.upper_bound THEN '找到'
    ELSE '沒找到'
  END AS verdict,
  CURRENT_TIMESTAMP() AS scored_at
FROM martech_gt.acceptance_criteria_v2 c
LEFT JOIN measured m USING (check_id)
WHERE c.signal_id = 'S4';

-- 每次評分都記一筆，只加不刪，連同當下判準表的指紋（依 check_id 排序後整張串起來取 FARM_FINGERPRINT）
-- check.sql 第 16 項要求所有評分紀錄的指紋都一樣、而且等於現在的判準，看完結果再改判準一定抓得到，也不受 git rebase 改 commit 時間影響
CREATE TABLE IF NOT EXISTS martech_gt.acceptance_s4_runs (
  scored_at   TIMESTAMP NOT NULL,
  criteria_fp INT64     NOT NULL
)
OPTIONS(description = 'Day 17 S4 補考每次評分的時間與判準指紋，只加不刪');
INSERT INTO martech_gt.acceptance_s4_runs (scored_at, criteria_fp)
SELECT
  (SELECT MIN(scored_at) FROM martech_gt.acceptance_scorecard_s4),
  (SELECT FARM_FINGERPRINT(STRING_AGG(TO_JSON_STRING(c), '|' ORDER BY c.check_id)) FROM martech_gt.acceptance_criteria_v2 c);

SELECT check_id, lower_bound, upper_bound, actual, verdict
FROM martech_gt.acceptance_scorecard_s4
ORDER BY check_id;
