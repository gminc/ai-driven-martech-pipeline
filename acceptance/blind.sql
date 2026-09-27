-- Day 13：AI 盲測，把整季週報交給 Gemini，不挑異常、不給候選原因，看它自己找得出幾個
-- 兩個模型各問三次（同一份題目），看回答穩不穩定；結果落成 martech_dw.blind_result（原始回答）與 blind_findings（拆開的每一項發現）
-- 回傳格式用 response_schema 鎖成 JSON：findings 陣列，每一項有對象、期間、觀察、可能原因、建議確認
-- thinking_budget 設 0：和 Day 09 一樣，思考 token 也算在 max_output_tokens 裡，關掉才好控制費用與長度
-- 這一步會產生 Token 費用，執行前先跑 blind_cost.sql 數 Token；只讀 martech_dw，不讀答案表

-- 遠端模型只是一個「指向 Gemini 的捷徑」，建立本身不收費；Day 09 建過就沿用
CREATE MODEL IF NOT EXISTS martech_dw.gemini_flash_lite
  REMOTE WITH CONNECTION `us.vertex_ai_conn`
  OPTIONS (ENDPOINT = 'gemini-3.5-flash-lite');

CREATE MODEL IF NOT EXISTS martech_dw.gemini_flash
  REMOTE WITH CONNECTION `us.vertex_ai_conn`
  OPTIONS (ENDPOINT = 'gemini-3.6-flash');

-- 主跑：gemini-3.5-flash-lite × 3
CREATE OR REPLACE TABLE martech_dw.blind_result
OPTIONS (description = 'Day 13 AI 盲測原始回答：只給整季週報、不給候選原因，一列＝一個模型 × 一次呼叫')
AS
SELECT
  run_no,
  'gemini-3.5-flash-lite' AS model,
  result AS raw_result,
  statistics,
  status,
  CURRENT_TIMESTAMP() AS created_at
FROM AI.GENERATE_TEXT(
  MODEL martech_dw.gemini_flash_lite,
  (SELECT run_no, prompt FROM martech_dw.blind_prompt),
  STRUCT(
    '''{
      "generation_config": {
        "max_output_tokens": 4096,
        "thinking_config": {"thinking_budget": 0},
        "response_mime_type": "application/json",
        "response_schema": {
          "type": "OBJECT",
          "properties": {
            "findings": {
              "type": "ARRAY",
              "items": {
                "type": "OBJECT",
                "properties": {
                  "target": {"type": "STRING"},
                  "period": {"type": "STRING"},
                  "observation": {"type": "STRING"},
                  "likely_cause": {"type": "STRING"},
                  "next_check": {"type": "STRING"}
                },
                "required": ["target", "period", "observation", "likely_cause", "next_check"]
              }
            }
          },
          "required": ["findings"]
        }
      }
    }''' AS model_params
  )
);

-- 對照：同一份題目交給 gemini-3.6-flash × 3
INSERT INTO martech_dw.blind_result
SELECT
  run_no,
  'gemini-3.6-flash',
  result, statistics, status, CURRENT_TIMESTAMP()
FROM AI.GENERATE_TEXT(
  MODEL martech_dw.gemini_flash,
  (SELECT run_no, prompt FROM martech_dw.blind_prompt),
  STRUCT(
    '''{
      "generation_config": {
        "max_output_tokens": 4096,
        "thinking_config": {"thinking_budget": 0},
        "response_mime_type": "application/json",
        "response_schema": {
          "type": "OBJECT",
          "properties": {
            "findings": {
              "type": "ARRAY",
              "items": {
                "type": "OBJECT",
                "properties": {
                  "target": {"type": "STRING"},
                  "period": {"type": "STRING"},
                  "observation": {"type": "STRING"},
                  "likely_cause": {"type": "STRING"},
                  "next_check": {"type": "STRING"}
                },
                "required": ["target", "period", "observation", "likely_cause", "next_check"]
              }
            }
          },
          "required": ["findings"]
        }
      }
    }''' AS model_params
  )
);

-- 把每一次回答的 findings 陣列拆成一列一項，方便讀、也方便評分
CREATE OR REPLACE TABLE martech_dw.blind_findings
OPTIONS (description = 'Day 13 AI 盲測的每一項發現：一列＝模型 × 第幾次 × 第幾項')
AS
SELECT
  r.model, r.run_no, idx + 1 AS finding_no,
  JSON_VALUE(f, '$.target') AS target,
  JSON_VALUE(f, '$.period') AS period,
  JSON_VALUE(f, '$.observation') AS observation,
  JSON_VALUE(f, '$.likely_cause') AS likely_cause,
  JSON_VALUE(f, '$.next_check') AS next_check
FROM martech_dw.blind_result r,
  UNNEST(JSON_QUERY_ARRAY(SAFE.PARSE_JSON(r.raw_result), '$.findings')) AS f WITH OFFSET AS idx;

SELECT model, run_no, status = '' AS ok,
  SAFE_CAST(JSON_VALUE(statistics, '$.prompt_token_count') AS INT64) AS input_tokens,
  SAFE_CAST(JSON_VALUE(statistics, '$.candidates_token_count') AS INT64) AS output_tokens,
  (SELECT COUNT(*) FROM martech_dw.blind_findings f WHERE f.model = r.model AND f.run_no = r.run_no) AS findings
FROM martech_dw.blind_result r
ORDER BY model, run_no;
