-- Day 16：記下「規格和畫面看起來不一致」的圖，放在答案資料集 martech_gt
-- 設計規格是合成器畫圖時照的，但底圖是 AI 生的，生出來的畫面不一定完全照規格，
-- 例如規格寫 cool（淺藍、灰、白），生出來的背景可能只是淺灰，照題目的判斷標準會是 neutral，
-- 這種圖拿來考 AI，答錯不一定是 AI 的錯，所以先標出來，report.sql 分兩種口徑算答對率，Day 20 評測排除 disagree 的圖
--
-- 做法：看圖之前，先請一位沒看過規格的判讀者照 extract.sql 同一套判斷標準逐張判讀 24 張，
-- 再和規格比對，判讀結果和規格不同的記 disagree，判讀者自己標了「別人可能判得不一樣」的記 borderline
-- 24 張 × 4 欄共 96 格，disagree 1 格、borderline 6 格，全部在 dominant_color
-- 這份表屬於答案，extract.sql 與 mart.sql 都不讀它，查詢在每月 1 TiB 免費額度內，整張重建，可以重複執行

CREATE OR REPLACE TABLE martech_gt.gt_creative_review
OPTIONS (description = 'Day 16 規格與畫面判讀不一致的格子：一列＝一張圖的一個欄位，verdict 為 disagree（判讀和規格不同）或 borderline（判讀者認為可能判得不一樣）')
AS
SELECT * FROM UNNEST([
  STRUCT('cr-meta-trn-r2' AS creative_id, 'dominant_color' AS field, 'cool' AS spec_value, 'neutral' AS eye_value, 'disagree' AS verdict,
         '背景是淺灰牆和水泥地，只帶一點點藍，照判斷標準的淺灰算 neutral' AS note),
  STRUCT('cr-line-aut-r2', 'dominant_color', 'warm', 'warm', 'borderline',
         '上半是赤陶色牆，下半是米色亞麻桌布，面積各半'),
  STRUCT('cr-line-evg-p1', 'dominant_color', 'cool', 'cool', 'borderline',
         '牆是灰藍，桌面是淺灰'),
  STRUCT('cr-line-evg-r2', 'dominant_color', 'cool', 'cool', 'borderline',
         '背景是很淡的灰藍，可能被看成淺灰'),
  STRUCT('cr-line-trn-r2', 'dominant_color', 'cool', 'cool', 'borderline',
         '上方牆面淡藍，下方水泥台灰色'),
  STRUCT('cr-meta-aut-p1', 'dominant_color', 'cool', 'cool', 'borderline',
         '牆面和桌面是偏藍的淺灰，介於灰藍和淺灰之間'),
  STRUCT('cr-meta-evg-p1', 'dominant_color', 'warm', 'warm', 'borderline',
         '左邊赤陶色板，右半邊是偏粉的米色牆')
]);

SELECT verdict, field, COUNT(*) AS cells
FROM martech_gt.gt_creative_review
GROUP BY 1, 2
ORDER BY 1, 2;
