-- Day 08：多觸點歸因，把 fct_events 的造訪串成每筆訂單的購買路徑，用三種規則分配功勞
-- 產出 martech_dw.mart_attribution，粒度：一筆訂單 × 路徑上的一個觸點
-- 每一列帶六個功勞欄位（三種規則 × direct 算或不算），同一筆訂單的每個功勞欄位加總都是 1
-- 用法：bash attribution/run.sh（會接著跑 check.sql 與 report.sql）

DECLARE lookback_days INT64 DEFAULT 30;       -- 回溯窗口：只看下單前 30 天內的造訪
DECLARE half_life_days FLOAT64 DEFAULT 7;     -- 時間衰減半衰期：距離下單每多 7 天，權重減半
DECLARE lookback_us INT64 DEFAULT lookback_days * 86400 * 1000000;
DECLARE half_life_us FLOAT64 DEFAULT half_life_days * 86400 * 1000000;

-- 事件表要求分區條件，先用訂單期間推出要讀的日期範圍，前面多讀一個回溯窗口
DECLARE first_order DATE DEFAULT (SELECT MIN(order_date) FROM martech_dw.fct_orders);
DECLARE last_order  DATE DEFAULT (SELECT MAX(order_date) FROM martech_dw.fct_orders);
-- 合成資料的第一天，比這天早的造訪不存在，回溯窗口會被截斷
DECLARE data_start  DATE DEFAULT (
  SELECT MIN(event_dt) FROM martech_dw.fct_events
  WHERE event_dt >= DATE '2000-01-01' AND data_source = 'synthetic');

CREATE OR REPLACE TABLE martech_dw.mart_attribution
PARTITION BY order_date
CLUSTER BY channel
OPTIONS(description = 'Day 08 多觸點歸因，粒度：訂單 × 觸點，六個功勞欄位各自對每筆訂單加總為 1')
AS
WITH orders AS (
  -- 轉換用訂單表，不用 purchase 事件：8/27 的 purchase 事件整天沒送出，訂單照常成立
  SELECT
    transaction_id, order_date, order_ts, customer_id, user_pseudo_id, revenue, item_id,
    UNIX_MICROS(order_ts) AS order_us,
    LAG(UNIX_MICROS(order_ts)) OVER w AS prev_order_us,
    ROW_NUMBER() OVER w AS order_seq
  FROM martech_dw.fct_orders
  WHERE data_source = 'synthetic'
  WINDOW w AS (PARTITION BY user_pseudo_id ORDER BY order_ts, transaction_id)
),
sessions AS (
  -- 一次造訪就是一個觸點，來源取 session_start 上的 UTM
  SELECT
    user_pseudo_id,
    event_timestamp AS touch_us,
    CONCAT(utm_source, ' / ', utm_medium) AS channel,
    utm_campaign,
    utm_source = '(direct)' AS is_direct
  FROM martech_dw.fct_events
  WHERE event_dt BETWEEN DATE_SUB(first_order, INTERVAL lookback_days + 1 DAY) AND last_order
    AND event_name = 'session_start'
    AND data_source = 'synthetic'
),
touches AS (
  SELECT o.*, s.touch_us, s.channel, s.utm_campaign, s.is_direct
  FROM orders o
  JOIN sessions s
    ON s.user_pseudo_id = o.user_pseudo_id
   AND s.touch_us <= o.order_us                          -- 下單之後的造訪不算
   AND s.touch_us > o.order_us - lookback_us             -- 回溯窗口
   AND s.touch_us > IFNULL(o.prev_order_us, -1)          -- 回購：路徑從上一筆訂單之後重新起算
),
seq AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY touch_us, channel, utm_campaign) AS touch_seq,
    COUNT(*) OVER (PARTITION BY transaction_id) AS path_len,
    COUNTIF(NOT is_direct) OVER (PARTITION BY transaction_id) AS nd_len,
    COUNTIF(NOT is_direct) OVER (PARTITION BY transaction_id ORDER BY touch_us, channel, utm_campaign
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS nd_seq,
    POW(0.5, (order_us - touch_us) / half_life_us) AS decay_w
  FROM touches
),
credit AS (
  SELECT
    *,
    SUM(decay_w) OVER (PARTITION BY transaction_id) AS decay_sum,
    SUM(IF(is_direct, 0, decay_w)) OVER (PARTITION BY transaction_id) AS decay_sum_nd
  FROM seq
)
SELECT
  order_date,
  transaction_id,
  order_ts,
  customer_id,
  user_pseudo_id,
  item_id,
  revenue,
  order_seq,
  order_seq > 1 AS is_repeat,
  -- 下單日往前推一個回溯窗口早於資料起點，這筆訂單的路徑可能被截斷
  DATE_SUB(order_date, INTERVAL lookback_days DAY) < data_start AS window_truncated,
  touch_seq,
  path_len,
  TIMESTAMP_MICROS(touch_us) AS touch_ts,
  ROUND((order_us - touch_us) / 86400e6, 3) AS days_before_order,
  channel,
  utm_campaign,
  is_direct,
  -- direct 也算觸點
  IF(touch_seq = 1, 1.0, 0.0) AS credit_first,
  IF(touch_seq = path_len, 1.0, 0.0) AS credit_last,
  decay_w / decay_sum AS credit_decay,
  -- direct 不算觸點：整條路徑都是 direct 時才把功勞給 direct
  IF(nd_len = 0, IF(touch_seq = 1, 1.0, 0.0),
     IF(NOT is_direct AND nd_seq = 1, 1.0, 0.0)) AS credit_first_nd,
  IF(nd_len = 0, IF(touch_seq = path_len, 1.0, 0.0),
     IF(NOT is_direct AND nd_seq = nd_len, 1.0, 0.0)) AS credit_last_nd,
  IF(nd_len = 0, decay_w / decay_sum,
     IF(is_direct, 0.0, decay_w / decay_sum_nd)) AS credit_decay_nd
FROM credit;
