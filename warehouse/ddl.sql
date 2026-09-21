-- Day 07：martech_dw 星狀綱要 DDL
-- 三張事實表＋四張維度表，型別與 raw 表一致，事實表都設分區與叢集
-- CREATE OR REPLACE 讓整份可以重跑，DDL 本身不收費
-- 用法：bash warehouse/build.sh（會先跑這份再跑 build.sql）

-- ── 維度表 ─────────────────────────────────────────────

CREATE OR REPLACE TABLE martech_dw.dim_date (
  date           DATE   NOT NULL OPTIONS(description = '日期（台北）'),
  event_date     STRING NOT NULL OPTIONS(description = 'YYYYMMDD 字串，與 GA4 匯出表相同，方便和事件表對照'),
  week_start     DATE   NOT NULL OPTIONS(description = '所屬週的週一'),
  day_of_week    INT64  NOT NULL OPTIONS(description = '1＝週日 … 7＝週六（BigQuery DAYOFWEEK）'),
  is_weekend     BOOL   NOT NULL OPTIONS(description = '週六或週日'),
  promotion_ids  ARRAY<STRING>  OPTIONS(description = '當天進行中的專案代號，沒有專案為空陣列')
)
OPTIONS(description = 'Day 07 日期維度，涵蓋合成資料與 GA4 的完整期間');

CREATE OR REPLACE TABLE martech_dw.dim_creative (
  creative_id     STRING NOT NULL OPTIONS(description = '素材 ID'),
  channel         STRING OPTIONS(description = '通路：meta、line、google_cpc'),
  utm_campaign    STRING OPTIONS(description = '活動代號'),
  promotion_id    STRING OPTIONS(description = '專案代號，常態素材為空'),
  ad_group_id     STRING OPTIONS(description = '廣告群組'),
  audience        STRING OPTIONS(description = '受眾'),
  format          STRING OPTIONS(description = 'image 或 search_text'),
  start_date      DATE   OPTIONS(description = '上線日'),
  end_date        DATE   OPTIONS(description = '下檔日'),
  product_focus   STRING OPTIONS(description = '主打商品 ID'),
  has_person      BOOL   OPTIONS(description = '圖片是否有人物，文字廣告為空'),
  cta_position    STRING OPTIONS(description = 'CTA 位置'),
  dominant_color  STRING OPTIONS(description = '主色系'),
  text_density    STRING OPTIONS(description = '文字密度'),
  image_file      STRING OPTIONS(description = '圖檔名稱')
)
OPTIONS(description = 'Day 07 素材維度，S4 素材屬性分析從這裡取屬性');

CREATE OR REPLACE TABLE martech_dw.dim_customer (
  customer_id       STRING NOT NULL OPTIONS(description = '顧客 ID'),
  city              STRING OPTIONS(description = '縣市'),
  first_order_date  DATE   OPTIONS(description = '首購日')
)
OPTIONS(description = 'Day 07 顧客維度，刻意不帶姓名、email、手機，個資只留在 raw_customers');

CREATE OR REPLACE TABLE martech_dw.dim_product (
  item_id           STRING NOT NULL OPTIONS(description = '商品 ID'),
  unit_price        INT64  OPTIONS(description = '最常見的成交單價（新台幣），沒有成交紀錄為空'),
  promotion_ids     ARRAY<STRING> OPTIONS(description = '曾經主打這項商品的專案代號'),
  first_seen_date   DATE   OPTIONS(description = '第一次出現在事件或訂單的日期')
)
OPTIONS(description = 'Day 07 商品維度，由訂單、事件與素材整理出來');

-- ── 事實表 ─────────────────────────────────────────────

CREATE OR REPLACE TABLE martech_dw.fct_ad_daily (
  date          DATE    NOT NULL OPTIONS(description = '日期（台北），分區欄位'),
  creative_id   STRING  NOT NULL OPTIONS(description = '素材 ID，對應 dim_creative'),
  channel       STRING  OPTIONS(description = '通路，刻意保留在事實表當叢集欄位'),
  ad_group_id   STRING  OPTIONS(description = '廣告群組'),
  utm_campaign  STRING  OPTIONS(description = '活動代號'),
  impressions   INT64   OPTIONS(description = '曝光'),
  clicks        INT64   OPTIONS(description = '點擊'),
  cost          NUMERIC OPTIONS(description = '花費（新台幣，小數兩位）'),
  data_source   STRING  NOT NULL OPTIONS(description = '資料來源：synthetic')
)
PARTITION BY date
CLUSTER BY channel, creative_id
OPTIONS(description = 'Day 07 廣告成效事實表，粒度：日 × 素材');

CREATE OR REPLACE TABLE martech_dw.fct_events (
  event_dt        DATE    NOT NULL OPTIONS(description = '事件日期（DATE），分區欄位，由 event_date 轉換'),
  event_date      STRING  NOT NULL OPTIONS(description = 'YYYYMMDD 字串，保留 GA4 原格式'),
  event_timestamp INT64   NOT NULL OPTIONS(description = 'UTC 微秒'),
  event_name      STRING  NOT NULL OPTIONS(description = '事件名稱'),
  user_pseudo_id  STRING  NOT NULL OPTIONS(description = '訪客 ID，字串'),
  ga_session_id   INT64   OPTIONS(description = '工作階段 ID'),
  customer_id     STRING  OPTIONS(description = '顧客 ID，GA4 取 user_id'),
  utm_source      STRING  OPTIONS(description = '工作階段來源，沒有 UTM 為 (direct)'),
  utm_medium      STRING  OPTIONS(description = '工作階段媒介，沒有 UTM 為 (none)'),
  utm_campaign    STRING  OPTIONS(description = '工作階段活動，沒有 UTM 為 (direct)'),
  creative_id     STRING  OPTIONS(description = '素材 ID，GA4 取 creative_name'),
  promotion_id    STRING  OPTIONS(description = '專案代號'),
  item_id         STRING  OPTIONS(description = '商品 ID，事件只帶一項商品時才有值'),
  item_variant    STRING  OPTIONS(description = '尺寸原字串，(not set) 轉成 NULL'),
  quantity        INT64   OPTIONS(description = '數量'),
  item_count      INT64   NOT NULL OPTIONS(description = '事件帶的商品項數'),
  value           FLOAT64 OPTIONS(description = '事件金額，GA4 整數、浮點數兩種存法合併'),
  transaction_id  STRING  OPTIONS(description = '訂單編號，(not set) 轉成 NULL'),
  data_source     STRING  NOT NULL OPTIONS(description = '資料來源：synthetic 或 ga4')
)
PARTITION BY event_dt
CLUSTER BY event_name, user_pseudo_id
OPTIONS(
  description = 'Day 07 事件事實表，粒度：一個事件，合成資料與 GA4 攤平後合併',
  require_partition_filter = TRUE
);

CREATE OR REPLACE TABLE martech_dw.fct_orders (
  order_date      DATE      NOT NULL OPTIONS(description = '訂單日期（台北），分區欄位'),
  transaction_id  STRING    NOT NULL OPTIONS(description = '訂單編號'),
  order_ts        TIMESTAMP NOT NULL OPTIONS(description = '訂單成立時間'),
  customer_id     STRING    OPTIONS(description = '顧客 ID，對應 dim_customer'),
  user_pseudo_id  STRING    OPTIONS(description = '訪客 ID'),
  item_id         STRING    OPTIONS(description = '商品 ID，對應 dim_product'),
  item_variant    STRING    OPTIONS(description = '尺寸原字串'),
  quantity        INT64     OPTIONS(description = '數量'),
  unit_price      INT64     OPTIONS(description = '單價（新台幣）'),
  revenue         INT64     OPTIONS(description = '金額（新台幣）'),
  utm_source      STRING    OPTIONS(description = '來源'),
  utm_medium      STRING    OPTIONS(description = '媒介'),
  utm_campaign    STRING    OPTIONS(description = '活動代號'),
  payment_status  STRING    OPTIONS(description = '付款狀態'),
  data_source     STRING    NOT NULL OPTIONS(description = '資料來源：synthetic')
)
PARTITION BY order_date
CLUSTER BY customer_id
OPTIONS(description = 'Day 07 訂單事實表，粒度：一筆訂單');
