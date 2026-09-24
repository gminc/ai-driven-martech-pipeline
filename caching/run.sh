#!/usr/bin/env bash
# Day 10：組固定內容 → 數 Token 估費用 → 確認後建明確快取 → 三種做法各跑三輪 → 刪快取 → 檢查 → 印對照表
# 用法：bash caching/run.sh             （在儲存庫根目錄執行，需先完成 Day 09 的 diagnosis/run.sh）
#       AUTO_YES=1 bash caching/run.sh  （跳過確認，排程用）
# 會呼叫 Gemini 36 次（3 種做法 × 3 輪 × 4 題），實測約新台幣 2 元；明確快取只活到腳本結束（最多 30 分鐘）
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"

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
bq --headless show --format=none "${PROJECT}:${DATASET}.diag_prompt" >/dev/null 2>&1 || {
  echo "❌ 找不到 ${DATASET}.diag_prompt，請先執行 Day 09 的 diagnosis/summary.sql 與 diagnosis/prompt.sql（只跑 SQL，不會呼叫 Gemini）"
  exit 1
}
bq --headless show --format=none --connection "${PROJECT}.us.vertex_ai_conn" >/dev/null 2>&1 || {
  echo "❌ 找不到連線 us.vertex_ai_conn，請先完成 Day 03 的 Terraform"
  exit 1
}

TMP="$(mktemp -d)"
cleanup() {
  # 不管腳本是正常結束還是中途出錯，都把快取刪掉，免得一直收儲存費
  # 訊息一律寫到 stderr：run_sql 失敗時 stdout 可能正被導向 /dev/null
  if [[ -f .cache_name ]]; then
    echo "🧹 刪除明確快取" >&2
    DATASET="${DATASET}" bash cache.sh delete >&2 || echo "⚠️ 快取刪除失敗，請手動執行 bash caching/cache.sh list 檢查" >&2
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s#PROJECT_ID#${PROJECT}#g" -e "s#CACHE_NAME#${CACHE_NAME:-CACHE_NAME}#g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "🧱 組固定內容（context.sql）"
run_sql context.sql > /dev/null

echo "💰 呼叫前先數 Token（cost.sql，最壞情況，新台幣）"
run_sql cost.sql --format=pretty

if [[ "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "要建立明確快取並呼叫 Gemini 36 次嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini"; exit 0; }
fi

echo "📦 建立明確快取（cache.sh create，存活 30 分鐘）"
T0="$(date +%s)"
DATASET="${DATASET}" bash cache.sh create
CACHE_NAME="$(cat .cache_name)"

echo "🤖 三種做法各跑三輪（experiment.sql）"
run_sql experiment.sql > /dev/null

DATASET="${DATASET}" bash cache.sh delete
T1="$(date +%s)"

echo "🧾 檢查結果（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
python3 - "${TMP}/check.csv" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    print(f"  {flag} {r['check_name']:<34} {r['expected']:>7}  {r['actual']:>7}")
bad = sum(r["ok"] != "OK" for r in rows)
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
if len(rows) != 16:
    print(f"❌ 檢查項目應該有 16 項，實際只有 {len(rows)} 項，代表有某種做法整批沒有寫進 cache_runs")
sys.exit(1 if bad or len(rows) != 16 else 0)
PYCHECK

echo "📊 三種做法對照（report.sql）"
python3 - report.sql "${TMP}" <<'PYSPLIT'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
parts = [p.strip() for p in re.split(r";\s*\n", text) if re.search(r"(?im)^\s*(WITH|SELECT)", p)]
for i, p in enumerate(parts, 1):
    open(f"{sys.argv[2]}/report_{i}.sql", "w", encoding="utf-8").write(p + "\n")
PYSPLIT
for f in "${TMP}"/report_*.sql; do
  grep -m1 '^-- [①②③]' "${f}" || true
  run_sql "${f}" --format=pretty --max_rows=100
  echo
done

run_sql cost.sql --format=csv > "${TMP}/cost.csv"
python3 - "${TMP}/cost.csv" "${T0}" "${T1}" <<'PYEXTRA'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
ctx = int(rows[0]["context_tokens"])
minutes = (int(sys.argv[3]) - int(sys.argv[2])) / 60
create = ctx * 0.30 / 1e6 * 32
storage = ctx * 1.00 * minutes / 60 / 1e6 * 32
print(f"明確快取額外成本：建立 NT$ {create:.3f}＋儲存 {minutes:.1f} 分鐘 NT$ {storage:.3f}＝NT$ {create + storage:.3f}")
PYEXTRA
