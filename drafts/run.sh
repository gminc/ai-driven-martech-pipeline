#!/usr/bin/env bash
# Day 18：商品事實與禁用詞表 →（確認費用）→ Gemini 替點擊率最低的三張圖打草稿 → 草稿表 → 再跑一次確認不重複收費 → 檢查 → 報表
# 用法：bash drafts/run.sh            （在儲存庫根目錄執行，需先完成 Day 14 物件表、Day 16 特徵表、Day 17 倍數表）
#       AUTO_YES=1 bash drafts/run.sh （跳過確認，排程用）
# 查詢在每月 1 TiB 免費額度內，打草稿會產生 Token 費用，呼叫前會先依「這次真的要呼叫的次數」印出最壞情況
# 影片延伸段是另一支 drafts/veo.sh，這支不會呼叫 Veo
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
EXPECTED=12   # 3 張圖 × 2 版題目 × 各 2 次

ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE}" ]]; then
  echo "❌ gcloud 沒有 active account，bq 會安靜地回傳空結果，請先 gcloud config set account <帳號>"
  exit 1
fi
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "❌ 尚未設定專案，請先 gcloud config set project <專案 ID>"
  exit 1
fi
for T in obj_creatives dim_creative mart_creative_features mart_creative_perf mart_creative_lift; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T}，請先完成 Day 14（物件表）、Day 16（特徵表）與 Day 17（成效表、倍數表）"
    exit 1
  }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

# 單一數字的查詢：失敗或拿到的不是數字就停下來，不要當成 0（當成 0 會讓估價確認被跳過）
scalar() {
  local v
  if ! v="$(bq --headless --location=US query --nouse_legacy_sql --quiet --format=csv "$1" 2> "${TMP}/scalar_err" | tail -n 1)"; then
    echo "❌ 查詢失敗：$1" >&2; cat "${TMP}/scalar_err" >&2; exit 1
  fi
  if [[ ! "${v}" =~ ^[0-9]+$ ]]; then
    echo "❌ 預期一個數字，拿到「${v}」：$1" >&2; exit 1
  fi
  echo "${v}"
}
log_exists() {
  bq --headless show --format=none "${PROJECT}:${DATASET}.mm_drafts_log" >/dev/null 2>&1
}
OK_COND="status = '' AND headline IS NOT NULL AND headline != '' AND cta_text IS NOT NULL AND has_person IS NOT NULL AND cited_ratio IS NOT NULL AND cta_position IN ('center', 'bottom_right', 'none') AND dominant_color IN ('warm', 'cool', 'neutral') AND text_density IN ('low', 'high') AND cited_feature IN ('person', 'cta', 'warm', 'text')"
TARGETS="SELECT creative_id FROM ${DATASET}.mart_creative_perf WHERE audience = 'prospecting' QUALIFY ROW_NUMBER() OVER (ORDER BY ctr, creative_id) <= 3"
pending() {  # 這次的三張目標圖 × 2 版 × 2 次，扣掉已經成功的組合（目標與成功的定義都和 generate.sql 一樣）
  if ! log_exists; then echo "${EXPECTED}"; return; fi
  scalar "WITH t AS (${TARGETS}), c AS (SELECT creative_id, v, s FROM t CROSS JOIN UNNEST(['free', 'rules']) AS v CROSS JOIN UNNEST([1, 2]) AS s), d AS (SELECT DISTINCT creative_id, version, sample FROM ${DATASET}.mm_drafts_log WHERE ${OK_COND}) SELECT COUNT(*) FROM c LEFT JOIN d ON d.creative_id = c.creative_id AND d.version = c.v AND d.sample = c.s WHERE d.creative_id IS NULL"
}
log_rows() {
  if log_exists; then scalar "SELECT COUNT(*) FROM ${DATASET}.mm_drafts_log"; else echo 0; fi
}

echo "📚 商品事實與不能寫的詞（facts.sql）"
run_sql facts.sql --format=pretty

P="$(pending)"
[[ "${P}" =~ ^[0-9]+$ ]] || { echo "❌ 算不出這次要呼叫幾次（拿到「${P}」），先停下來，沒有呼叫 Gemini"; exit 1; }
# 最壞情況：每次輸入以 2,600 個 Token 計（一張圖約 1,100、題目與倍數表約 1,000，留兩成餘裕，這一項是估計值），
# 輸出以 max_output_tokens 4,096 計（思考 Token 也算在裡面，這一項是上限），單價用 gemini-3.6-flash 非 global 端點
python3 - "${P}" <<'PYCOST'
import sys
n = int(sys.argv[1])
fx = 32
cost = n * (2600 * 0.825 + 4096 * 4.125) / 1e6
print(f"💰 這次要呼叫 Gemini {n} 次（3 張圖 × 2 版題目 × 各 2 次，已經成功過的組合不再呼叫）")
print(f"   最壞情況約 US$ {cost:.4f} ≈ 新台幣 {cost * fx:.2f} 元（輸入以 2,600、輸出含思考以 4,096 Token 計）")
PYCOST
if [[ "${AUTO_YES:-0}" != "1" && "${P}" -gt 0 ]]; then
  read -r -p "要呼叫 Gemini 打草稿嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini"; exit 0; }
fi

echo "✍️  第一次執行：Gemini 看圖打草稿（generate.sql）"
run_sql generate.sql --format=pretty

echo "🧱 建草稿表（mart.sql）"
run_sql mart.sql --format=pretty

# 同一段 SQL 再跑一次：成功過的組合不會再呼叫，只補第一次失敗的
MISSING="$(pending)"
[[ "${MISSING}" =~ ^[0-9]+$ ]] || { echo "❌ 算不出還沒成功的有幾個（拿到「${MISSING}」），先停下來"; exit 1; }
BEFORE="$(log_rows)"
echo "🔁 第二次執行 generate.sql：還沒成功的有 ${MISSING} 個，成功過的不應該再呼叫"
if [[ "${MISSING}" -gt 0 && "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "第一次有 ${MISSING} 個沒成功，第二次會再呼叫這些，每次最多約新台幣 0.61 元，輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已停在這裡，第二次沒有執行，之後再跑 run.sh 會只補沒成功的"; exit 0; }
fi
run_sql generate.sql --format=pretty
AFTER="$(log_rows)"
RERUN_CALLS="$(( AFTER - BEFORE ))"
echo "   第二次執行呼叫了 ${RERUN_CALLS} 次"
if [[ "${RERUN_CALLS}" -gt 0 ]]; then
  run_sql mart.sql --format=none >/dev/null
fi

echo "🧾 檢查（check.sql ＋ 兩項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# 打草稿的 SQL 不能讀答案資料集，raw_creatives 也還留著設計規格，一樣不能讀
LEAK="$(for F in facts.sql generate.sql mart.sql check.sql report.sql; do grep -vE '^\s*--' "$F" | grep -iE 'martech_gt|gt_|raw_|gs://|EXECUTE' >/dev/null && printf '%s ' "$F"; done || true)"
python3 - "${TMP}/check.csv" "${LEAK}" "${MISSING}" "${RERUN_CALLS}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
leak, missing, rerun = sys.argv[2].strip(), int(sys.argv[3]), int(sys.argv[4])
rows.append({"check_name": "12 rerun calls = still missing", "expected": str(missing),
             "actual": str(rerun), "ok": "OK" if rerun == missing else "DIFF"})
rows.append({"check_name": "13 no answer table in drafts SQL", "expected": "none",
             "actual": leak or "none", "ok": "OK" if not leak else "DIFF"})
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<42} {r['expected']:>7}  {r['actual']:>7}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

echo "📊 報表（report.sql）"
run_sql report.sql --format=pretty --max_rows=100

echo "✅ Day 18 完成：草稿在 ${DATASET}.mart_creative_drafts，呼叫紀錄在 ${DATASET}.mm_drafts_log，Token 用量在 ${DATASET}.ops_llm_usage"
echo "   影片延伸段：bash drafts/veo.sh（另外確認費用）"
