-- Day 19：廣告點進去會到哪一頁，把頁面準備成 Gemini 讀得到的兩種樣子
--   1. 頁面文字：ref_landing_pages，一列＝一個頁面，page_text 是瀏覽器畫面上看得到的全部文字（由上到下，空行拿掉）
--   2. 頁面截圖：物件表 obj_landing，指向素材 bucket 的 landing/ 資料夾（creatives/landing/ 的三張 jpg，寬 1200、整頁長截圖）
--   3. 對照表：map_creative_landing，24 張廣告圖各自導去哪一頁（常態素材到首頁，兩個專案到各自的活動頁）
-- 文字和截圖都來自同一份 live-demo 程式（2026-10-02 在本機啟動後用無頭瀏覽器擷取），所以兩種給法的內容是同一個頁面
-- 這個檔只準備題目，不讀答案表，建表與查中繼資料不收費（含在每月 1 TiB 免費額度）
-- PROJECT_ID 由 run.sh 換成目前的專案 ID

CREATE OR REPLACE TABLE martech_dw.ref_landing_pages
OPTIONS (description = 'Day 19 到達頁面的文字：一列＝一個頁面，page_text 是畫面上看得到的全部文字')
AS
SELECT * FROM UNNEST([
  STRUCT('home' AS page_id, '/' AS path, '首頁' AS title, '''iThome 鐵人賽技術展示站：使用綠界「測試環境」，不會實際扣款，商品不會出貨；站上商品與情境圖由 Pollinations.ai 與 Gemini 生成。
織日常
EVERYDAY WEAVE
全部商品
關於織日常
當期專案
彰化社頭・台灣織造
擦拭時的純淨蓬鬆
行走時的溫柔包覆
看看商品
全部商品
襪子、毛巾、浴巾，從每天都會用到的小東西開始。
經典款
襪子
日常中筒襪
精梳棉 × 無壓痕束口
NT$ 180 NT$ 220
運動選用
襪子
厚底毛巾訓練襪
毛圈底 × 足弓支撐
NT$ 260
每日必備
毛巾
純棉洗臉毛巾
無撚紗 × 瞬吸快乾
NT$ 220
人氣商品
浴巾
純棉大浴巾
雙面毛圈 × 厚實包覆
NT$ 690 NT$ 780
組合省 130
組合
日常入門組合
中筒襪 ×2 ＋ 洗臉毛巾 ×2
NT$ 890 NT$ 1,020
當期專案
秋日棉織專案
入秋選品：無撚紗毛巾與中筒襪，滿 NT$ 600 免運。
重訓襪專案
厚底毛圈與足弓支撐，為硬舉與深蹲設計的訓練襪。
織日常 · Everyday Weave
彰化社頭・台灣織造
商品
日常中筒襪
厚底毛巾訓練襪
純棉洗臉毛巾
純棉大浴巾
日常入門組合
關於
品牌與織造
秋日棉織專案
重訓襪專案
說明
本站為 2026 iThome 鐵人賽「AI-Driven MarTech」系列的 Live Demo，品牌與商品皆為示範用途。
付款模式：綠界 ECPay 測試環境''' AS page_text),
  ('lp-autumn-cotton', '/lp/autumn-cotton', '秋日棉織專案活動頁', '''iThome 鐵人賽技術展示站：使用綠界「測試環境」，不會實際扣款，商品不會出貨；站上商品與情境圖由 Pollinations.ai 與 Gemini 生成。
織日常
EVERYDAY WEAVE
全部商品
關於織日常
當期專案
秋日棉織專案
換季的第一件事，先把每天碰到皮膚的東西換好
入秋選品：無撚紗毛巾與中筒襪，滿 NT$ 600 免運。
無撚紗織法，洗過越多次越蓬鬆
低敏染整，敏感肌與嬰幼兒都適用
彰化社頭與雲林虎尾的老廠，低速織機慢慢織
看專案商品
專案商品
每日必備
毛巾
純棉洗臉毛巾
無撚紗 × 瞬吸快乾
NT$ 220
經典款
襪子
日常中筒襪
精梳棉 × 無壓痕束口
NT$ 180 NT$ 220
組合省 130
組合
日常入門組合
中筒襪 ×2 ＋ 洗臉毛巾 ×2
NT$ 890 NT$ 1,020
織日常 · Everyday Weave
彰化社頭・台灣織造
商品
日常中筒襪
厚底毛巾訓練襪
純棉洗臉毛巾
純棉大浴巾
日常入門組合
關於
品牌與織造
秋日棉織專案
重訓襪專案
說明
本站為 2026 iThome 鐵人賽「AI-Driven MarTech」系列的 Live Demo，品牌與商品皆為示範用途。
付款模式：綠界 ECPay 測試環境'''),
  ('lp-training-socks', '/lp/training-socks', '重訓襪專案活動頁', '''iThome 鐵人賽技術展示站：使用綠界「測試環境」，不會實際扣款，商品不會出貨；站上商品與情境圖由 Pollinations.ai 與 Gemini 生成。
織日常
EVERYDAY WEAVE
全部商品
關於織日常
當期專案
重訓襪專案
腳掌在鞋裡滑一次，那一組就白做了
厚底毛圈與足弓支撐，為硬舉與深蹲設計的訓練襪。
腳掌高密度毛圈，出力時不打滑
織入式足弓支撐帶，久站不易累
腳趾平織接縫，長時間穿不磨腳
看專案商品
專案商品
運動選用
襪子
厚底毛巾訓練襪
毛圈底 × 足弓支撐
NT$ 260
經典款
襪子
日常中筒襪
精梳棉 × 無壓痕束口
NT$ 180 NT$ 220
織日常 · Everyday Weave
彰化社頭・台灣織造
商品
日常中筒襪
厚底毛巾訓練襪
純棉洗臉毛巾
純棉大浴巾
日常入門組合
關於
品牌與織造
秋日棉織專案
重訓襪專案
說明
本站為 2026 iThome 鐵人賽「AI-Driven MarTech」系列的 Live Demo，品牌與商品皆為示範用途。
付款模式：綠界 ECPay 測試環境''')
]);

CREATE OR REPLACE EXTERNAL TABLE martech_dw.obj_landing
WITH CONNECTION `us.vertex_ai_conn`
OPTIONS (
  object_metadata = 'SIMPLE',
  uris = ['gs://PROJECT_ID-martech-assets/landing/*.jpg']
);

CREATE OR REPLACE TABLE martech_dw.map_creative_landing
OPTIONS (description = 'Day 19 廣告圖導去哪一頁：一列＝一張廣告圖，依活動代號對到頁面')
AS
SELECT creative_id, channel, audience, utm_campaign, product_focus,
  CASE utm_campaign
    WHEN 'autumn-cotton' THEN 'lp-autumn-cotton'
    WHEN 'training-socks' THEN 'lp-training-socks'
    ELSE 'home'
  END AS page_id
FROM martech_dw.dim_creative
WHERE format = 'image';

SELECT m.page_id, p.path, p.title,
  COUNT(*) AS creatives,
  ANY_VALUE(LENGTH(p.page_text)) AS text_chars,
  ANY_VALUE(o.size) AS screenshot_bytes
FROM martech_dw.map_creative_landing m
JOIN martech_dw.ref_landing_pages p USING (page_id)
LEFT JOIN martech_dw.obj_landing o ON o.uri LIKE CONCAT('%/', m.page_id, '.jpg')
GROUP BY 1, 2, 3
ORDER BY 1;
