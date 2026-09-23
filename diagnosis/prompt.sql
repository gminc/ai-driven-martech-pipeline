-- Day 09 第二步：把每一列異常摘要寫成一段給 Gemini 看的白話說明
-- 只放數字與候選原因的名稱，不放答案、也不寫「點擊成本變高就是競價」這類判斷規則
-- 讓模型自己從數字組合推論，才看得出它到底有沒有判斷力

CREATE OR REPLACE VIEW martech_dw.diag_prompt AS
WITH d AS (
  SELECT s.*, JSON_QUERY(s.metrics_json, '$') AS mj
  FROM martech_dw.diag_summary s
),
f AS (
  SELECT
    anomaly_id, level, entity, period_start,
    CASE level
      WHEN 'adgroup_week' THEN FORMAT(
        '對象：廣告群組 %s（通路 %s）\n期間：%t 到 %t，這週有資料 %s 天，對照前四週\n'
        || '- 每天平均點擊：%s 次（前四週 %s 次）\n'
        || '- 點擊率：%s%%（前四週 %s%%）\n'
        || '- 平均每次點擊花費：%s 元（前四週 %s 元），變化 %s%%\n'
        || '- 這週花費：%s 元\n'
        || '- 同通路的網站追蹤 ROAS：%s（前四週 %s）',
        entity, channel, period_start, period_end, JSON_VALUE(mj, '$.days'),
        JSON_VALUE(mj, '$.clk_per_day'), JSON_VALUE(mj, '$.clk_per_day_base'),
        JSON_VALUE(mj, '$.ctr_pct'), JSON_VALUE(mj, '$.ctr_base_pct'),
        JSON_VALUE(mj, '$.cpc'), JSON_VALUE(mj, '$.cpc_base'), FORMAT('%+.0f', cpc_chg_pct),
        FORMAT('%.0f', CAST(JSON_VALUE(mj, '$.cost') AS FLOAT64)),
        IFNULL(JSON_VALUE(mj, '$.channel_roas'), '無資料'), IFNULL(JSON_VALUE(mj, '$.channel_roas_base'), '無資料'))
      WHEN 'creative_week' THEN FORMAT(
        '對象：廣告素材 %s（通路 %s）\n期間：%t 到 %t，這週有資料 %s 天，素材已上線 %s 天，對照素材上線頭 14 天\n'
        || '- 曝光：%s 次，點擊：%s 次\n'
        || '- 點擊率：%s%%（上線頭 14 天 %s%%），變化 %s%%\n'
        || '- 平均每次點擊花費：%s 元（上線頭 14 天 %s 元）\n'
        || '- 這週花費：%s 元',
        entity, channel, period_start, period_end, JSON_VALUE(mj, '$.days'), JSON_VALUE(mj, '$.days_since_launch'),
        JSON_VALUE(mj, '$.imp'), JSON_VALUE(mj, '$.clk'),
        JSON_VALUE(mj, '$.ctr_pct'), JSON_VALUE(mj, '$.ctr_base_pct'), FORMAT('%+.0f', ctr_chg_pct),
        JSON_VALUE(mj, '$.cpc'), JSON_VALUE(mj, '$.cpc_base'),
        FORMAT('%.0f', CAST(JSON_VALUE(mj, '$.cost') AS FLOAT64)))
      WHEN 'site_day' THEN FORMAT(
        '對象：全站\n期間：%t 單日，對照前七天平均\n'
        || '- 網站追蹤到的購買：%s 筆（前七天平均 %s 筆）\n'
        || '- 後台成立的訂單：%s 筆（前七天平均 %s 筆）\n'
        || '- 廣告點擊：%s 次（前七天平均 %s 次）\n'
        || '- 用網站追蹤營收算的 ROAS：%s，用後台訂單營收算的 ROAS：%s',
        period_start,
        JSON_VALUE(mj, '$.tracked'), JSON_VALUE(mj, '$.tracked_base'),
        JSON_VALUE(mj, '$.orders'), JSON_VALUE(mj, '$.orders_base'),
        JSON_VALUE(mj, '$.clk'), JSON_VALUE(mj, '$.clk_base'),
        JSON_VALUE(mj, '$.tracked_roas'), JSON_VALUE(mj, '$.order_roas'))
    END AS facts
  FROM d
)
SELECT
  anomaly_id, level, entity, period_start, facts,
  CONCAT(
    '你是電商公司的廣告分析師，下面是系統自動找出的一筆成效異常，數字都已經算好\n\n',
    facts, '\n\n',
    '請判斷最可能的原因，只能從這六個選一個：競價變貴、追蹤碼失效、素材疲乏、需求或季節變化、其他、資料不足\n',
    '規則：\n',
    '1. 只能根據上面的數字推論，不要假設沒給你的資訊\n',
    '2. 數字不夠下結論時選「資料不足」，不要硬猜\n',
    '3. evidence 用一到兩句繁體中文，引用你判斷時用到的數字\n',
    '4. next_check 寫一件行銷人員接下來應該去確認的事'
  ) AS prompt
FROM f;
