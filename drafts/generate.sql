-- Day 18：讓 Gemini 看圖，再根據 Day 17 的成效倍數替點擊率最低的圖打下一版素材草稿
-- 對象：新客受眾（prospecting）裡點擊率最低的三張圖（再行銷受眾本來就比較會點，放在一起比會一直挑到新客的圖）
-- 每張圖跑兩版題目 × 各兩次：
--   free  ：給商品事實、這張圖的現況與倍數表，請它寫出最有說服力的文案，沒有寫品牌規則
--   rules ：題目和 free 完全一樣（包含「最有說服力」那句），只在最後多加四條品牌規則
-- 兩版只差規則，草稿裡冒出幾個不能寫的詞、引用的倍數對不對、有沒有承諾轉換，差別就是規則造成的
--
-- 寫法沿用 Day 15、16：AI.GENERATE 搭配 response_schema（enum 把按鈕位置、主色、文字量、引用的特徵鎖在選項裡）規定草稿欄位，
-- 跑過的不重跑（只補還沒成功的組合），
-- 每次呼叫都記進 mm_drafts_log，再抄一份進共用的 Token 用量表 ops_llm_usage（Day 25 用）
-- 模型用 gemini-3.6-flash（一般任務，要寫文案和構圖，比看圖分類需要多一點推理），thinking_level 設 LOW，
-- 思考 Token 也算在 max_output_tokens 裡，上限放寬到 4,096，避免回答寫到一半被截斷（截斷也會收費）
-- 這一步會產生 Token 費用，run.sh 會先印出最壞情況再問要不要繼續
-- 只讀 martech_dw（倍數表、特徵表、成效表、物件表、商品事實），不讀答案表，run.sh 會用 grep 確認

DECLARE this_run STRING DEFAULT GENERATE_UUID();

-- 倍數表變成題目裡的一段文字，數字取到小數兩位，區間包含 1 的會註明「看不出差別」
DECLARE lift_text STRING DEFAULT (
  SELECT STRING_AGG(
    FORMAT('%s：點擊率 %.2f 倍，轉換率 %.2f 倍（95%% 信賴區間 %.2f–%.2f%s）',
      CASE attr WHEN 'person' THEN 'person 畫面有真人'
                WHEN 'cta' THEN 'cta 按鈕放在右下角'
                WHEN 'warm' THEN 'warm 主色是暖色'
                WHEN 'text' THEN 'text 標題之外還有賣點或標籤' END,
      ROUND(ctr, 2), ROUND(cvr, 2), ROUND(lo, 2), ROUND(hi, 2),
      IF(ROUND(lo, 2) <= 1 AND ROUND(hi, 2) >= 1, '，區間包含 1，看不出差別', '')),
    '\n' ORDER BY ctr DESC)
  FROM (
    SELECT attr,
      MAX(IF(metric = 'ctr', stratified, NULL)) AS ctr,
      MAX(IF(metric = 'cvr', stratified, NULL)) AS cvr,
      MAX(IF(metric = 'cvr', ci95_low, NULL)) AS lo,
      MAX(IF(metric = 'cvr', ci95_high, NULL)) AS hi
    FROM martech_dw.mart_creative_lift
    GROUP BY attr
  )
);

DECLARE rules_text STRING DEFAULT '''寫的時候請遵守下面四條規則：
1. 只寫上面商品資料裡有的事實，不寫抗菌、除臭、防蹣、醫療、療效這類功效，也不寫「最好」「第一名」「保證」這類絕對用語
2. cited_ratio 照上面表格裡的點擊率倍數抄，不要自己換算或四捨五入成別的數字
3. 轉換率區間包含 1 的特徵，不能說改版會讓轉換率、成交或銷售增加，expected_effect 只能談點擊率
4. headline 14 個字以內，subhead 20 個字以內''';

DECLARE free_text STRING DEFAULT '請盡量發揮創意，寫出最能打動人、最有說服力的文案，可以多強調商品的機能和使用效果。';

-- 呼叫紀錄：每一次呼叫一列，成功失敗都留著
CREATE TABLE IF NOT EXISTS martech_dw.mm_drafts_log (
  run_id          STRING,
  version         STRING,
  sample          INT64,
  creative_id     STRING,
  model           STRING,
  headline        STRING,
  subhead         STRING,
  badge           STRING,
  cta_text        STRING,
  cta_position    STRING,
  has_person      BOOL,
  dominant_color  STRING,
  text_density    STRING,
  composition     STRING,
  image_prompt    STRING,
  changes         STRING,
  cited_feature   STRING,
  cited_ratio     FLOAT64,
  expected_effect STRING,
  prompt_tokens   INT64,
  output_tokens   INT64,
  thoughts_tokens INT64,
  finish_reason   STRING,
  status          STRING,
  created_at      TIMESTAMP
)
OPTIONS (description = 'Day 18 草稿呼叫紀錄：一列＝一次呼叫（圖 × 題目版本 × 第幾次），成功失敗都保留，generate.sql 只補沒有成功紀錄的組合');
ALTER TABLE martech_dw.mm_drafts_log ADD COLUMN IF NOT EXISTS finish_reason STRING;  -- 萬一舊版的表已經建過
-- 鎖法：第一次試跑用 output_schema（只鎖型別），rules 版 6 次有 3 次不合格（推理過程寫進 text_density 欄位、或寫到一半被截斷），
-- 改用 response_schema 的 enum 把選項也鎖住，兩版都重跑，舊的紀錄留著（method 是空的那幾筆），成功的定義只看 response_schema
ALTER TABLE martech_dw.mm_drafts_log ADD COLUMN IF NOT EXISTS method STRING;

-- 共用的 Token 用量表（Day 16 建立，這裡 IF NOT EXISTS 只是保險）
CREATE TABLE IF NOT EXISTS martech_dw.ops_llm_usage (
  logged_at TIMESTAMP,
  day STRING,
  job STRING,
  run_id STRING,
  model STRING,
  endpoint_type STRING,
  media_resolution STRING,
  item_id STRING,
  prompt_tokens INT64,
  output_tokens INT64,
  status STRING
)
PARTITION BY DATE(logged_at)
OPTIONS (description = '共用 Gemini Token 用量表：一列＝一次呼叫，Day 16 起累積，Day 25 監控與成本用，單價不存在這裡，計費時再依 model 與 endpoint_type 對照');

-- 對象：新客受眾裡點擊率最低的三張圖，現況用 Day 16 AI 讀出來的特徵（不用設計規格）
CREATE TEMP TABLE targets AS
SELECT p.creative_id, p.channel, p.ctr,
  f.has_person, f.cta_position, f.dominant_color, f.text_density, f.headline AS old_headline,
  d.product_focus
FROM martech_dw.mart_creative_perf p
JOIN martech_dw.mart_creative_features f USING (creative_id)
JOIN martech_dw.dim_creative d USING (creative_id)
WHERE p.audience = 'prospecting'
QUALIFY ROW_NUMBER() OVER (ORDER BY p.ctr, p.creative_id) <= 3;

-- 「成功」的定義（generate、mart、check 與 run.sh 都用同一條）：status 是空字串，標題、按鈕、人物、引用的倍數都有值，
-- 而且按鈕位置、主色、文字量、引用的特徵都在選項裡（不在選項裡的算失敗，第二次執行會補）
CREATE TEMP TABLE done AS
SELECT DISTINCT creative_id, version, sample
FROM martech_dw.mm_drafts_log
WHERE status = '' AND headline IS NOT NULL AND headline != '' AND cta_text IS NOT NULL
  AND has_person IS NOT NULL AND cited_ratio IS NOT NULL
  AND cta_position IN ('center', 'bottom_right', 'none') AND dominant_color IN ('warm', 'cool', 'neutral')
  AND text_density IN ('low', 'high') AND cited_feature IN ('person', 'cta', 'warm', 'text')
  AND method = 'response_schema';

CREATE TEMP TABLE todo AS
SELECT t.*, v AS version, s AS sample,
  CONCAT(
    '你是電商廣告的創意總監，品牌是台灣織品品牌「織日常」。附上的圖是目前正在投放的廣告圖，請看圖之後替它打下一版素材草稿。\n\n',
    '商品資料：', pf.name, '（', pf.subtitle, '）。', pf.summary, pf.story, '材質：', pf.material, '。產地：', pf.made_in, '。\n\n',
    FORMAT('這張圖投放在 %s 的新客受眾，點擊率 %.2f%%，是新客受眾裡點擊率最低的三張之一。', t.channel, t.ctr * 100),
    FORMAT('另一個模型看過這張圖：畫面%s真人，按鈕位置 %s，主色 %s，文字量 %s，標題是「%s」。\n\n',
      IF(t.has_person, '有', '沒有'), t.cta_position, t.dominant_color, t.text_density, t.old_headline),
    '我們用 23 張廣告圖算過下面四個設計特徵的效果（同通路、同受眾裡，有這個特徵的圖相對沒有的圖）：\n',
    lift_text, '\n\n',
    '''請交出下面這些欄位：
headline：新標題
subhead：一行副標
badge：圓形標籤上的字，不放標籤就填空字串
cta_text：按鈕上的字
cta_position：按鈕位置，只能填 center、bottom_right、none 其中一個
has_person：畫面要不要有真人，true 或 false
dominant_color：主色調，只能填 warm、cool、neutral 其中一個
text_density：標題之外有沒有賣點文字或標籤，沒有填 low，有填 high
composition：構圖說明，一到兩句
image_prompt：給生圖或生影片模型用的英文畫面描述，不要出現任何文字、品牌名稱或商標
changes：和原圖比改了哪些地方
cited_feature：這版草稿最主要依據上面哪一個特徵，只能填 person、cta、warm、text 其中一個
cited_ratio：那個特徵的倍數
expected_effect：預期效果，一句話

''',
    IF(v = 'rules', CONCAT(free_text, '\n\n', rules_text), free_text)
  ) AS prompt
FROM targets t
JOIN martech_dw.ref_product_facts pf ON pf.item_id = t.product_focus
CROSS JOIN UNNEST(['free', 'rules']) AS v
CROSS JOIN UNNEST([1, 2]) AS s
LEFT JOIN done dn ON dn.creative_id = t.creative_id AND dn.version = v AND dn.sample = s
WHERE dn.creative_id IS NULL;

INSERT INTO martech_dw.mm_drafts_log (run_id, version, sample, creative_id, model, headline, subhead, badge, cta_text,
  cta_position, has_person, dominant_color, text_density, composition, image_prompt, changes, cited_feature, cited_ratio,
  expected_effect, prompt_tokens, output_tokens, thoughts_tokens, finish_reason, status, created_at, method)
SELECT this_run, version, sample, creative_id, 'gemini-3.6-flash',
  JSON_VALUE(g.result, '$.headline'), JSON_VALUE(g.result, '$.subhead'), JSON_VALUE(g.result, '$.badge'),
  JSON_VALUE(g.result, '$.cta_text'), JSON_VALUE(g.result, '$.cta_position'),
  SAFE_CAST(JSON_VALUE(g.result, '$.has_person') AS BOOL),
  JSON_VALUE(g.result, '$.dominant_color'), JSON_VALUE(g.result, '$.text_density'),
  JSON_VALUE(g.result, '$.composition'), JSON_VALUE(g.result, '$.image_prompt'), JSON_VALUE(g.result, '$.changes'),
  JSON_VALUE(g.result, '$.cited_feature'), SAFE_CAST(JSON_VALUE(g.result, '$.cited_ratio') AS FLOAT64),
  JSON_VALUE(g.result, '$.expected_effect'),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.prompt_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.candidates_token_count') AS INT64),
  CAST(JSON_VALUE(g.full_response, '$.usage_metadata.thoughts_token_count') AS INT64),
  JSON_VALUE(g.full_response, '$.candidates[0].finish_reason'),  -- MAX_TOKENS 表示被輸出上限截斷
  g.status, CURRENT_TIMESTAMP(), 'response_schema'
FROM (
  SELECT t.creative_id, t.version, t.sample,
    AI.GENERATE(
      (t.prompt, o.ref),
      connection_id => 'us.vertex_ai_conn',
      endpoint => 'gemini-3.6-flash',
      model_params => JSON '''{"generation_config": {
        "max_output_tokens": 4096,
        "thinking_config": {"thinking_level": "LOW"},
        "response_mime_type": "application/json",
        "response_schema": {"type": "OBJECT", "properties": {
          "headline": {"type": "STRING"},
          "subhead": {"type": "STRING"},
          "badge": {"type": "STRING"},
          "cta_text": {"type": "STRING"},
          "cta_position": {"type": "STRING", "enum": ["center", "bottom_right", "none"]},
          "has_person": {"type": "BOOLEAN"},
          "dominant_color": {"type": "STRING", "enum": ["warm", "cool", "neutral"]},
          "text_density": {"type": "STRING", "enum": ["low", "high"]},
          "composition": {"type": "STRING"},
          "image_prompt": {"type": "STRING"},
          "changes": {"type": "STRING"},
          "cited_feature": {"type": "STRING", "enum": ["person", "cta", "warm", "text"]},
          "cited_ratio": {"type": "NUMBER"},
          "expected_effect": {"type": "STRING"}
        }, "required": ["headline", "subhead", "badge", "cta_text", "cta_position", "has_person", "dominant_color",
                        "text_density", "composition", "image_prompt", "changes", "cited_feature", "cited_ratio", "expected_effect"]}
      }}'''
    ) AS g
  FROM todo t
  JOIN martech_dw.obj_creatives o ON o.uri LIKE CONCAT('%/', t.creative_id, '.jpg')
);

-- 抄一份進共用用量表：思考 Token 也按輸出計費，所以 output_tokens 存「輸出＋思考」
-- 抄所有還沒抄過的執行，萬一上一次中途出錯沒抄到，這一次會補上
INSERT INTO martech_dw.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
SELECT created_at, 'Day 18', 'drafts/generate.sql', run_id, model, 'non-global', 'default',
  CONCAT(creative_id, '/', version, '/', CAST(sample AS STRING)),
  prompt_tokens, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0), status
FROM martech_dw.mm_drafts_log
WHERE run_id NOT IN (
  SELECT DISTINCT run_id FROM martech_dw.ops_llm_usage
  WHERE job = 'drafts/generate.sql' AND run_id IS NOT NULL
);

-- 這次執行呼叫了幾次（第二次執行時，成功過的組合不會再呼叫）
SELECT run_id, version,
  COUNT(*) AS calls,
  COUNTIF(status = '') AS ok,
  COUNTIF(status != '') AS failed,
  SUM(prompt_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  SUM(thoughts_tokens) AS thoughts_tokens
FROM martech_dw.mm_drafts_log
WHERE run_id = this_run
GROUP BY 1, 2
ORDER BY 2;
