#!/usr/bin/env bash
# Day 13：判準（先 commit）→ 成績單 → 盲測題目 → 數 Token →（確認）→ 呼叫 Gemini 6 次 → 盲測評分 → 檢查 → 報表
# 用法：bash acceptance/run.sh               （在儲存庫根目錄執行，需先完成 Day 07、08、09、11、12）
#       AUTO_YES=1 bash acceptance/run.sh    （跳過確認，排程用）
# 成績單只讀各篇的結果表，全部在每月 1 TiB 免費額度內；盲測會呼叫 Gemini 6 次（2 個模型 × 3 次），
# 最壞情況（每次都輸出滿 4,096 個 token）約新台幣 7 元，實測見 README；執行到一半會印出 Token 數與估價再問要不要繼續
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
GT="${GT_DATASET:-martech_gt}"

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
for T in "fct_ad_daily Day 07" "fct_events Day 07" "fct_orders Day 07" "dim_product Day 07" \
         "mart_attribution Day 08" "mart_diagnosis Day 09" "mart_customer_ltv Day 12"; do
  set -- ${T}
  bq --headless show --format=none "${PROJECT}:${DATASET}.$1" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.$1，請先完成 $2 $3"
    exit 1
  }
done
bq --headless show --format=none --connection "${PROJECT}.us.vertex_ai_conn" >/dev/null 2>&1 || {
  echo "❌ 找不到連線 us.vertex_ai_conn，請先完成 Day 03 的 Terraform"
  exit 1
}
# Day 11 的分群：K-means 每次重建分法可能不同，我把發表當天的分群另存成 mart_customer_segment_official 當驗收固定輸入；
# 讀者的環境只有 mart_customer_segment 的話就用它，S5a 的數字可能和文章不同
SEG="mart_customer_segment_official"
if ! bq --headless show --format=none "${PROJECT}:${DATASET}.${SEG}" >/dev/null 2>&1; then
  SEG="mart_customer_segment"
  bq --headless show --format=none "${PROJECT}:${DATASET}.${SEG}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.mart_customer_segment，請先完成 Day 11"
    exit 1
  }
  echo "ℹ️  沒有 mart_customer_segment_official，S5a 改讀 mart_customer_segment（最近一次重建的分群）"
fi
if ! bq --headless show --format=none "${PROJECT}:${GT}.gt_customer_segment" >/dev/null 2>&1 \
   || ! bq --headless show --format=none "${PROJECT}:${GT}.gt_signals" >/dev/null 2>&1; then
  echo "📥 找不到答案表，先載入（scripts/load_ground_truth.sh）"
  GT_DATASET="${GT}" bash ../scripts/load_ground_truth.sh
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s/martech_gt\./${GT}./g" \
           -e "s/mart_customer_segment_official/${SEG}/g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

# 判準什麼時候寫死的：印 GitHub 上最後一次修改判準檔的 commit 時間，等一下和評分時間比
CRIT_TS=""; BLIND_TS=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CRIT_TS="$(git log -1 --format='%cI' -- criteria.sql 2>/dev/null || true)"
  BLIND_TS="$(git log -1 --format='%cI' -- blind_criteria.sql 2>/dev/null || true)"
  echo "📌 判準最後 commit：criteria.sql ${CRIT_TS:-（未 commit）}、blind_criteria.sql ${BLIND_TS:-（未 commit）}"
  if [[ -n "$(git status --porcelain -- criteria.sql blind_criteria.sql)" ]]; then
    echo "⚠️  判準檔有未 commit 的修改，成績單的判準時間戳將不可信"
  fi
fi

echo "📋 建立判準表（criteria.sql、blind_criteria.sql）"
run_sql criteria.sql > /dev/null
run_sql blind_criteria.sql > /dev/null

echo "📊 成績單：各篇結果表對照判準（scorecard.sql，只讀結果表，不呼叫 Gemini）"
run_sql scorecard.sql --format=pretty --max_rows=100

echo "📝 盲測題目：整季週報（blind_prompt.sql，不挑異常、不給候選原因）"
run_sql blind_prompt.sql --format=pretty
run_sql <(printf 'SELECT prompt FROM martech_dw.blind_prompt WHERE run_no = 1') --format=csv --max_rows=1 \
  | python3 -c 'import csv,sys; r=list(csv.reader(sys.stdin)); t=r[1][0] if len(r)>1 else ""; L=t.split("\n"); print("\n".join(L[:10])); print(f"…（共 {len(L)} 行、{len(t)} 字）")'

echo "💰 呼叫前先數 Token（blind_cost.sql，兩個模型各三次的最壞情況）"
run_sql blind_cost.sql --format=pretty

if [[ "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "要呼叫 Gemini 嗎？會跑 flash-lite 與 3.6-flash 各三次，輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini；成績單已經建好在 ${GT}.acceptance_scorecard"; exit 0; }
fi

echo "🤖 呼叫 Gemini（blind.sql，6 次）"
run_sql blind.sql --format=pretty

echo "🎯 盲測評分（blind_score.sql，回答對照 blind_criteria）"
run_sql blind_score.sql --format=pretty

echo "🧾 檢查（check.sql ＋ 兩項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# 題目與呼叫的 SQL 不能讀答案表：只看真正執行的 SQL，註解裡提到 martech_gt 不算
LEAK=""
for F in blind_prompt.sql blind_cost.sql blind.sql; do
  if grep -v '^[[:space:]]*--' "${F}" | grep -q 'martech_gt'; then LEAK="${LEAK}${F} "; fi
done
run_sql <(printf 'SELECT FORMAT_TIMESTAMP("%%Y-%%m-%%dT%%H:%%M:%%S%%Ez", MIN(scored_at)) AS s FROM martech_gt.acceptance_scorecard UNION ALL SELECT FORMAT_TIMESTAMP("%%Y-%%m-%%dT%%H:%%M:%%S%%Ez", MIN(scored_at)) FROM martech_gt.blind_scorecard') \
  --format=csv --max_rows=2 > "${TMP}/scored.csv"
python3 - "${TMP}/check.csv" "${LEAK}" "${CRIT_TS}" "${BLIND_TS}" "${TMP}/scored.csv" <<'PYCHECK'
import csv, sys
from datetime import datetime
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
leak = sys.argv[2].strip()
rows.append({"check_name": "16 no answer table in prompt/call", "expected": "none",
             "actual": leak or "none", "ok": "DIFF" if leak else "OK"})
crit_ts, blind_ts = sys.argv[3], sys.argv[4]
scored = [r[0] for r in csv.reader(open(sys.argv[5], encoding="utf-8"))][1:]
def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
try:
    ok = bool(crit_ts and blind_ts and len(scored) == 2 and ts(crit_ts) < ts(scored[0]) and ts(blind_ts) < ts(scored[1]))
    actual = "yes" if ok else ("no git" if not (crit_ts and blind_ts) else "no")
except Exception:
    ok, actual = False, "n/a"
rows.append({"check_name": "17 criteria committed before scoring", "expected": "yes", "actual": actual, "ok": "OK" if ok else "DIFF"})
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    print(f"  {flag} {r['check_name']:<38} {r['expected']:>7}  {r['actual']:>7}")
bad = sum(r["ok"] != "OK" for r in rows)
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
if len(rows) != 17:
    print(f"❌ 檢查項目應該有 17 項，實際只有 {len(rows)} 項")
sys.exit(1 if bad or len(rows) != 17 else 0)
PYCHECK

echo "📈 報表（report.sql）"
python3 - report.sql "${TMP}" <<'PYSPLIT'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
parts = [p.strip() for p in re.split(r";\s*\n", text) if re.search(r"(?im)^\s*SELECT", p)]
for i, p in enumerate(parts, 1):
    open(f"{sys.argv[2]}/report_{i}.sql", "w", encoding="utf-8").write(p + "\n")
PYSPLIT
for F in "${TMP}"/report_*.sql; do
  grep '^--' "${F}" | tail -n 1 || true
  run_sql "${F}" --format=pretty --max_rows=100
  echo
done
