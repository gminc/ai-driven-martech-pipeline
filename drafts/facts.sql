-- Day 18：替 AI 打草稿準備兩張參考表
--   ref_product_facts：商品事實，內容照抄 live-demo/products.json（Day 04 小店的商品頁），草稿只能寫這裡有的事實
--   ref_claim_terms：不能寫進廣告的詞，Day 18 用來數草稿裡冒出幾個，Day 23 做過濾時沿用
-- 兩張都是小表、整張重建，可以重複執行，查詢在每月 1 TiB 免費額度內
-- 商品故事原文的全形分號與破折號改成逗號，其他照抄

CREATE OR REPLACE TABLE martech_dw.ref_product_facts (
  item_id   STRING NOT NULL,
  name      STRING,
  subtitle  STRING,
  summary   STRING,
  story     STRING,
  material  STRING,
  made_in   STRING
)
OPTIONS (description = 'Day 18 商品事實，照抄 live-demo/products.json，草稿只能寫這裡有的事實');

INSERT INTO martech_dw.ref_product_facts VALUES
  ('sock-crew-daily', '日常中筒襪', '精梳棉 × 無壓痕束口', '中等厚度、透氣舒適，適合外出與日常穿搭。', '襪口採用低張力羅紋，脫下後腳踝不留一圈壓痕，腳趾以平織手法收邊，減少走一整天後的摩擦感。', '精梳棉 78%、聚酯纖維 20%、彈性纖維 2%', '彰化社頭'),
  ('sock-towel-training', '厚底毛巾訓練襪', '毛圈底 × 足弓支撐', '厚底毛巾結構，重訓時穩定、耐穿。', '腳掌下方織入高密度毛圈，硬舉與深蹲時腳掌不會在鞋內滑動，足弓處加上一圈織入式支撐帶，久站也不容易累。', '精梳棉 72%、尼龍 25%、彈性纖維 3%', '彰化社頭'),
  ('towel-face-cotton', '純棉洗臉毛巾', '無撚紗 × 瞬吸快乾', '柔軟吸水，每天洗臉都舒服。', '以無撚紗織成，纖維之間留有空氣，第一次使用就能吸水，洗過幾次之後會更蓬鬆。邊緣採用細針收邊，不易脫線。', '100% 有機棉（無撚紗）', '雲林虎尾'),
  ('towel-bath-cotton', '純棉大浴巾', '雙面毛圈 × 厚實包覆', '大尺寸、厚實包覆，洗完澡的第一份溫暖。', '雙面毛圈讓浴巾兩面都能擦，厚度控制在 480 g 上下，足夠包覆，又不會厚到洗完晾不乾。', '100% 有機棉', '雲林虎尾'),
  ('set-starter', '日常入門組合', '中筒襪 ×2 ＋ 洗臉毛巾 ×2', '中筒襪兩雙＋洗臉毛巾兩條，送禮自用都合適。', '想先認識我們的話，從這組開始最剛好：一雙上班穿、一雙在家穿，兩條毛巾一條放浴室、一條放健身包。附素面紙盒，可直接送人。', '依組合內單品材質', '彰化社頭 × 雲林虎尾');

-- 不能寫進廣告的詞，分三類：
--   功效：紡織品沒有檢驗報告不能宣稱的機能
--   醫療：一般商品不能暗示醫療效果
--   絕對：無法證明的絕對用語（單一個「最」「第一」會誤抓「最近」「第一次使用」這類商品事實，所以只列常見的組合）
-- 比對方式是字串包含，Day 23 會再加上正規化（全半形、空白）與語意判斷
CREATE OR REPLACE TABLE martech_dw.ref_claim_terms (
  term  STRING NOT NULL,
  kind  STRING NOT NULL
)
OPTIONS (description = 'Day 18 不能寫進廣告的詞（功效、醫療、絕對用語），Day 18 數草稿裡冒出幾個，Day 23 過濾沿用');

INSERT INTO martech_dw.ref_claim_terms (term, kind)
SELECT term, '功效' FROM UNNEST(['抗菌', '殺菌', '抑菌', '除臭', '防臭', '消臭', '防蹣', '除蹣', '防霉', '遠紅外線', '負離子', '血液循環', '排毒']) AS term
UNION ALL
SELECT term, '醫療' FROM UNNEST(['醫療', '醫學', '醫師', '療效', '治療', '消炎', '止癢', '止痛', '抗過敏', '預防']) AS term
UNION ALL
SELECT term, '絕對' FROM UNNEST(['最好', '最強', '最佳', '最舒服', '最柔軟', '最吸水', '第一名', '全台第一', '業界第一', '唯一', '保證', '永不', '絕對', '100% 有效', 'No.1']) AS term;

SELECT kind, COUNT(*) AS terms FROM martech_dw.ref_claim_terms GROUP BY kind ORDER BY kind;
