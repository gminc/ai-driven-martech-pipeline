-- Day 10 第一步：把每題都一樣的內容（角色、候選原因、規則、背景資料）組成一段固定文字
-- 快取只認「開頭完全相同」的部分，所以這段要放在題目最前面，而且每次都要一字不差
-- 背景資料全部用倉儲裡的真資料，不灌水：商品、專案檔期、素材清單、各廣告群組每週成效
-- 這一步只跑 SQL，不呼叫 Gemini，不產生 Token 費用

CREATE OR REPLACE TABLE martech_dw.cache_context
OPTIONS (description = 'Day 10 固定內容：角色、候選原因、規則與背景資料，一列')
AS
WITH prod AS (
  SELECT STRING_AGG(FORMAT('%s|%s|%t',
           item_id,
           IFNULL(CAST(unit_price AS STRING), '-'),
           first_seen_date), '\n' ORDER BY item_id) AS t
  FROM martech_dw.dim_product
),
promo AS (
  SELECT STRING_AGG(FORMAT('%s：%t 到 %t', p, mn, mx), '\n' ORDER BY p) AS t
  FROM (
    SELECT p, MIN(date) AS mn, MAX(date) AS mx
    FROM martech_dw.dim_date, UNNEST(promotion_ids) AS p
    GROUP BY p
  )
),
cr AS (
  SELECT STRING_AGG(FORMAT('%s|%s|%s|%s|%s|%s|%s|%s',
           creative_id, channel, ad_group_id,
           IFNULL(audience, '-'), IFNULL(format, '-'),
           IFNULL(CAST(start_date AS STRING), '-'), IFNULL(CAST(end_date AS STRING), '-'),
           IFNULL(product_focus, '-')), '\n' ORDER BY creative_id) AS t
  FROM martech_dw.dim_creative
),
wk AS (
  SELECT
    ad_group_id,
    DATE_TRUNC(date, WEEK(MONDAY)) AS w,
    COUNT(DISTINCT date) AS d,
    SUM(clicks) AS clk,
    SUM(impressions) AS imp,
    CAST(SUM(cost) AS FLOAT64) AS cost
  FROM martech_dw.fct_ad_daily
  WHERE date BETWEEN '2026-06-22' AND '2026-09-20'
  GROUP BY 1, 2
),
wkt AS (
  -- FORMAT 只要有一個參數是 NULL 整行就會變 NULL，被 STRING_AGG 略過，所以點擊或曝光為 0 的週改印「-」
  SELECT STRING_AGG(FORMAT('%s|%t|%d|%d|%s|%s',
           ad_group_id, w, d, IFNULL(clk, 0),
           IFNULL(FORMAT('%.2f', SAFE_DIVIDE(clk, imp) * 100), '-'),
           IFNULL(FORMAT('%.1f', SAFE_DIVIDE(cost, clk)), '-')), '\n' ORDER BY ad_group_id, w) AS t
  FROM wk
)
SELECT
  CONCAT(
    '你是電商公司的廣告分析師，接下來會陸續收到系統自動找出的成效異常，每次一筆，請根據這份背景資料和那一筆的數字，判斷最可能的原因\n\n',
    '候選原因只能從這六個選一個：競價變貴、追蹤碼失效、素材疲乏、需求或季節變化、其他、資料不足\n',
    '規則：\n',
    '1. 只能根據背景資料和那一筆的數字推論，不要假設沒給你的資訊\n',
    '2. 數字不夠下結論時選「資料不足」，不要硬猜\n',
    '3. evidence 用一到兩句繁體中文，引用你判斷時用到的數字\n',
    '4. next_check 寫一件行銷人員接下來應該去確認的事\n\n',
    '【背景一】商品清單（商品|定價元|第一次出現）\n', prod.t, '\n\n',
    '【背景二】專案檔期\n', promo.t, '\n\n',
    '【背景三】素材清單（素材|通路|廣告群組|受眾|格式|上線日|下檔日|主打商品，上線日與下檔日是「-」代表常態素材）\n', cr.t, '\n\n',
    '【背景四】各廣告群組每週成效（廣告群組|週一日期|有資料天數|點擊|點擊率%|每次點擊花費元）\n', wkt.t
  ) AS context,
  CURRENT_TIMESTAMP() AS built_at
FROM prod, promo, cr, wkt;

-- 每題會變的部分：只有那一筆異常的數字（沿用 Day 09 的 diag_prompt.facts）
-- 固定內容要放前面還是後面、要不要走快取，交給 experiment.sql 決定
CREATE OR REPLACE VIEW martech_dw.cache_prompt AS
SELECT
  anomaly_id, level, entity, period_start,
  CONCAT('【這次要判斷的異常】\n', facts) AS question
FROM martech_dw.diag_prompt;

-- 實測紀錄表：一列＝一題 × 一輪，experiment.sql 會寫進來
CREATE TABLE IF NOT EXISTS martech_dw.cache_runs (
  run_at        TIMESTAMP OPTIONS(description = '這一輪送出的時間'),
  scenario      STRING    OPTIONS(description = 'old＝數字在前、new＝固定內容在前、explicit＝明確快取、verify_*＝開工驗證'),
  round         INT64     OPTIONS(description = '第幾輪'),
  anomaly_id    STRING,
  cause         STRING    OPTIONS(description = 'Gemini 選的原因'),
  prompt_tokens INT64     OPTIONS(description = '輸入 Token（含快取命中的部分）'),
  cached_tokens INT64     OPTIONS(description = '快取命中的輸入 Token，沒命中為 0'),
  output_tokens INT64     OPTIONS(description = '輸出 Token'),
  status        STRING,
  usage         JSON      OPTIONS(description = '完整 usage_metadata')
)
OPTIONS(description = 'Day 10 三種做法的實測紀錄，一列＝一題 × 一輪');
