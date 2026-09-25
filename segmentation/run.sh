#!/usr/bin/env bash
# Day 11：整理特徵 →（確認）→ 建 K-means 模型 → 分群 → 檢查 → 輪廓 → 揭曉
# 用法：bash segmentation/run.sh               （在儲存庫根目錄執行，需先完成 Day 07 與 Day 05 合成器）
#       bash segmentation/run.sh --compare     （另外建 3 群、5 群、全部顧客 4 群三個對照模型，約多新台幣 0.3 元）
#       AUTO_YES=1 bash segmentation/run.sh    （跳過確認，排程用）
# CREATE MODEL 沒有免費額度，每個模型照最低 10 MB 計費，約新台幣 0.1 元；其他查詢在每月 1 TiB 免費額度內
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
GT="${GT_DATASET:-martech_gt}"
COMPARE=0
[[ "${1:-}" == "--compare" ]] && COMPARE=1

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
bq --headless show --format=none "${PROJECT}:${DATASET}.fct_orders" >/dev/null 2>&1 || {
  echo "❌ 找不到 ${DATASET}.fct_orders，請先完成 Day 07"
  exit 1
}
if ! bq --headless show --format=none "${PROJECT}:${GT}.gt_customer_segment" >/dev/null 2>&1; then
  echo "📥 找不到答案表，先載入（scripts/load_ground_truth.sh）"
  GT_DATASET="${GT}" bash ../scripts/load_ground_truth.sh
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s/martech_gt\./${GT}./g" "$1" \
      | bq --headless --location=US query --nouse_legacy_sql --quiet "${@:2}" \
        > "${TMP}/out" 2> "${TMP}/err"; then
    echo "❌ $1 執行失敗" >&2
    tail -n 20 "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  cat "${TMP}/out"
}

echo "🧮 整理特徵（features.sql）"
run_sql features.sql --format=pretty

MODELS=1
[[ "${COMPARE}" == "1" ]] && MODELS=4
echo "💰 將建立 ${MODELS} 個 K-means 模型，每個照最低 10 MB 計費，約新台幣 $(python3 -c "print(f'{${MODELS}*0.1:.1f}')") 元"
if [[ "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "要建立模型嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有建立模型"; exit 0; }
fi

echo "🤖 建立正式模型 seg_kmeans_k4（model.sql，一到幾分鐘，大多在排隊）"
run_sql model.sql > /dev/null
echo "🏷️  分群並落表（predict.sql）"
run_sql predict.sql > /dev/null

if [[ "${COMPARE}" == "1" ]]; then
  echo "🤖 建立對照模型 k3、k5、k4_all（compare.sql）"
  run_sql compare.sql > /dev/null
fi

echo "🧾 檢查結果（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# 另外確認只有揭曉用的 SQL 讀答案表：特徵、模型、分群、輪廓都不能出現 martech_gt
LEAK=""
for F in features.sql model.sql predict.sql profile.sql compare.sql evaluate.sql; do
  # 註解裡提到 martech_gt 不算，只看真正執行的 SQL
  if grep -v '^[[:space:]]*--' "${F}" | grep -q 'martech_gt'; then LEAK="${LEAK}${F} "; fi
done
python3 - "${TMP}/check.csv" "${LEAK}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
leak = sys.argv[2].strip()
rows.append({"check_name": "8 no answer table in features/model", "expected": "none",
             "actual": leak or "none", "ok": "DIFF" if leak else "OK"})
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    print(f"  {flag} {r['check_name']:<38} {r['expected']:>7}  {r['actual']:>7}")
bad = sum(r["ok"] != "OK" for r in rows)
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
if len(rows) != 8:
    print(f"❌ 檢查項目應該有 8 項，實際只有 {len(rows)} 項")
sys.exit(1 if bad or len(rows) != 8 else 0)
PYCHECK

echo "📊 每一群的輪廓（profile.sql 第一段，不看答案）"
python3 - profile.sql "${TMP}" <<'PYSPLIT'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
parts = [p.strip() for p in re.split(r";\s*\n", text) if re.search(r"(?im)^\s*(WITH|SELECT)", p)]
open(f"{sys.argv[2]}/profile_1.sql", "w", encoding="utf-8").write(parts[0] + "\n")
PYSPLIT
run_sql "${TMP}/profile_1.sql" --format=pretty

echo "🔓 揭曉（reveal.sql，分群結果 × 答案表）"
run_sql reveal.sql --format=pretty --max_rows=100

if [[ "${COMPARE}" == "1" ]]; then
  echo "📐 Davies-Bouldin 比較（evaluate.sql）"
  run_sql evaluate.sql --format=pretty
  for M in seg_kmeans_k3 seg_kmeans_k5 seg_kmeans_k4_all; do
    echo "🔓 ${M} 揭曉（reveal_models.sql，只含觀察滿 30 天的人）"
    sed "s/MODEL_NAME/${M}/g" reveal_models.sql > "${TMP}/reveal_${M}.sql"
    run_sql "${TMP}/reveal_${M}.sql" --format=pretty --max_rows=100
  done
fi
