#!/usr/bin/env bash
# Day 16：記下規格與畫面不一致的圖 →（確認費用）→ Gemini 看完全部素材圖 → 特徵表 → 再跑一次確認不重複收費 → 檢查 → 報表
# 用法：bash features/run.sh            （在儲存庫根目錄執行，需先完成 Day 14 的物件表與 Day 15 的搬家）
#       AUTO_YES=1 bash features/run.sh （跳過確認，排程用）
# 查詢在每月 1 TiB 免費額度內，看圖會產生 Token 費用，呼叫前會先依「這次真的要呼叫的次數」印出最壞情況
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
for T in dim_creative obj_creatives; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T}，請先完成 Day 07 與 Day 14"
    exit 1
  }
done
bq --headless show --format=none "${PROJECT}:${GT_DATASET}.gt_creative_design" >/dev/null 2>&1 || {
  echo "❌ 找不到答案表 ${GT_DATASET}.gt_creative_design，請先執行 Day 15 的搬家（bash structured/run.sh，在估價那一步按 Enter 就好，免費）"
  exit 1
}

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
  bq --headless show --format=none "${PROJECT}:${DATASET}.mm_features_log" >/dev/null 2>&1
}
pending() {  # 還沒有成功紀錄的圖 × 解析度，$1＝default 或 low
  local done_n=0
  if log_exists; then
    done_n="$(scalar "SELECT COUNT(DISTINCT creative_id) FROM ${DATASET}.mm_features_log WHERE resolution = '$1' AND status = '' AND has_person IS NOT NULL AND cta_position IS NOT NULL AND dominant_color IS NOT NULL AND text_density IS NOT NULL AND headline IS NOT NULL AND headline != ''")"
  fi
  echo $(( IMAGES - done_n ))
}
log_rows() {
  if log_exists; then scalar "SELECT COUNT(*) FROM ${DATASET}.mm_features_log"; else echo 0; fi
}

echo "🔍 記下規格與畫面看起來不一致的圖（review.sql，答案資料集）"
run_sql review.sql --format=pretty

IMAGES="$(scalar "SELECT COUNT(*) FROM ${DATASET}.obj_creatives")"
if [[ "${IMAGES}" -eq 0 ]]; then
  echo "❌ 物件表裡沒有圖，請先完成 Day 14 並確認 bucket 裡有素材圖"
  exit 1
fi
P_DEFAULT="$(pending default)"
P_LOW="$(pending low)"

# 最壞情況：預設解析度每次輸入以 1,600 個 Token 計（一張圖 1,104、題目與判斷標準約 380，實測最多約 1,490），
# 低解析度以 800 計（一張圖 276），輸出都以 max_output_tokens 256 計，單價用非 global 端點
# 超出選項時用 enum 補問的那幾張不在這個估價裡，每張約再加新台幣 0.04 元，check 與報表會列出有沒有發生
python3 - "${P_DEFAULT}" "${P_LOW}" <<'PYCOST'
import sys
pd, pl = int(sys.argv[1]), int(sys.argv[2])
fx = 32
cost = (pd * (1600 * 0.33 + 256 * 2.75) + pl * (800 * 0.33 + 256 * 2.75)) / 1e6
print(f"💰 這次要呼叫 Gemini {pd + pl} 次（預設解析度 {pd} 次、低解析度 {pl} 次，已經成功過的圖不再呼叫）")
print(f"   最壞情況約 US$ {cost:.4f} ≈ 新台幣 {cost * fx:.2f} 元（輸入以預設 1,600、低解析度 800 Token 計，輸出以 256 計）")
print(f"   若有值超出選項，那幾張會改用 enum 再問一次，每張約再加新台幣 0.04 元")
PYCOST
if [[ "${AUTO_YES:-0}" != "1" && $(( P_DEFAULT + P_LOW )) -gt 0 ]]; then
  read -r -p "要呼叫 Gemini 看圖嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini"; exit 0; }
fi

echo "👀 第一次執行：Gemini 看完全部素材圖（extract.sql）"
run_sql extract.sql --format=pretty

echo "🧱 建特徵表（mart.sql）"
run_sql mart.sql --format=pretty

# 同一段 SQL 再跑一次：成功過的圖不會再呼叫，只補第一次失敗的
MISSING="$(( $(pending default) + $(pending low) ))"
BEFORE="$(log_rows)"
echo "🔁 第二次執行 extract.sql：還沒成功的有 ${MISSING} 個，成功過的不應該再呼叫"
if [[ "${MISSING}" -gt 0 && "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "第一次有 ${MISSING} 個沒成功，第二次會再呼叫這些，每次約新台幣 0.04 元，輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已停在這裡，第二次沒有執行，之後再跑 run.sh 會只補沒成功的"; exit 0; }
fi
run_sql extract.sql --format=pretty
AFTER="$(log_rows)"
RERUN_CALLS="$(( AFTER - BEFORE ))"
echo "   第二次執行呼叫了 ${RERUN_CALLS} 次"
if [[ "${RERUN_CALLS}" -gt 0 ]]; then
  run_sql mart.sql --format=none >/dev/null
fi

echo "🧾 檢查（check.sql ＋ 一項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# raw_creatives 是 Day 06 原樣載入的檔案，裡面還留著設計規格，分析用的 SQL 一樣不能讀
LEAK="$(for F in extract.sql mart.sql; do grep -vE '^\s*--' "$F" | grep -E 'martech_gt|gt_creative|raw_creatives' >/dev/null && printf '%s ' "$F"; done || true)"
python3 - "${TMP}/check.csv" "${LEAK}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
leak = sys.argv[2].strip()
rows.append({"check_name": "13 no answer table in extract/mart SQL", "expected": "none",
             "actual": leak or "none", "ok": "OK" if not leak else "DIFF"})
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<40} {r['expected']:>7}  {r['actual']:>7}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

echo "📊 報表（report.sql，第 3、4、5 段對答案）"
run_sql report.sql --format=pretty --max_rows=100

echo "✅ Day 16 完成：特徵表在 ${DATASET}.mart_creative_features，呼叫紀錄在 ${DATASET}.mm_features_log，Token 用量在 ${DATASET}.ops_llm_usage"
