#!/usr/bin/env bash
# Day 21：把三個查詢工具交給 Gemini，同一批問題有工具和沒有工具各問一次 → 對答案 → 檢查 → 報表
# 用法：bash agent/run.sh   （在儲存庫根目錄執行，需先完成 Day 08 attribution/、Day 09 diagnosis/、Day 17 lift/）
# 呼叫模型會產生 Token 費用，呼叫前會先印出最壞估價，輸入 yes 才會開始，沒有跳過確認的選項
# 問過而且成功的題目不會再問，重跑不會重複收費
set -euo pipefail

cd "$(dirname "$0")"
export DATASET="${DATASET:-martech_dw}"

ACTIVE="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACTIVE}" ]]; then
  echo "❌ gcloud 沒有 active account，請先 gcloud config set account <帳號>"
  exit 1
fi
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "❌ 尚未設定專案，請先 gcloud config set project <專案 ID>"
  exit 1
fi
export GOOGLE_CLOUD_PROJECT="${PROJECT}"
for T in "mart_attribution:Day 08（bash attribution/run.sh）" "diag_summary:Day 09（bash diagnosis/run.sh）" \
         "mart_diagnosis:Day 09" "mart_creative_lift:Day 17（bash lift/run.sh）" "ops_llm_usage:Day 16（bash features/run.sh）"; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T%%:*}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T%%:*}，請先完成 ${T#*:}"
    exit 1
  }
done
python3 -c "from google import genai; from google.cloud import bigquery" 2>/dev/null || {
  echo "❌ 缺少 Python 套件，請先 pip install --user google-genai google-cloud-bigquery"
  exit 1
}

# 問題、工具定義有未 commit 的修改就停下來：看完結果再改題目或工具說明，就不能說是同一份題目了
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain -- ask.py tools.py)" ]]; then
    echo "❌ agent/ask.py 或 agent/tools.py 有未 commit 的修改（或還沒 commit 過），先 commit 再執行"
    exit 1
  fi
fi

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

echo "🤖 問問題（ask.py）"
python3 ask.py

echo "🧾 檢查（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
CHECK_RC=0
python3 - "${TMP}/check.csv" <<'PYCHECK' || CHECK_RC=$?
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if len(rows) != 10:
    print(f"❌ check.sql 應該回 10 項，拿到 {len(rows)} 項")
    sys.exit(1)
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<42} {r['expected']:>6}  {r['actual']:>6}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

# 檢查沒過也把報表印出來，最後再用檢查的結果當結束碼
echo "📊 報表（report.sql）"
run_sql report.sql --format=pretty --max_rows=200

if [[ "${CHECK_RC}" != "0" ]]; then
  echo "❌ Day 21 有檢查沒通過，結果先不要拿來用"
  exit 1
fi
echo "✅ Day 21 完成：對答案的結果在 ${DATASET}.mart_fc_score，回答在 ${DATASET}.fc_answers，呼叫紀錄在 ${DATASET}.fc_calls_log 與 ${DATASET}.fc_tool_log，Token 用量在 ${DATASET}.ops_llm_usage"
