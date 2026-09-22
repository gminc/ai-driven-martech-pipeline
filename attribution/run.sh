#!/usr/bin/env bash
# Day 08：建立 martech_dw.mart_attribution，做功勞守恆檢查，再印出歸因報表
# 用法：bash attribution/run.sh           （在儲存庫根目錄執行，需先完成 Day 07 的 warehouse/build.sh）
# 建表約處理 59 MB（計費約 81 MB，每個陳述式讀到的每張表最低計費 10 MiB），整段計費約 150 MB，在每月 1 TiB 免費額度內
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
for t in fct_events fct_orders; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${t}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${t}，請先完成 Day 07 的 warehouse/build.sh"
    exit 1
  }
done
LOCATION="$(bq --headless show --format=json "${PROJECT}:${DATASET}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["location"])')" || {
  echo "❌ 讀不到 ${DATASET} 的位置"
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  # 結果寫到標準輸出，bq 的警告與錯誤另外收；失敗時兩邊都印出來
  if ! sed "s/martech_dw\./${DATASET}./g" "$1" \
      | bq --headless --location="${LOCATION}" query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "🧭 建立 ${DATASET}.mart_attribution（build.sql）"
run_sql build.sql > /dev/null

echo "🧾 功勞守恆檢查（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
python3 - "${TMP}/check.csv" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
for r in rows:
    flag = {"OK": "✅", "INFO": "ℹ️ "}.get(r["ok"], "❌")
    print(f"  {flag} {r['check_name']:<30} {r['expected']:>12}  {r['actual']:>12}")
bad = sum(r["ok"] == "DIFF" for r in rows)
ok = sum(r["ok"] == "OK" for r in rows)
print(f"\n{ok} 項通過、{bad} 項不通過")
sys.exit(1 if bad or not rows else 0)
PYCHECK

echo "📊 歸因報表（report.sql）"
python3 - report.sql "${TMP}" <<'PYSPLIT'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = "\n".join(l for l in text.splitlines() if not l.startswith("-- Day 08"))
parts = [p.strip() for p in re.split(r";\s*\n", text) if re.search(r"(?im)^\s*SELECT", p)]
for i, p in enumerate(parts, 1):
    open(f"{sys.argv[2]}/report_{i}.sql", "w", encoding="utf-8").write(p + "\n")
PYSPLIT
for f in "${TMP}"/report_*.sql; do
  head -n 1 "${f}"
  run_sql "${f}" --format=pretty --max_rows=100
  echo
done
