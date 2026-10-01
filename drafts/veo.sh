#!/usr/bin/env bash
# Day 18 延伸段：把一份草稿的畫面描述交給 Vertex AI 的 Veo，渲染一支 4 秒短片
# 用法：bash drafts/veo.sh   （先跑完 bash drafts/run.sh，草稿表要有資料）
# 只發一次請求：4 秒、720p、不要音軌、只生一支，輸出寫到素材 bucket 的 veo/ 資料夾
# 同一份草稿已經有影片就不再呼叫，重跑不會重複收費
# 這一步會產生費用，呼叫前會印出最壞情況再問要不要繼續
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
REGION="${REGION:-us-central1}"
MODEL="${VEO_MODEL:-veo-3.1-lite-generate-001}"
SECONDS_LEN=4

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "❌ 尚未設定專案，請先 gcloud config set project <專案 ID>"
  exit 1
fi
bq --headless show --format=none "${PROJECT}:${DATASET}.mart_creative_drafts" >/dev/null 2>&1 || {
  echo "❌ 找不到 ${DATASET}.mart_creative_drafts，請先執行 bash drafts/run.sh"
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# 挑哪一份：有品牌規則那一版、點擊率最低那張圖、第 1 次的草稿
bq --headless --location=US query --nouse_legacy_sql --quiet --format=json "
SELECT d.creative_id, d.version, d.sample, d.headline, d.image_prompt
FROM ${DATASET}.mart_creative_drafts d
JOIN ${DATASET}.mart_creative_perf p USING (creative_id)
WHERE d.version = 'rules' AND d.sample = 1 AND IFNULL(d.image_prompt, '') != ''
ORDER BY p.ctr, d.creative_id
LIMIT 1" > "${TMP}/draft.json"

PICK="$(python3 - "${TMP}/draft.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
if not rows:
    print("NONE -"); sys.exit(0)
r = rows[0]
print(f"{r['creative_id']}-{r['version']}-{r['sample']} {r['headline']}")
PY
)"
DRAFT_ID="${PICK%% *}"
HEADLINE="${PICK#* }"
if [[ "${DRAFT_ID}" == "NONE" || -z "${DRAFT_ID}" ]]; then
  echo "❌ 草稿表裡沒有可用的畫面描述（rules 版第 1 次），請先確認 drafts/run.sh 跑完"
  exit 1
fi

OUT="gs://${PROJECT}-martech-assets/veo/${DRAFT_ID}/"
echo "🎬 草稿：${DRAFT_ID}（標題「${HEADLINE}」）"
if gcloud storage ls "${OUT}**.mp4" >/dev/null 2>&1; then
  echo "✅ 這份草稿已經有影片，不再呼叫 Veo："
  gcloud storage ls "${OUT}**.mp4"
  exit 0
fi
# 上一次送出後如果中斷（逾時、Ctrl+C、網路斷線），operation 名稱留在 op.txt，這次接著查進度，不重新送出
OP=""
# 上一次的請求失敗時，op.txt 會被改寫成 FAILED 開頭，這次就重新送出（照樣會先問）
if gcloud storage cat "${OUT}op.txt" > "${TMP}/op.txt" 2>/dev/null; then
  OP="$(tr -d '[:space:]' < "${TMP}/op.txt")"
  if [[ "${OP}" == FAILED* ]]; then
    echo "↩️  上一次的請求失敗了（${OP#FAILED}），這次重新送出"
    OP=""
  else
    echo "↩️  上一次已經送出過（${OP##*/}），這次只查進度，不會再收費"
  fi
fi

if [[ -z "${OP}" ]]; then
  # 最壞情況：Vertex 官方定價頁目前沒有列 Veo 3.1 Lite，以官方頁上 Veo 3 Fast 不含音軌每秒 US$ 0.10 估
  # （第三方整理的 Lite 價格約每秒 US$ 0.03–0.05），只有回傳成功的請求才收費
  python3 - "${SECONDS_LEN}" <<'PYCOST'
import sys
s = int(sys.argv[1])
worst = s * 0.10
print(f"💰 會呼叫 Veo 1 次，產生 1 支 {s} 秒、720p、不含音軌的短片")
print(f"   最壞情況約 US$ {worst:.2f} ≈ 新台幣 {worst * 32:.1f} 元（以 Veo 3 Fast 不含音軌每秒 US$ 0.10 估，Lite 應該更便宜）")
PYCOST
  if [[ "${AUTO_YES:-0}" != "1" ]]; then
    read -r -p "要呼叫 Veo 嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
    [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Veo"; exit 0; }
  fi

  # 請求內容：畫面描述來自草稿的 image_prompt（Gemini 寫的英文），補一句鏡頭運動與不要文字
  python3 - "${TMP}/draft.json" "${OUT}" "${SECONDS_LEN}" > "${TMP}/body.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))[0]
prompt = r["image_prompt"].strip().rstrip(".") + ". Slow gentle camera push-in, soft natural light, no text, no logos, no subtitles."
body = {
  "instances": [{"prompt": prompt}],
  "parameters": {
    "durationSeconds": int(sys.argv[3]),
    "sampleCount": 1,
    "generateAudio": False,
    "resolution": "720p",
    "aspectRatio": "16:9",
    "personGeneration": "allow_adult",
    "storageUri": sys.argv[2],
  },
}
print(json.dumps(body, ensure_ascii=False))
PY
  echo "📝 送出的畫面描述："
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['instances'][0]['prompt'])" "${TMP}/body.json"

  BASE="https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/${REGION}/publishers/google/models/${MODEL}"
  TOKEN="$(gcloud auth print-access-token)"
  HTTP="$(curl -s -o "${TMP}/op.json" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "${BASE}:predictLongRunning" -d @"${TMP}/body.json")"
  if [[ "${HTTP}" != "200" ]]; then
    echo "❌ Veo 請求失敗（HTTP ${HTTP}，失敗的請求不收費）："
    cat "${TMP}/op.json"; exit 1
  fi
  OP="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "${TMP}/op.json")"
  # 先把 operation 名稱存進 bucket，萬一後面中斷，重跑只會接著查進度
  echo "   operation：${OP}"
  printf '%s\n' "${OP}" | gcloud storage cp - "${OUT}op.txt" >/dev/null 2>&1 \
    || echo "⚠️  operation 名稱沒存進 bucket，萬一中斷，請用上面這行 operation 自己查進度，不要直接重跑"
fi
BASE="https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/${REGION}/publishers/google/models/${MODEL}"
echo "⏳ 每 15 秒查一次進度（最多 10 分鐘，逾時的話重跑這支只會接著查，不會重新送出）"

STATUS="timeout"
for i in $(seq 1 40); do
  sleep 15
  TOKEN="$(gcloud auth print-access-token)"
  curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "${BASE}:fetchPredictOperation" -d "{\"operationName\": \"${OP}\"}" > "${TMP}/poll.json"
  # done 為 True 才算結束，回應只有 error、沒有 done（例如 operation 已過期）也當成結束，不要空等
  DONE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(bool(d.get('done')) or ('error' in d and 'done' not in d))" "${TMP}/poll.json" 2>/dev/null || echo False)"
  if [[ "${DONE}" == "True" ]]; then
    STATUS="$(python3 - "${TMP}/poll.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if "error" in d:
  print("error:" + d["error"].get("message", "")[:200].replace("\n", " "))
else:
  vids = d.get("response", {}).get("videos", [])
  print("ok" if vids else "no_video:" + json.dumps(d.get("response", {}))[:200])
PY
)"
    break
  fi
  echo "   第 ${i} 次：還在產生"
done
echo "結果：${STATUS}"
CODE="${STATUS%%:*}"
[[ "${CODE}" == "ok" ]] && CODE=""
cp "${TMP}/poll.json" "${HOME}/day18_veo_response.json" 2>/dev/null || true

if [[ "${STATUS}" == "timeout" ]]; then
  echo "⏳ 10 分鐘還沒好，operation 名稱存在 ${OUT}op.txt，等一下重跑 bash drafts/veo.sh 會接著查，不會再收費"
  exit 1
fi
if [[ "${STATUS}" != "ok" ]]; then
  # 失敗的請求不收費，把 op.txt 改寫成 FAILED 開頭，下次重跑會重新送出
  printf 'FAILED%s\n' "${OP##*/}" | gcloud storage cp - "${OUT}op.txt" >/dev/null 2>&1 || true
fi

# 記進共用用量表（只在有最終結果時寫一列），Veo 不是用 Token 計費，Token 欄位留空，item_id 記草稿、media_resolution 記解析度與秒數
# endpoint_type 和其他列一樣記 non-global（us-central1 區域端點），2026-10-01 第一次執行時這一欄記成 us-central1
bq --headless --location=US query --nouse_legacy_sql --quiet --format=none "
INSERT INTO ${DATASET}.ops_llm_usage (logged_at, day, job, run_id, model, endpoint_type, media_resolution, item_id, prompt_tokens, output_tokens, status)
VALUES (CURRENT_TIMESTAMP(), 'Day 18', 'drafts/veo.sh', '${OP##*/}', '${MODEL}', 'non-global', '720p/${SECONDS_LEN}s', '${DRAFT_ID}', NULL, NULL, '${CODE}')"

if [[ "${STATUS}" != "ok" ]]; then
  echo "❌ 沒有拿到影片（失敗的請求不收費），回應存在 ~/day18_veo_response.json，重跑會重新送出"
  exit 1
fi
echo "✅ 影片："
gcloud storage ls "${OUT}**.mp4"
