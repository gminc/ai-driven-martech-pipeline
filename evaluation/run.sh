#!/usr/bin/env bash
# Day 24：拿預先藏好的標準答案考助理，三種評分方式（規則、人、評分模型）放在一起比
# 用法（在儲存庫根目錄執行，需先完成 Day 21 agent/）：
#   bash evaluation/run.sh answers   8 個問題在有工具、沒有工具各問一次 → 規則評分 → 匯出給人評分的表（會花錢）
#   bash evaluation/run.sh human     把填好的 evaluation/human_labels.csv 寫進評分表（不花錢）
#   bash evaluation/run.sh judge     請評分模型評分 → 檢查 → 報表（會花錢，要先有人工評分，而且 human_labels.csv 已經 commit）
#   bash evaluation/run.sh report    只跑檢查與報表（不花錢）
#   answers 與 judge 可以加 --dry，只做到估價為止
#   judge 可以加 --one，每個評分模型只試一筆並印出原始回應，確認模型能用、分數讀得到，再跑完整的
# 會花錢的步驟開始前都先印估價，輸入 yes 才會開始，沒有跳過確認的選項，成功過的不會再問
set -euo pipefail

STEP="${1:-}"
DRY="${2:-}"
case "${STEP}" in
  answers|human|judge|report) ;;
  *) echo "用法：bash evaluation/run.sh answers|human|judge|report [--dry]"; exit 1 ;;
esac
case "${STEP}:${DRY}" in
  answers:|answers:--dry|human:|judge:|judge:--dry|judge:--one|report:) ;;
  *) echo "❌ ${STEP} 不接受參數 ${DRY}（answers 可以加 --dry，judge 可以加 --dry 或 --one）"; exit 1 ;;
esac

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
python3 -c "from google import genai; from google.cloud import bigquery; import google.auth.transport.requests" 2>/dev/null || {
  echo "❌ 缺少 Python 套件，請先 pip install --user google-genai google-cloud-bigquery requests"
  exit 1
}

# 題目、標準答案、評分規則、評分標準都在 eval_run.py，助理的工具在 agent/
# 有未 commit 的修改就停下來：看完回答再改題目或標準答案，分數就不能信了
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ 這裡不是 git 儲存庫，沒辦法確認題目在問之前就定下來了，請在 clone 下來的儲存庫裡執行"
  exit 1
fi
if [[ -n "$(git status --porcelain -- eval_run.py ../agent/ask.py ../agent/tools.py)" ]]; then
  echo "❌ evaluation/eval_run.py、agent/ask.py 或 agent/tools.py 有未 commit 的修改（或還沒 commit 過），先 commit 再執行"
  exit 1
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

case "${STEP}" in
  answers)
    echo "🤖 問問題（eval_run.py answers）"
    python3 eval_run.py answers ${DRY}
    if [[ -n "${DRY}" ]]; then exit 0; fi
    echo "📏 規則評分（eval_run.py rules）"
    python3 eval_run.py rules
    echo "📄 匯出給人評分的表（eval_run.py export）"
    python3 eval_run.py export
    echo "➡️  下一步：讀 evaluation/answers_to_label.md，把分數填進 evaluation/human_labels.csv，執行 bash evaluation/run.sh human，再把這兩個檔案 commit"
    exit 0
    ;;
  human)
    echo "🧑 寫入人工評分（eval_run.py human）"
    python3 eval_run.py human
    echo "➡️  下一步：commit evaluation/human_labels.csv 與 answers_to_label.md，再執行 bash evaluation/run.sh judge --one"
    exit 0
    ;;
  judge)
    # 人的分數要在評分模型開始之前 commit，commit 的時間就是「人先評完」的證據
    if [[ ! -f human_labels.csv || -n "$(git status --porcelain -- human_labels.csv)" ]]; then
      echo "❌ evaluation/human_labels.csv 還沒有 commit（或 commit 之後又改過），先 commit 再請評分模型評分"
      exit 1
    fi
    echo "⚖️  評分模型評分（eval_run.py judge）"
    python3 eval_run.py judge ${DRY}
    if [[ -n "${DRY}" ]]; then exit 0; fi
    ;;
esac

echo "🧾 檢查（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
CHECK_RC=0
python3 - "${TMP}/check.csv" <<'PYCHECK' || CHECK_RC=$?
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if len(rows) != 12:
    print(f"❌ check.sql 應該回 12 項，拿到 {len(rows)} 項")
    sys.exit(1)
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<46} {r['expected']:>6}  {r['actual']:>6}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

# 檢查沒過也把報表印出來，最後再用檢查的結果當結束碼
echo "📊 報表（report.sql）"
run_sql report.sql --format=pretty --max_rows=200

if [[ "${CHECK_RC}" != "0" ]]; then
  echo "❌ Day 24 有檢查沒通過，結果先不要拿來用"
  exit 1
fi
echo "✅ Day 24 完成：回答在 ${DATASET}.eval_answers，三種評分在 ${DATASET}.eval_scores，呼叫紀錄在 ${DATASET}.eval_calls_log，Token 用量在 ${DATASET}.ops_llm_usage"
