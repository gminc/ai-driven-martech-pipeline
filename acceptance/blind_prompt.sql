-- Day 13 盲測題目：把整季的廣告與訂單週報寫成一段文字，交給 Gemini 自己找異常
-- 和 Day 09 的差別：Day 09 先用 SQL 挑出四筆異常、再給六個候選原因讓模型選；
-- 這裡不挑、不給候選，只給每個廣告群組、每個素材、全站對帳、各商品件數的每週數字
-- 只讀 martech_dw 的事實表，不讀答案表 martech_gt；三列同一份題目（run_no 1–3），每個模型各問三次
-- 週次以週一日期標示，第一週與最後一週不滿七天

CREATE OR REPLACE TABLE martech_dw.blind_prompt
OPTIONS(description = 'Day 13 AI 盲測題目：整季週報，一列＝一次呼叫（run_no 1–3，內容相同）') AS
WITH
ad AS (
  SELECT date, ad_group_id, creative_id, channel, utm_campaign, impressions, clicks,
    CAST(cost AS FLOAT64) AS cost, DATE_TRUNC(date, WEEK(MONDAY)) AS wk
  FROM martech_dw.fct_ad_daily
  WHERE date BETWEEN '2026-06-01' AND '2026-09-30'
),
-- ── 一、廣告群組 × 週：點擊/點擊率/每次點擊花費/花費 ──
ag AS (
  SELECT ad_group_id, ANY_VALUE(channel) AS channel, ANY_VALUE(utm_campaign) AS campaign, wk,
    SUM(impressions) AS imp, SUM(clicks) AS clk, SUM(cost) AS cost
  FROM ad
  GROUP BY ad_group_id, wk
),
ag_lines AS (
  SELECT
    ad_group_id, MIN(wk) AS first_wk,
    FORMAT('%s（%s、%s、%s）：%s', ad_group_id,
      CASE channel WHEN 'meta' THEN 'Meta' WHEN 'line' THEN 'LINE' WHEN 'google_cpc' THEN 'Google 搜尋' ELSE channel END,
      CASE campaign WHEN 'evergreen' THEN '常態' WHEN 'training-socks' THEN '重訓襪專案' WHEN 'autumn-cotton' THEN '秋日棉織專案' ELSE campaign END,
      CASE WHEN ad_group_id LIKE '%prospecting' THEN '開發新客'
           WHEN ad_group_id LIKE '%retargeting' THEN '再行銷'
           WHEN ad_group_id LIKE '%search' THEN '搜尋' ELSE '' END,
      STRING_AGG(
        FORMAT('%d/%d %d/%.2f/%.1f/%d', EXTRACT(MONTH FROM wk), EXTRACT(DAY FROM wk),
          clk, IFNULL(100 * SAFE_DIVIDE(clk, imp), 0), IFNULL(SAFE_DIVIDE(cost, clk), 0), CAST(ROUND(cost) AS INT64)),
        '；' ORDER BY wk)) AS line
  FROM ag
  GROUP BY ad_group_id, channel, campaign
),
-- ── 二、素材 × 週：點擊率 ──
cr AS (
  SELECT creative_id, ANY_VALUE(ad_group_id) AS ad_group_id, wk,
    SUM(impressions) AS imp, SUM(clicks) AS clk, MIN(date) AS first_date
  FROM ad
  GROUP BY creative_id, wk
),
cr_lines AS (
  SELECT
    creative_id, ANY_VALUE(ad_group_id) AS ad_group_id, MIN(first_date) AS launch,
    FORMAT('%s（%s，上線 %d/%d）：%s', creative_id, ANY_VALUE(ad_group_id),
      EXTRACT(MONTH FROM MIN(first_date)), EXTRACT(DAY FROM MIN(first_date)),
      STRING_AGG(
        FORMAT('%d/%d %.2f', EXTRACT(MONTH FROM wk), EXTRACT(DAY FROM wk), IFNULL(100 * SAFE_DIVIDE(clk, imp), 0)),
        '、' ORDER BY wk)) AS line
  FROM cr
  GROUP BY creative_id
),
-- ── 三、全站 × 週：網站追蹤到的購買事件 vs 後台訂單 ──
ev AS (
  SELECT DATE_TRUNC(event_dt, WEEK(MONDAY)) AS wk, COUNT(*) AS tracked
  FROM martech_dw.fct_events
  WHERE event_dt BETWEEN '2026-06-01' AND '2026-09-30'
    AND event_name = 'purchase' AND data_source = 'synthetic'
  GROUP BY wk
),
od AS (
  SELECT DATE_TRUNC(order_date, WEEK(MONDAY)) AS wk, COUNT(*) AS orders, SUM(revenue) AS rev
  FROM martech_dw.fct_orders
  WHERE order_date BETWEEN '2026-06-01' AND '2026-09-30' AND data_source = 'synthetic'
  GROUP BY wk
),
wk_all AS (
  SELECT DISTINCT wk FROM ad
  UNION DISTINCT SELECT wk FROM od
),
site_lines AS (
  SELECT STRING_AGG(
    FORMAT('%d/%d %d/%d/%d', EXTRACT(MONTH FROM w.wk), EXTRACT(DAY FROM w.wk),
      IFNULL(e.tracked, 0), IFNULL(o.orders, 0), IFNULL(o.rev, 0)),
    '；' ORDER BY w.wk) AS line
  FROM wk_all w
  LEFT JOIN ev e USING (wk)
  LEFT JOIN od o USING (wk)
),
-- ── 四、商品 × 週：售出件數 ──
pr AS (
  SELECT DATE_TRUNC(order_date, WEEK(MONDAY)) AS wk,
    SUM(IF(item_id = 'sock-crew-daily', quantity, 0)) AS crew,
    SUM(IF(item_id = 'sock-towel-training', quantity, 0)) AS trn,
    SUM(IF(item_id = 'towel-face-cotton', quantity, 0)) AS face,
    SUM(IF(item_id = 'towel-bath-cotton', quantity, 0)) AS bath,
    SUM(IF(item_id = 'set-starter', quantity, 0)) AS starter,
    SUM(quantity) AS total
  FROM martech_dw.fct_orders
  WHERE order_date BETWEEN '2026-06-01' AND '2026-09-30' AND data_source = 'synthetic'
  GROUP BY wk
),
pr_lines AS (
  SELECT STRING_AGG(
    FORMAT('%d/%d 日常中筒襪 %d、厚底毛巾訓練襪 %d、純棉洗臉毛巾 %d、純棉大浴巾 %d、日常入門組合 %d（合計 %d）',
      EXTRACT(MONTH FROM wk), EXTRACT(DAY FROM wk), crew, trn, face, bath, starter, total),
    '；' ORDER BY wk) AS line
  FROM pr
),
-- ── 組成題目 ──
report AS (
  SELECT CONCAT(
    '你是電商公司「織日常」的廣告分析師，下面是 2026 年 6 月中到 9 月 16 日的廣告與訂單週報，數字都已經算好，金額都是新台幣，',
    '週次以週一日期標示，第一週與最後一週不滿七天\n',
    '活動：常態（evergreen，全期間）、重訓襪專案（training-socks，7/15 起，主打厚底毛巾訓練襪與日常中筒襪）、',
    '秋日棉織專案（autumn-cotton，9/1 到 9/16，主打純棉洗臉毛巾、日常中筒襪、日常入門組合）\n',
    '廣告群組命名：通路-活動-受眾（evg 常態、trn 重訓襪專案、aut 秋日棉織專案；prospecting 開發新客、retargeting 再行銷、search 搜尋）\n\n',
    '一、廣告群組每週成效（每週：週一日期 點擊次數/點擊率%/平均每次點擊花費元/花費元）\n',
    (SELECT STRING_AGG(line, '\n' ORDER BY first_wk, ad_group_id) FROM ag_lines), '\n\n',
    '二、素材每週點擊率%（每週：週一日期 點擊率）\n',
    (SELECT STRING_AGG(line, '\n' ORDER BY ad_group_id, creative_id) FROM cr_lines), '\n\n',
    '三、每週網站追蹤到的購買事件數/後台成立訂單數/後台訂單營收元\n',
    (SELECT line FROM site_lines), '\n\n',
    '四、每週各商品售出件數\n',
    (SELECT line FROM pr_lines), '\n\n',
    '請找出這份週報裡值得注意的異常或變化，每一項寫出對象（廣告群組、素材、全站或商品）、期間、觀察到的數字變化、',
    '最可能的原因，以及建議接下來去確認的事，只列你有把握的，數量不限，只能根據上面的數字推論，不要假設沒給你的資訊，用繁體中文回答'
  ) AS prompt
)
SELECT run_no, prompt
FROM UNNEST([1, 2, 3]) AS run_no
CROSS JOIN report;

SELECT run_no, CHAR_LENGTH(prompt) AS chars, ARRAY_LENGTH(SPLIT(prompt, '\n')) AS lines
FROM martech_dw.blind_prompt
ORDER BY run_no;
