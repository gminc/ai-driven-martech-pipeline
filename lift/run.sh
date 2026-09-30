#!/usr/bin/env bash
# Day 17：判準第二版 → 特徵 × 成效（只讀 martech_dw）→ S4 補考評分 → 檢查 → 報表
# 用法：bash lift/run.sh（在儲存庫根目錄執行，需先完成 Day 13 的判準表與 Day 16 的特徵表）
# 全部是查詢，在每月 1 TiB 免費額度內，不呼叫 Gemini
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
GT_DATASET="${GT_DATASET:-martech_gt}"

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
for T in "${DATASET}.mart_creative_features:Day 16（bash features/run.sh）" \
         "${DATASET}.fct_ad_daily:Day 07" \
         "${GT_DATASET}.acceptance_criteria:Day 13（bash acceptance/run.sh）" \
         "${GT_DATASET}.gt_creative_design:Day 15（bash structured/run.sh）" \
         "${GT_DATASET}.gt_signals:Day 13（bash scripts/load_ground_truth.sh）"; do
  bq --headless show --format=none "${PROJECT}:${T%%:*}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${T%%:*}，請先完成 ${T#*:}"
    exit 1
  }
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s/martech_gt\./${GT_DATASET}./g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

# 判準、分析與評分的 SQL 有未 commit 的修改就停下來，結果一印出來就不能再說「先寫判準」了，看完結果再改算法或評分方式也一樣
# 評分之後判準有沒有被改過，由 check.sql 第 16 項用判準表的指紋檢查（不比 commit 時間，rebase 會改掉它）
CRIT_TS=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain -- ../acceptance/criteria_v2.sql lift.sql score.sql)" ]]; then
    echo "❌ acceptance/criteria_v2.sql、lift/lift.sql 或 lift/score.sql 有未 commit 的修改（或還沒 commit 過），先 commit 再執行"
    exit 1
  fi
  CRIT_TS="$(git log -1 --format='%cI' -- ../acceptance/criteria_v2.sql 2>/dev/null || true)"
  echo "📌 判準最後 commit：acceptance/criteria_v2.sql ${CRIT_TS:-（找不到）}"
fi

echo "📋 建立判準第二版（acceptance/criteria_v2.sql）"
run_sql ../acceptance/criteria_v2.sql --format=pretty

echo "🔗 特徵 × 成效（lift.sql，只讀 ${DATASET}）"
run_sql lift.sql --format=pretty --max_rows=100

echo "🎯 S4 補考評分（score.sql）"
run_sql score.sql --format=pretty

echo "🧾 檢查（check.sql ＋ 一項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# 分析用的 SQL 不能讀答案：只看真正執行的 SQL，註解裡提到不算，raw_creatives 還留著規格欄位所以也擋
LEAK="$(grep -vE '^[[:space:]]*--' lift.sql | grep -iE 'martech_gt|gt_|raw_|gs://|EXECUTE' >/dev/null && printf 'lift.sql' || true)"
python3 - "${TMP}/check.csv" "${LEAK}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
leak = sys.argv[2].strip()
rows.append({"check_name": "17 no answer table in lift.sql", "expected": "none",
             "actual": leak or "none", "ok": "DIFF" if leak else "OK"})
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    print(f"  {flag} {r['check_name']:<44} {r['expected']:>7}  {r['actual']:>7}")
bad = sum(r["ok"] != "OK" for r in rows)
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
if len(rows) != 17:
    print(f"❌ 檢查項目應該有 17 項，實際有 {len(rows)} 項")
sys.exit(1 if bad or len(rows) != 17 else 0)
PYCHECK

echo "📊 報表（report.sql，第 5、6 段讀答案）"
run_sql report.sql --format=pretty --max_rows=100
