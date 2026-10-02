#!/usr/bin/env bash
# Day 20：沿用 Day 16、Day 19 的呼叫紀錄 →（確認費用）→ 每個新組合先試一張 →（再確認）→ 跑完其餘的 → 再跑一次確認不重複收費 → 對答案 → 檢查 → 報表
# 用法：bash benchmark/run.sh            （在儲存庫根目錄執行，需先完成 Day 16 的 features/ 與 Day 19 的 consistency/）
#       每一次要花錢之前都會停下來問，沒有跳過確認的選項
#       ALLOW_RECALL=1 bash benchmark/run.sh （Day 16 或 Day 19 的紀錄沿用不到 24 筆時，同意把缺的重新問一次）
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
         "${DATASET}.mart_creative_features:Day 16" \
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

# 五個組合各還有幾張要問（task,model,pending 的 CSV，寫到 $1）：還沒成功、而且「有回答但不算成功」不到兩次的張數，條件要和 bench.sql 的 todo 一樣
PENDING_SQL="SELECT c.task, c.model, COUNTIF(d.creative_id IS NULL AND x.creative_id IS NULL) AS pending
FROM UNNEST([STRUCT('features' AS task, 'gemini-3.5-flash-lite' AS model), STRUCT('features', 'gemini-3.6-flash'),
  STRUCT('gaps', 'gemini-3.5-flash-lite'), STRUCT('gaps', 'gemini-3.6-flash'), STRUCT('gaps', 'gemini-3.1-pro-preview')]) AS c
CROSS JOIN ${DATASET}.map_creative_landing m
JOIN ${DATASET}.ref_landing_pages p USING (page_id)
LEFT JOIN (SELECT DISTINCT task, model, creative_id FROM ${DATASET}.mm_bench_log WHERE ok) d
  ON d.task = c.task AND d.model = c.model AND d.creative_id = m.creative_id
LEFT JOIN (SELECT task, model, creative_id FROM ${DATASET}.mm_bench_log
           WHERE source = 'day20' AND NOT ok AND status = '' GROUP BY 1, 2, 3 HAVING COUNT(*) >= 2) x
  ON x.task = c.task AND x.model = c.model AND x.creative_id = m.creative_id
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
# 時間一律用 BigQuery 的時鐘（呼叫紀錄的 created_at 也是 BigQuery 的時間），不用這台機器的
bq_now() {
  local v
  v="$(bq --headless --location=US query --nouse_legacy_sql --quiet --format=csv "SELECT FORMAT_TIMESTAMP('%F %H:%M:%E6S+00', CURRENT_TIMESTAMP())" 2> "${TMP}/now_err" | tail -n 1)" || true
  if [[ ! "${v}" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}\ [0-9:.]+\+00$ ]]; then
    echo "❌ 拿不到 BigQuery 的時間（拿到「${v}」），先停下來，沒有呼叫模型" >&2; cat "${TMP}/now_err" >&2; exit 1
  fi
  echo "${v}"
}

# 題目、評分的 SQL 有未 commit 的修改就停下來：看完結果再改題目或評分方式，就不能說是同一份題目了
# 答案表是 Day 15、Day 16、Day 19 寫好的，評分之後有沒有被改過由 check.sql 第 14 項用指紋檢查
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain -- reuse.sql bench.sql score.sql ../features/extract.sql ../features/review.sql ../consistency/compare.sql ../consistency/pages.sql ../consistency/answers.sql ../creatives/images ../creatives/landing)" ]]; then
    echo "❌ benchmark/ 的 reuse.sql、bench.sql、score.sql，或 Day 16、Day 19 的題目、頁面文字、答案與圖片有未 commit 的修改（或還沒 commit 過），先 commit 再執行"
    exit 1
  fi
fi

# 三項不花錢的檢查放在呼叫之前：題目一字不差、每一段呼叫除了 endpoint 之外和原本的一樣、呼叫模型的 SQL 不讀答案
# （bench.sql 裡另外有 ASSERT 用指紋再擋一次題目）
STATIC="$(python3 - <<'PYSTATIC'
import re
def read(p): return open(p, encoding="utf-8").read()
def block(src, name):
    m = re.search(r"DECLARE %s STRING DEFAULT '''(.*?)''';" % name, src, re.S)
    return m.group(1) if m else None
def calls(src):
    # 每一段 AI.GENERATE( … ) AS g，去掉空白、把 endpoint 蓋掉之後拿來比
    out = []
    for m in re.finditer(r"AI\.GENERATE\((.*?)\)\s+AS g\b", src, re.S):
        t = re.sub(r"\s+", "", m.group(1))
        out.append(re.sub(r"endpoint=>'[^']+'", "endpoint=>X", t))
    return out
def intro(src):
    m = re.search(r"FORMAT\('(你是[^']+)', m\.channel, p\.title\) AS intro", src)
    return m.group(1) if m else None
bench, day16, day19 = read("bench.sql"), read("../features/extract.sql"), read("../consistency/compare.sql")
prompts = (block(bench, "prompt_b") is not None and block(bench, "prompt_b") == block(day16, "prompt_b")
           and block(bench, "task_text") is not None and block(bench, "task_text") == block(day19, "task_text"))
b, d16, d19 = calls(bench), calls(day16), calls(day19)
# Day 16 第一段是預設解析度，Day 19 第二段是給文字，bench.sql 前兩段是簡單題、後三段是難題
same = (len(b) == 5 and len(d16) >= 1 and len(d19) == 2
        and b[0] == b[1] == d16[0] and b[2] == b[3] == b[4] == d19[1]
        and intro(bench) is not None and intro(bench) == intro(day19))
leak = []
for f in ("reuse.sql", "bench.sql"):
    code = "\n".join(l for l in read(f).splitlines() if not l.lstrip().startswith("--"))
    if re.search(r"martech_gt|gt_|raw_|EXECUTE", code, re.I):
        leak.append(f)
print("same" if prompts else "different", "same" if same else "different", ",".join(leak) or "none")
PYSTATIC
)"
read -r S_PROMPT S_CALL S_LEAK <<< "${STATIC}"
echo "📌 題目和 Day 16、Day 19 一字不差：${S_PROMPT}｜每一段呼叫除了 endpoint 之外和原本的一樣：${S_CALL}｜呼叫模型的 SQL 讀到答案的檔案：${S_LEAK}"
if [[ "${S_PROMPT}" != "same" || "${S_CALL}" != "same" || "${S_LEAK}" != "none" ]]; then
  echo "❌ 上面三項有不對的，先停下來，沒有呼叫模型"
  exit 1
fi

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
  read -r -p "$1 輸入 yes 繼續：" ANSWER || ANSWER=""
  [[ "${ANSWER}" == "yes" ]] || { echo "已停在這裡，還沒有對答案也沒有報表，之後再跑 run.sh 會只補還沒成功的"; exit 2; }
}

pending_csv "${TMP}/pending.csv"
# 沿用的兩個組合應該 24 筆都抄到，沒抄滿代表篩選條件沒對上（例如舊紀錄沒有題目指紋），這時不要自動重問
SHORT="$(python3 -c "
import csv, sys
reuse = {('features', 'gemini-3.5-flash-lite'), ('gaps', 'gemini-3.6-flash')}
print(sum(int(r['pending']) for r in csv.DictReader(open(sys.argv[1])) if (r['task'], r['model']) in reuse))" "${TMP}/pending.csv")"
if [[ "${SHORT}" != "0" && "${ALLOW_RECALL:-0}" != "1" ]]; then
  echo "❌ 應該沿用的兩個組合還有 ${SHORT} 張沒有成功紀錄（看上面那張表），先停下來，沒有呼叫模型"
  echo "   確認過要重新問這幾張的話，用 ALLOW_RECALL=1 bash benchmark/run.sh"
  exit 1
fi
estimate "${TMP}/pending.csv"
P="$(pending_total "${TMP}/pending.csv")"

if [[ "${P}" -gt 0 ]]; then
  confirm "先讓每個還沒問完的組合各試一張（最多 5 次呼叫），看模型叫不叫得動、實際用掉多少 Token，"
  cp "${TMP}/pending.csv" "${TMP}/before.csv"
  T0="$(bq_now)"
  echo "🧪 每個組合先試一張（bench.sql，batch_limit = 1）"
  run_sql bench.sql --format=pretty --parameter=batch_limit:INT64:1
  # 試跑那幾筆：每個還沒問完的組合都要剛好一筆，而且要成功，少一筆或有失敗都停下來
  if ! bq --headless --location=US query --nouse_legacy_sql --quiet --format=csv \
    "SELECT task, model, CAST(ok AS STRING) AS ok, IFNULL(prompt_tokens, 0) AS tin, IFNULL(output_tokens, 0) + IFNULL(thoughts_tokens, 0) AS tout
     FROM ${DATASET}.mm_bench_log WHERE source = 'day20' AND created_at >= TIMESTAMP '${T0}'" > "${TMP}/canary.csv" 2> "${TMP}/canary_err"; then
    echo "❌ 讀不到試跑的紀錄，先停下來，其餘的沒有呼叫" >&2; cat "${TMP}/canary_err" >&2; exit 1
  fi
  pending_csv "${TMP}/pending.csv"
  python3 - "${TMP}/before.csv" "${TMP}/pending.csv" "${TMP}/canary.csv" <<'PYCANARY'
import csv, sys
price = {"gemini-3.5-flash-lite": (0.33, 2.75), "gemini-3.6-flash": (0.825, 4.125), "gemini-3.1-pro-preview": (2.2, 13.2)}
before = {(r["task"], r["model"]): int(r["pending"]) for r in csv.DictReader(open(sys.argv[1]))}
after = {(r["task"], r["model"]): int(r["pending"]) for r in csv.DictReader(open(sys.argv[2]))}
seen = {}
for r in csv.DictReader(open(sys.argv[3])):
    seen.setdefault((r["task"], r["model"]), []).append(r)
bad, total = [], 0.0
for key, n0 in before.items():
    if n0 == 0:
        continue
    rows = seen.get(key, [])
    if len(rows) != 1 or rows[0]["ok"] != "true":
        bad.append(f"{key[0]} × {key[1]}：試跑 {len(rows)} 筆、成功 {sum(r['ok'] == 'true' for r in rows)} 筆")
        continue
    tin, tout = int(rows[0]["tin"]), int(rows[0]["tout"]); pin, pout = price[key[1]]
    one = (tin * pin + tout * pout) / 1e6 * 32
    c = after[key] * one
    total += c
    print(f"   {key[0]:<9}{key[1]:<24}試跑那一張：輸入 {tin}、輸出含思考 {tout} 個 Token（{one:.3f} 元），其餘 {after[key]} 張照這個量約 {c:.2f} 元")
if bad:
    print("❌ 試跑沒有每個組合都成功一筆（看上面那張表的 failed 與 error_sample），先停下來，其餘的沒有呼叫")
    for b in bad: print("   " + b)
    sys.exit(1)
print(f"💰 其餘的照試跑的用量估計約新台幣 {total:.2f} 元（只有一張的樣本，每張用量會不同，寫滿上限的金額看前面那張表）")
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
RERUN="yes"
if [[ "${MISSING}" -gt 0 ]]; then
  estimate "${TMP}/pending.csv"
  read -r -p "還有 ${MISSING} 個沒成功，這一次會再呼叫這些，輸入 yes 繼續，其他輸入會跳過這一步、直接對答案：" RERUN || RERUN=""
fi
if [[ "${RERUN}" == "yes" ]]; then
  run_sql bench.sql --format=pretty --parameter=batch_limit:INT64:24
else
  echo "   跳過了，沒有再呼叫"
  MISSING=0
fi
AFTER="$(log_rows)"
RERUN_CALLS="$(( AFTER - BEFORE ))"
echo "   這一次呼叫了 ${RERUN_CALLS} 次"

echo "📝 對答案（score.sql）"
run_sql score.sql --format=pretty

echo "🧾 檢查（check.sql ＋ 三項腳本檢查）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
CHECK_RC=0
python3 - "${TMP}/check.csv" "${MISSING}" "${RERUN_CALLS}" "${S_CALL}" "${S_LEAK}" <<'PYCHECK' || CHECK_RC=$?
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if len(rows) != 17:
    print(f"❌ check.sql 應該回 17 項，拿到 {len(rows)} 項")
    sys.exit(1)
missing, rerun, same, leak = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
rows.append({"check_name": "18 rerun calls = still missing", "expected": str(missing),
             "actual": str(rerun), "ok": "OK" if rerun == missing else "DIFF"})
rows.append({"check_name": "19 no answer table in calling SQL", "expected": "none",
             "actual": leak, "ok": "OK" if leak == "none" else "DIFF"})
rows.append({"check_name": "20 calls same as day 16/19 but endpoint", "expected": "same",
             "actual": same, "ok": "OK" if same == "same" else "DIFF"})
bad = 0
for r in rows:
    flag = "✅" if r["ok"] == "OK" else "❌"
    bad += r["ok"] != "OK"
    print(f"  {flag} {r['check_name']:<42} {r['expected']:>9}  {r['actual']:>9}")
print(f"\n{len(rows) - bad} 項通過、{bad} 項不通過")
sys.exit(1 if bad else 0)
PYCHECK

# 檢查沒過也把報表印出來（沒做完的組合在報表裡看得到 no_call），最後再用檢查的結果當結束碼
echo "📊 報表（report.sql）"
run_sql report.sql --format=pretty --max_rows=300

echo "⏱  一批跑多久（timing.sql，沒有權限看工作紀錄時跳過）"
if sed -e "s/martech_dw\./${DATASET}./g" timing.sql \
    | bq --headless --location=US query --nouse_legacy_sql --quiet --format=pretty > "${TMP}/timing" 2> "${TMP}/timing_err"; then
  cat "${TMP}/timing"
else
  echo "   這一段沒有跑成功，其他報表不受影響："; tail -n 5 "${TMP}/timing" "${TMP}/timing_err"
fi

if [[ "${CHECK_RC}" != "0" ]]; then
  echo "❌ Day 20 有檢查沒通過，成績先不要拿來用"
  exit 1
fi
echo "✅ Day 20 完成：成績在 ${DATASET}.mart_bench_features 與 ${DATASET}.mart_bench_gaps，呼叫紀錄在 ${DATASET}.mm_bench_log，Token 用量在 ${DATASET}.ops_llm_usage"
