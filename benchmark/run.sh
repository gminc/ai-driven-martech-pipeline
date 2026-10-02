#!/usr/bin/env bash
# Day 20：沿用 Day 16、Day 19 的呼叫紀錄 →（確認費用）→ 每個新組合先試一張 →（再確認）→ 跑完其餘的 → 再跑一次確認不重複收費 → 對答案 → 檢查 → 報表
# 用法：bash benchmark/run.sh            （在儲存庫根目錄執行，需先完成 Day 16 的 features/ 與 Day 19 的 consistency/）
#       AUTO_YES=1 bash benchmark/run.sh （跳過確認，排程用）
# 查詢在每月 1 TiB 免費額度內，呼叫模型會產生 Token 費用，呼叫前會先依「這次真的要呼叫的次數」印出估價
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
for T in "${DATASET}.obj_creatives:Day 14" "${DATASET}.mm_features_log:Day 16（bash features/run.sh）" \
         "${DATASET}.map_creative_landing:Day 19（bash consistency/run.sh）" "${DATASET}.ref_landing_pages:Day 19" \
         "${DATASET}.mm_gaps_log:Day 19" "${DATASET}.mart_ad_page_gaps:Day 19" \
         "martech_gt.gt_creative_design:Day 15" "martech_gt.gt_creative_review:Day 16" \
         "martech_gt.gt_ad_page_gaps:Day 19" "martech_gt.ad_page_gaps_runs:Day 19"; do
  bq --headless show --format=none "${PROJECT}:${T%%:*}" >/dev/null 2>&1 || {
    echo "❌ 找不到 ${T%%:*}，請先完成 ${T#*:}"
    exit 1
  }
done

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

# 五個組合各還有幾張沒有成功紀錄（task,model,pending 的 CSV，寫到 $1），組合的清單要和 bench.sql 的 todo 一樣
PENDING_SQL="SELECT c.task, c.model, COUNT(*) - COUNT(d.creative_id) AS pending
FROM UNNEST([STRUCT('features' AS task, 'gemini-3.5-flash-lite' AS model), STRUCT('features', 'gemini-3.6-flash'),
  STRUCT('gaps', 'gemini-3.5-flash-lite'), STRUCT('gaps', 'gemini-3.6-flash'), STRUCT('gaps', 'gemini-3.1-pro-preview')]) AS c
CROSS JOIN ${DATASET}.map_creative_landing m
LEFT JOIN (SELECT DISTINCT task, model, creative_id FROM ${DATASET}.mm_bench_log WHERE ok) d
  ON d.task = c.task AND d.model = c.model AND d.creative_id = m.creative_id
GROUP BY 1, 2 ORDER BY 1, 2"
pending_csv() {
  if ! bq --headless --location=US query --nouse_legacy_sql --quiet --format=csv "${PENDING_SQL}" > "$1" 2> "${TMP}/pending_err"; then
    echo "❌ 算不出還有幾張要問，先停下來，沒有呼叫模型" >&2; cat "${TMP}/pending_err" >&2; exit 1
  fi
  if [[ "$(wc -l < "$1" | tr -d ' ')" != "6" ]]; then
    echo "❌ 預期五個組合各一列，拿到的是：" >&2; cat "$1" >&2; exit 1
  fi
}
pending_total() { python3 -c "import csv,sys; print(sum(int(r['pending']) for r in csv.DictReader(open(sys.argv[1]))))" "$1"; }
log_rows() { scalar "SELECT COUNT(*) FROM ${DATASET}.mm_bench_log"; }
failed_since() {  # $1 之後新增的呼叫裡，沒有成功的有幾筆
  scalar "SELECT COUNT(*) FROM ${DATASET}.mm_bench_log WHERE source = 'day20' AND NOT ok AND created_at >= TIMESTAMP '$1'"
}

# 題目、評分的 SQL 有未 commit 的修改就停下來：看完結果再改題目或評分方式，就不能說是同一份題目了
# 答案表是 Day 15、Day 16、Day 19 寫好的，評分之後有沒有被改過由 check.sql 第 14 項用指紋檢查
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain -- reuse.sql bench.sql score.sql ../features/extract.sql ../consistency/compare.sql ../consistency/answers.sql ../features/review.sql)" ]]; then
    echo "❌ benchmark/ 的 reuse.sql、bench.sql、score.sql 或 Day 16、Day 19 的題目與答案有未 commit 的修改（或還沒 commit 過），先 commit 再執行"
    exit 1
  fi
fi

# 題目要和 Day 16、Day 19 的檔案一字不差（bench.sql 裡另外有 ASSERT 用指紋再擋一次）
python3 - <<'PYSYNC'
import re, sys
def block(path, name):
    m = re.search(r"DECLARE %s STRING DEFAULT '''(.*?)''';" % name, open(path, encoding="utf-8").read(), re.S)
    return m.group(1) if m else None
bad = []
if block("bench.sql", "prompt_b") is None or block("bench.sql", "prompt_b") != block("../features/extract.sql", "prompt_b"):
    bad.append("簡單題（features/extract.sql 的 prompt_b）")
if block("bench.sql", "task_text") is None or block("bench.sql", "task_text") != block("../consistency/compare.sql", "task_text"):
    bad.append("難題（consistency/compare.sql 的 task_text）")
if bad:
    print("❌ bench.sql 的題目和原本的檔案不一樣：" + "、".join(bad)); sys.exit(1)
print("📌 題目和 Day 16、Day 19 的檔案一字不差")
PYSYNC

echo "♻️  沿用前幾天的呼叫紀錄（reuse.sql，不呼叫模型）"
run_sql reuse.sql --format=pretty

# 估價：每次呼叫的輸入以「簡單題 1,600、難題 2,900 個 Token」計（估計值，Day 16、Day 19 實測平均約 1,400 與 2,150），
# 輸出寫滿上限是「簡單題 256、難題 2,048」（思考 Token 也算在上限裡，這一項是上限），
# 另外印一個「照 Day 19 實測的輸出量」的估計：難題輸出含思考以 600 個 Token 計（3.6-flash 實測平均 190、最多 951，Pro 會想比較多）
estimate() {  # $1 = pending 的 CSV
  python3 - "$1" <<'PYCOST'
import csv, sys
price = {"gemini-3.5-flash-lite": (0.33, 2.75), "gemini-3.6-flash": (0.825, 4.125), "gemini-3.1-pro-preview": (2.2, 13.2)}
shape = {"features": (1600, 256, 80), "gaps": (2900, 2048, 600)}   # 輸入、輸出上限、預期輸出
fx, worst, likely, n_all = 32, 0.0, 0.0, 0
for r in csv.DictReader(open(sys.argv[1])):
    n = int(r["pending"]); pin, pout = price[r["model"]]; tin, cap, exp = shape[r["task"]]
    w = n * (tin * pin + cap * pout) / 1e6 * fx
    l = n * (tin * pin + exp * pout) / 1e6 * fx
    worst += w; likely += l; n_all += n
    print(f"   {r['task']:<9}{r['model']:<24}{n:>3} 次  預期約 {l:>5.2f} 元  寫滿上限 {w:>5.2f} 元")
print(f"💰 這次要呼叫 {n_all} 次，預期約新台幣 {likely:.2f} 元，輸出全部寫滿上限時 {worst:.2f} 元（成功過的組合不再呼叫）")
PYCOST
}
confirm() {  # $1 = 問句
  if [[ "${AUTO_YES:-0}" != "1" ]]; then
    read -r -p "$1 輸入 yes 繼續：" ANSWER || ANSWER=""
    [[ "${ANSWER}" == "yes" ]] || { echo "已停在這裡，之後再跑 run.sh 會只補還沒成功的"; exit 0; }
  fi
}

pending_csv "${TMP}/pending.csv"
estimate "${TMP}/pending.csv"
P="$(pending_total "${TMP}/pending.csv")"

if [[ "${P}" -gt 0 ]]; then
  confirm "先讓每個還沒問完的組合各試一張（最多 5 次呼叫），看模型叫不叫得動、實際用掉多少 Token，"
  T0="$(date -u '+%Y-%m-%d %H:%M:%S+00')"
  echo "🧪 每個組合先試一張（bench.sql，batch_limit = 1）"
  run_sql bench.sql --format=pretty --parameter=batch_limit:INT64:1
  if [[ "$(failed_since "${T0}")" != "0" ]]; then
    echo "❌ 試跑有沒成功的呼叫（上面那張表的 failed 與 error_sample），先停下來，其餘的沒有呼叫"
    exit 1
  fi
  # 用試跑實際用掉的 Token 重新估一次其餘的費用
  bq --headless --location=US query --nouse_legacy_sql --quiet --format=csv \
    "SELECT task, model, prompt_tokens AS tin, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0) AS tout
     FROM ${DATASET}.mm_bench_log WHERE source = 'day20' AND created_at >= TIMESTAMP '${T0}'" > "${TMP}/canary.csv"
  pending_csv "${TMP}/pending.csv"
  python3 - "${TMP}/pending.csv" "${TMP}/canary.csv" <<'PYCANARY'
import csv, sys
price = {"gemini-3.5-flash-lite": (0.33, 2.75), "gemini-3.6-flash": (0.825, 4.125), "gemini-3.1-pro-preview": (2.2, 13.2)}
seen = {(r["task"], r["model"]): (int(r["tin"]), int(r["tout"])) for r in csv.DictReader(open(sys.argv[2]))}
total = 0.0
for r in csv.DictReader(open(sys.argv[1])):
    n = int(r["pending"]); key = (r["task"], r["model"])
    if n == 0 or key not in seen: continue
    tin, tout = seen[key]; pin, pout = price[r["model"]]
    c = n * (tin * pin + tout * pout) / 1e6 * 32
    total += c
    print(f"   {key[0]:<9}{key[1]:<24}試跑那一張：輸入 {tin}、輸出含思考 {tout} 個 Token，其餘 {n} 張照這個量約 {c:.2f} 元")
print(f"💰 其餘的照試跑的用量估計約新台幣 {total:.2f} 元（只有一張的樣本，每張用量會不同）")
PYCANARY
  P="$(pending_total "${TMP}/pending.csv")"
  if [[ "${P}" -gt 0 ]]; then
    confirm "要把其餘 ${P} 次跑完嗎？"
    echo "🏁 跑完其餘的（bench.sql，batch_limit = 24）"
    run_sql bench.sql --format=pretty --parameter=batch_limit:INT64:24
  fi
fi

# 同一段 SQL 再跑一次：成功過的組合不會再呼叫，只補第一次失敗的
pending_csv "${TMP}/pending.csv"
MISSING="$(pending_total "${TMP}/pending.csv")"
BEFORE="$(log_rows)"
echo "🔁 再執行一次 bench.sql：還沒成功的有 ${MISSING} 個，成功過的不應該再呼叫"
if [[ "${MISSING}" -gt 0 ]]; then
  estimate "${TMP}/pending.csv"
  confirm "還有 ${MISSING} 個沒成功，這一次會再呼叫這些，"
fi
run_sql bench.sql --format=pretty --parameter=batch_limit:INT64:24
AFTER="$(log_rows)"
RERUN_CALLS="$(( AFTER - BEFORE ))"
echo "   這一次呼叫了 ${RERUN_CALLS} 次"

echo "📝 對答案（score.sql）"
run_sql score.sql --format=pretty

echo "🧾 檢查（check.sql ＋ 三項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
# 呼叫模型的 SQL 不能讀答案資料集，raw_creatives 也還留著設計規格，一樣不能讀
LEAK="$(for F in reuse.sql bench.sql; do grep -vE '^\s*--' "$F" | grep -iE 'martech_gt|gt_|raw_|EXECUTE' >/dev/null && printf '%s ' "$F"; done || true)"
# 沿用的那一段和 Day 19 的給文字那一段，除了 endpoint 之外應該一樣：把 model_params 抽出來比
PARAMS="$(python3 - <<'PYPARAMS'
import re
def params(path, anchor):
    s = open(path, encoding="utf-8").read()
    i = s.index(anchor)
    m = re.search(r"model_params => JSON '''(.*?)'''", s[i:], re.S)
    return re.sub(r"\s+", "", m.group(1))
day19 = params("../consistency/compare.sql", "-- text：廣告圖＋頁面文字")
bench = open("bench.sql", encoding="utf-8").read()
mine = {re.sub(r"\s+", "", m) for m in re.findall(r"model_params => JSON '''(.*?)'''", bench, re.S)}
print("same" if mine == {day19} else "different")
PYPARAMS
)"
python3 - "${TMP}/check.csv" "${LEAK}" "${MISSING}" "${RERUN_CALLS}" "${PARAMS}" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if len(rows) != 15:
    print(f"❌ check.sql 應該回 15 項，拿到 {len(rows)} 項")
    sys.exit(1)
leak, missing, rerun, params = sys.argv[2].strip(), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5].strip()
rows.append({"check_name": "16 rerun calls = still missing", "expected": str(missing),
             "actual": str(rerun), "ok": "OK" if rerun == missing else "DIFF"})
rows.append({"check_name": "17 no answer table in calling SQL", "expected": "none",
             "actual": leak or "none", "ok": "OK" if not leak else "DIFF"})
rows.append({"check_name": "18 gaps params same as day 19", "expected": "same",
             "actual": params, "ok": "OK" if params == "same" else "DIFF"})
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<42} {r['expected']:>9}  {r['actual']:>9}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

echo "📊 報表（report.sql）"
run_sql report.sql --format=pretty --max_rows=300

echo "✅ Day 20 完成：成績在 ${DATASET}.mart_bench_features 與 ${DATASET}.mart_bench_gaps，呼叫紀錄在 ${DATASET}.mm_bench_log，Token 用量在 ${DATASET}.ops_llm_usage"
