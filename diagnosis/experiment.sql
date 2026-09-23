-- Day 09 3.4 小實驗：資料給不夠，AI 會不會硬猜
-- 同樣四筆異常，只留下「老闆最常看的那幾個數字」，拿掉能分辨原因的關鍵欄位
--   廣告群組：只給花費和同通路 ROAS，拿掉點擊成本與點擊率
--   素材：只給曝光與點擊，拿掉和上線初期的比較
--   全站：只給網站追蹤到的購買與 ROAS，拿掉後台訂單
-- A 組：沒有「資料不足」選項、也沒有「不要硬猜」的規則
-- B 組：有「資料不足」選項和規則（和正式診斷一樣）
-- 模型固定用 gemini-3.5-flash-lite，結果放 diag_experiment，不混進 mart_diagnosis

CREATE OR REPLACE TABLE martech_dw.diag_experiment AS
WITH thin AS (
  SELECT
    anomaly_id, level, entity, period_start,
    CASE level
      WHEN 'adgroup_week' THEN FORMAT(
        '對象：廣告群組 %s（通路 %s）\n期間：%t 到 %t\n- 這週花費：%s 元\n- 同通路的網站追蹤 ROAS：%s（前四週 %s）',
        entity, channel, period_start, period_end,
        FORMAT('%.0f', CAST(JSON_VALUE(metrics_json, '$.cost') AS FLOAT64)),
        JSON_VALUE(metrics_json, '$.channel_roas'), JSON_VALUE(metrics_json, '$.channel_roas_base'))
      WHEN 'creative_week' THEN FORMAT(
        '對象：廣告素材 %s（通路 %s）\n期間：%t 到 %t\n- 曝光：%s 次，點擊：%s 次',
        entity, channel, period_start, period_end,
        JSON_VALUE(metrics_json, '$.imp'), JSON_VALUE(metrics_json, '$.clk'))
      WHEN 'site_day' THEN FORMAT(
        '對象：全站\n期間：%t 單日，對照前七天平均\n- 網站追蹤到的購買：%s 筆（前七天平均 %s 筆）\n- 用網站追蹤營收算的 ROAS：%s',
        period_start,
        JSON_VALUE(metrics_json, '$.tracked'), JSON_VALUE(metrics_json, '$.tracked_base'),
        JSON_VALUE(metrics_json, '$.tracked_roas'))
    END AS facts
  FROM martech_dw.diag_summary
),
a AS (
  SELECT 'A_硬選' AS variant, anomaly_id, level, entity, period_start, facts,
    CONCAT('你是電商公司的廣告分析師，下面是一筆成效異常\n\n', facts, '\n\n',
      '請判斷最可能的原因，從這五個選一個：競價變貴、追蹤碼失效、素材疲乏、需求或季節變化、其他') AS prompt
  FROM thin
),
b AS (
  SELECT 'B_可說不知道' AS variant, anomaly_id, level, entity, period_start, facts,
    CONCAT('你是電商公司的廣告分析師，下面是一筆成效異常\n\n', facts, '\n\n',
      '請判斷最可能的原因，只能從這六個選一個：競價變貴、追蹤碼失效、素材疲乏、需求或季節變化、其他、資料不足\n',
      '規則：\n',
      '1. 只能根據上面的數字推論，不要假設沒給你的資訊\n',
      '2. 數字不夠下結論時選「資料不足」，不要硬猜\n',
      '3. evidence 用一到兩句繁體中文，引用你判斷時用到的數字\n',
      '4. next_check 寫一件行銷人員接下來應該去確認的事') AS prompt
  FROM thin
)
SELECT variant, anomaly_id, level, entity, period_start,
  JSON_VALUE(result, '$.cause') AS cause,
  JSON_VALUE(result, '$.evidence') AS evidence,
  SAFE_CAST(JSON_VALUE(result, '$.confidence') AS FLOAT64) AS confidence,
  prompt, result AS raw_result, statistics, status
FROM AI.GENERATE_TEXT(
  MODEL martech_dw.gemini_flash_lite,
  (SELECT * FROM a),
  STRUCT('''{"generation_config": {"max_output_tokens": 512, "thinking_config": {"thinking_budget": 0},
    "response_mime_type": "application/json",
    "response_schema": {"type": "OBJECT", "properties": {
      "cause": {"type": "STRING", "enum": ["競價變貴", "追蹤碼失效", "素材疲乏", "需求或季節變化", "其他"]},
      "evidence": {"type": "STRING"}, "confidence": {"type": "NUMBER"}},
      "required": ["cause", "evidence", "confidence"]}}}''' AS model_params))
UNION ALL
SELECT variant, anomaly_id, level, entity, period_start,
  JSON_VALUE(result, '$.cause'), JSON_VALUE(result, '$.evidence'),
  SAFE_CAST(JSON_VALUE(result, '$.confidence') AS FLOAT64),
  prompt, result, statistics, status
FROM AI.GENERATE_TEXT(
  MODEL martech_dw.gemini_flash_lite,
  (SELECT * FROM b),
  STRUCT('''{"generation_config": {"max_output_tokens": 512, "thinking_config": {"thinking_budget": 0},
    "response_mime_type": "application/json",
    "response_schema": {"type": "OBJECT", "properties": {
      "cause": {"type": "STRING", "enum": ["競價變貴", "追蹤碼失效", "素材疲乏", "需求或季節變化", "其他", "資料不足"]},
      "evidence": {"type": "STRING"}, "confidence": {"type": "NUMBER"}, "next_check": {"type": "STRING"}},
      "required": ["cause", "evidence", "confidence", "next_check"]}}}''' AS model_params));
