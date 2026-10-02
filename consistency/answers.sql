-- Day 19：答案表，廣告圖上有寫、到達頁面上找不到或說法不同的地方，一列＝一張廣告圖的一個落差
-- 這個檔在第一次執行 compare.sql 之前 commit，之後不回頭改，run.sh 在這個檔、compare.sql 或 score.sql 有未 commit 的修改時會直接停下來
--
-- 答案怎麼來的：廣告圖上的字是 creatives/compose.py 照規格畫上去的（標題依主打商品，文字多的圖另外有兩行賣點和兩個徽章），
-- 頁面內容來自 live-demo/products.json 與樣板，兩邊逐字比對，不靠 AI，不是盲考的地方是這些落差本來就存在、只是沒有人列過
--
-- 只收「查得到對錯」的五種落差，形容觸感、質感的文案（柔軟、蓬鬆、好吸水）不收：
--   limited_offer   徽章寫「限定」：秋日專案文字多的 3 張，活動頁沒有任何限量、限時或截止日期
--   special_price   徽章寫「專案價」：重訓專案文字多、主打厚底毛巾訓練襪的 3 張，活動頁上這雙襪子是 NT$ 260、沒有優惠價
--   free_shipping   徽章寫「免運」：常態素材文字多的 5 張，首頁只在秋日專案那一格寫「滿 NT$ 600 免運」，廣告沒有寫門檻
--   product_name    標題寫「純棉短襪」：主打日常中筒襪的 8 張，頁面上的商品叫「日常中筒襪」、材質寫精梳棉
--   product_option  賣點寫「多色可選」：主打日常中筒襪、文字多的 2 張，頁面沒有任何顏色選項
-- 有爭議的 1 列（disputed = TRUE，不計分）：cr-line-trn-r2 的徽章也寫「專案價」，但它主打日常中筒襪，
--   活動頁上這雙襪子標 NT$ 180、原價 NT$ 220 劃掉，那是全站都有的價格、不是這個專案才有，算不算「專案價」見仁見智
-- 沒有任何落差的廣告圖有 6 張（文字少、主打的不是日常中筒襪），用來看 AI 會不會無中生有
-- ad_keyword 是廣告圖上那幾個字，報表用它看 AI 抄下來的廣告文字裡有沒有這個詞（有讀到但沒列，還是根本沒讀到）

CREATE OR REPLACE TABLE martech_gt.gt_ad_page_gaps
OPTIONS (description = 'Day 19 答案表：廣告圖有寫、到達頁面找不到或說法不同的落差，一列＝一張圖的一個落差，第一次執行 compare.sql 之前寫死')
AS
SELECT * FROM UNNEST([
  STRUCT('cr-meta-aut-p1' AS creative_id, 'limited_offer' AS gap_type, '限定' AS ad_keyword,
    '活動頁沒有限量、限時或截止日期' AS page_fact, FALSE AS disputed),
  ('cr-meta-aut-p2', 'limited_offer', '限定', '活動頁沒有限量、限時或截止日期', FALSE),
  ('cr-line-aut-p2', 'limited_offer', '限定', '活動頁沒有限量、限時或截止日期', FALSE),

  ('cr-meta-trn-p1', 'special_price', '專案價', '活動頁上厚底毛巾訓練襪 NT$ 260，沒有優惠價', FALSE),
  ('cr-meta-trn-r1', 'special_price', '專案價', '活動頁上厚底毛巾訓練襪 NT$ 260，沒有優惠價', FALSE),
  ('cr-line-trn-r1', 'special_price', '專案價', '活動頁上厚底毛巾訓練襪 NT$ 260，沒有優惠價', FALSE),
  ('cr-line-trn-r2', 'special_price', '專案價', '活動頁上日常中筒襪 NT$ 180、原價 NT$ 220 劃掉，全站都是這個價格', TRUE),

  ('cr-meta-evg-r2', 'free_shipping', '免運', '首頁只在秋日專案寫滿 NT$ 600 免運', FALSE),
  ('cr-line-evg-p1', 'free_shipping', '免運', '首頁只在秋日專案寫滿 NT$ 600 免運', FALSE),
  ('cr-line-evg-p2', 'free_shipping', '免運', '首頁只在秋日專案寫滿 NT$ 600 免運', FALSE),
  ('cr-line-evg-r1', 'free_shipping', '免運', '首頁只在秋日專案寫滿 NT$ 600 免運', FALSE),
  ('cr-line-evg-r2', 'free_shipping', '免運', '首頁只在秋日專案寫滿 NT$ 600 免運', FALSE),

  ('cr-meta-evg-p1', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),
  ('cr-meta-trn-p2', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),
  ('cr-meta-trn-r2', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),
  ('cr-meta-aut-r1', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),
  ('cr-line-evg-p1', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),
  ('cr-line-trn-p2', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),
  ('cr-line-trn-r2', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),
  ('cr-line-aut-r1', 'product_name', '短襪', '頁面上的商品是日常中筒襪', FALSE),

  ('cr-line-evg-p1', 'product_option', '多色可選', '頁面沒有顏色選項', FALSE),
  ('cr-line-trn-r2', 'product_option', '多色可選', '頁面沒有顏色選項', FALSE)
]);

SELECT gap_type, ad_keyword,
  COUNTIF(NOT disputed) AS scored,
  COUNTIF(disputed) AS disputed,
  STRING_AGG(creative_id, '、' ORDER BY creative_id) AS creatives
FROM martech_gt.gt_ad_page_gaps
GROUP BY 1, 2
ORDER BY 1;
