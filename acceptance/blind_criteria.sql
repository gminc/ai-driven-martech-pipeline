-- Day 13：AI 盲測的判準，先寫死、先 commit，再呼叫 Gemini（blind.sql）
-- 盲測只給整季週報、不給候選原因，Gemini 回傳的每一項發現要同時命中三組關鍵字才算找到某個訊號
-- 週報看得到的只有 S1、S2、S3、S7 四題；S5（顧客類型）與 S6（通路在路徑的位置）週報裡沒有這種資料，不考
-- 判準是規則運算式（RE2），看完結果不能回頭改；要改就另開一版並在 README 記錄原因
-- 關鍵字判定一定有誤差，文章會把每一項發現的原文列出來給讀者自己對照
-- 答案與判準都放在 martech_gt，題目（blind_prompt.sql）與呼叫（blind.sql）只讀 martech_dw

CREATE OR REPLACE TABLE martech_gt.blind_criteria
OPTIONS(description = 'Day 13 AI 盲測判準：每個訊號要同時命中的三組關鍵字（規則運算式），呼叫 Gemini 前寫死') AS
SELECT * FROM UNNEST([
  STRUCT(
    'S1' AS signal_id,
    'meta-trn-prospecting 的平均每次點擊花費從 8/12 起變成兩倍（點擊次數沒有變）' AS rule,
    r'(meta-trn-prospecting|(Meta|meta).{0,8}重訓襪.{0,12}(開發新客|prospecting))' AS must_1,
    r'(CPC|點擊成本|每次點擊|單次點擊|點擊花費|點擊單價|點擊費用|點擊價格|每點擊|花費.{0,8}(倍|翻))' AS must_2,
    r'(升|漲|貴|增|倍|飆|跳|攀|拉高|走高|提高|變高)' AS must_3),
  ('S2',
    '8/24 那週網站追蹤到的購買事件比後台訂單少（8/27 整天沒送出 purchase 事件）',
    r'(8/24|8/27|8 ?月 ?24|8 ?月 ?27|08-24|08-27|0824|0827)',
    r'(追蹤|purchase|購買事件|購買|事件|GA4)',
    r'(少|低|落差|缺|漏|不一致|對不上|差距|差異|遺漏|失效|沒有|未|短|減|降|異常|掉|不符|不等)'),
  ('S3',
    'cr-meta-evg-p1 的點擊率逐週下降',
    r'cr-meta-evg-p1',
    r'(點擊率|CTR)',
    r'(降|滑|衰|退|減|跌|疲|走低|降低|遞減|逐週|逐漸|越來越)'),
  ('S7',
    '秋日棉織專案期間（9/1 起）專案商品（純棉洗臉毛巾、日常中筒襪、日常入門組合）的售出件數或占比上升',
    r'(秋日|autumn|AUTUMN|9/1|9/8|9/14|9 ?月|09-0|09-1)',
    r'(洗臉|入門組合|中筒襪|專案商品|占比|比例|比重)',
    r'(升|增|多|高|成長|拉高|上揚|翻|倍|跳)')
]);

SELECT signal_id, rule FROM martech_gt.blind_criteria ORDER BY signal_id;
