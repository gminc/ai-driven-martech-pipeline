#!/usr/bin/env bash
# Day 19：頁面截圖上傳 → 頁面文字與對照表 → 答案表 →（確認費用）→ Gemini 比對廣告圖與頁面 → 再跑一次確認不重複收費 → 對答案 → 檢查 → 報表
# 用法：bash consistency/run.sh            （在儲存庫根目錄執行，需先完成 Day 14 物件表與 Day 16 的共用用量表）
#       AUTO_YES=1 bash consistency/run.sh （跳過確認，排程用）
# 查詢在每月 1 TiB 免費額度內，比對會產生 Token 費用，呼叫前會先依「這次真的要呼叫的次數」印出最壞情況
set -euo pipefail

cd "$(dirname "$0")"
DATASET="${DATASET:-martech_dw}"
EXPECTED=48   # 24 張廣告圖 × 2 種給頁面的方式

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
for T in obj_creatives dim_creative; do
  bq --headless show --format=none "${PROJECT}:${DATASET}.${T}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${DATASET}.${T}，請先完成 Day 07（素材維度）與 Day 14（物件表）"
    exit 1
  }
done
bq --headless show --format=none "${PROJECT}:martech_gt" >/dev/null 2>&1 || {
  echo "❌ 找不到答案資料集 martech_gt，請先完成 Day 11 的 scripts/load_ground_truth.sh"
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

run_sql() {
  if ! sed -e "s/martech_dw\./${DATASET}./g" -e "s/PROJECT_ID/${PROJECT}/g" "$1" \
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
  bq --headless show --format=none "${PROJECT}:${DATASET}.mm_gaps_log" >/dev/null 2>&1
}
OK_COND="status = '' AND IFNULL(finish_reason, '') != 'MAX_TOKENS' AND JSON_QUERY_ARRAY(SAFE.PARSE_JSON(result), '\$.gaps') IS NOT NULL"
pending() {  # 24 張 × 2 種給法，扣掉已經成功的組合（成功的定義和 compare.sql 一樣）
  if ! log_exists; then echo "${EXPECTED}"; return; fi
  scalar "WITH c AS (SELECT creative_id, m FROM ${DATASET}.dim_creative CROSS JOIN UNNEST(['image', 'text']) AS m WHERE format = 'image'), d AS (SELECT DISTINCT creative_id, mode FROM ${DATASET}.mm_gaps_log WHERE ${OK_COND}) SELECT COUNT(*) FROM c LEFT JOIN d ON d.creative_id = c.creative_id AND d.mode = c.m WHERE d.creative_id IS NULL"
}
log_rows() {
  if log_exists; then scalar "SELECT COUNT(*) FROM ${DATASET}.mm_gaps_log"; else echo 0; fi
}

# 答案、題目與評分的 SQL 有未 commit 的修改就停下來：結果一印出來就不能再說「先寫答案」了，看完結果再改題目或評分方式也一樣
# 評分之後答案表有沒有被改過，由 check.sql 第 12 項用答案表的指紋檢查
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain -- answers.sql compare.sql score.sql)" ]]; then
    echo "❌ consistency/answers.sql、compare.sql 或 score.sql 有未 commit 的修改（或還沒 commit 過），先 commit 再執行"
    exit 1
  fi
  echo "📌 答案表最後 commit：consistency/answers.sql $(git log -1 --format='%cI' -- answers.sql 2>/dev/null || true)"
fi

BUCKET="gs://${PROJECT}-martech-assets/landing"
SHOTS="$(gcloud storage ls "${BUCKET}/*.jpg" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${SHOTS}" != "3" ]]; then
  echo "📤 上傳三張頁面截圖到 ${BUCKET}（不到 1 MB，在 Cloud Storage 免費額度內）"
  gcloud storage cp ../creatives/landing/home.jpg ../creatives/landing/lp-autumn-cotton.jpg ../creatives/landing/lp-training-socks.jpg "${BUCKET}/"
else
  echo "🗂️  ${BUCKET} 已有三張頁面截圖，沿用"
fi

echo "📄 頁面文字、截圖物件表與對照表（pages.sql）"
run_sql pages.sql --format=pretty

echo "🔑 答案表（answers.sql，在呼叫 Gemini 之前就寫好）"
run_sql answers.sql --format=pretty

P="$(pending)"
[[ "${P}" =~ ^[0-9]+$ ]] || { echo "❌ 算不出這次要呼叫幾次（拿到「${P}」），先停下來，沒有呼叫 Gemini"; exit 1; }
# 最壞情況：每次輸入以 3,400 個 Token 計（兩張圖各約 1,100、題目約 700，留一成多餘裕，這一項是估計值，給文字的那一半實際會比較少），
# 輸出以 max_output_tokens 2,048 計（思考 Token 也算在裡面，這一項是上限），單價用 gemini-3.6-flash 非 global 端點
python3 - "${P}" <<'PYCOST'
import sys
n = int(sys.argv[1])
fx = 32
cost = n * (3400 * 0.825 + 2048 * 4.125) / 1e6
print(f"💰 這次要呼叫 Gemini {n} 次（24 張廣告圖 × 2 種給頁面的方式，已經成功過的組合不再呼叫）")
print(f"   最壞情況約 US$ {cost:.4f} ≈ 新台幣 {cost * fx:.2f} 元（輸入以 3,400、輸出含思考以 2,048 Token 計）")
PYCOST
if [[ "${AUTO_YES:-0}" != "1" && "${P}" -gt 0 ]]; then
  read -r -p "要呼叫 Gemini 比對嗎？輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已取消，沒有呼叫 Gemini"; exit 0; }
fi

echo "🔍 第一次執行：Gemini 比對廣告圖與頁面（compare.sql）"
run_sql compare.sql --format=pretty

# 同一段 SQL 再跑一次：成功過的組合不會再呼叫，只補第一次失敗的
MISSING="$(pending)"
[[ "${MISSING}" =~ ^[0-9]+$ ]] || { echo "❌ 算不出還沒成功的有幾個（拿到「${MISSING}」），先停下來"; exit 1; }
BEFORE="$(log_rows)"
echo "🔁 第二次執行 compare.sql：還沒成功的有 ${MISSING} 個，成功過的不應該再呼叫"
if [[ "${MISSING}" -gt 0 && "${AUTO_YES:-0}" != "1" ]]; then
  read -r -p "第一次有 ${MISSING} 個沒成功，第二次會再呼叫這些，每次最多約新台幣 0.36 元，輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已停在這裡，第二次沒有執行，之後再跑 run.sh 會只補沒成功的"; exit 0; }
fi
run_sql compare.sql --format=pretty
AFTER="$(log_rows)"
RERUN_CALLS="$(( AFTER - BEFORE ))"
echo "   第二次執行呼叫了 ${RERUN_CALLS} 次"

echo "📝 對答案（score.sql）"
run_sql score.sql --format=pretty

echo "🧾 檢查（check.sql ＋ 兩項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# 準備題目與呼叫 Gemini 的 SQL 不能讀答案資料集，raw_creatives 也還留著設計規格，一樣不能讀
LEAK="$(for F in pages.sql compare.sql; do grep -vE '^\s*--' "$F" | grep -iE 'martech_gt|gt_|raw_|EXECUTE' >/dev/null && printf '%s ' "$F"; done || true)"
python3 - "${TMP}/check.csv" "${LEAK}" "${MISSING}" "${RERUN_CALLS}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
leak, missing, rerun = sys.argv[2].strip(), int(sys.argv[3]), int(sys.argv[4])
rows.append({"check_name": "13 rerun calls = still missing", "expected": str(missing),
             "actual": str(rerun), "ok": "OK" if rerun == missing else "DIFF"})
rows.append({"check_name": "14 no answer table in question SQL", "expected": "none",
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
run_sql report.sql --format=pretty --max_rows=200

echo "✅ Day 19 完成：對答案的結果在 ${DATASET}.mart_ad_page_gaps，呼叫紀錄在 ${DATASET}.mm_gaps_log，Token 用量在 ${DATASET}.ops_llm_usage"
