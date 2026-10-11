#!/usr/bin/env bash
# Day 27：手動啟動一次日報流程，再跑檢查與報表
# 用法（在儲存庫根目錄，先 bash scripts/deploy_daily_report.sh）：
#   bash workflows/run.sh --free      不花錢：三題都改打不存在的路徑，三題都要是 http_404 才算過（代表身分通過、寫入與失敗的處理都正常）
#   bash workflows/run.sh             今天還沒有完整的日報就問三題（先印估價，輸入 yes 才問），已經有就直接跳過
#   bash workflows/run.sh --force     今天已經有日報也重新問一次（再花一次錢）
#   bash workflows/run.sh --break 2   第 2 題故意失敗、其他兩題照問（會花兩題的錢），看缺一題的日報長什麼樣子
#   bash workflows/run.sh --report    不啟動流程，只跑檢查與報表
# 流程與查詢本身都在免費額度內，費用來自助理呼叫模型，上限由助理服務自己的每日上限管
set -euo pipefail

cd "$(dirname "$0")"
WORKFLOW="martech-daily-report"
SERVICE_NAME="martech-assistant"
REGION="${REGION:-us-central1}"
DATASET="${DATASET:-martech_dw}"
QUESTIONS=3
# 和 agent/serve.py 相同的上限與單價，只用來印估價
MAX_STEPS=4; INPUT_CAP=6000; MAX_OUTPUT=1024; PRICE_IN=0.75; PRICE_OUT=3.75; FX=32

MODE="normal"; BREAK=""; FREE_BAD=0
case "${1:-}" in
  "") ;;
  --free) MODE="free" ;;
  --force) MODE="force" ;;
  --report) MODE="report" ;;
  --break)
    MODE="break"; BREAK="${2:-}"
    [[ "${BREAK}" =~ ^[1-3]$ ]] || { echo "❌ --break 後面要接 1、2 或 3"; exit 1; } ;;
  *) echo "❌ 不認得的參數「$1」，用法見這個檔案開頭"; exit 1 ;;
esac

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
bq --headless show --format=none "${PROJECT}:${DATASET}.daily_reports" >/dev/null 2>&1 || {
  echo "❌ 找不到 ${DATASET}.daily_reports，請先 bash scripts/deploy_daily_report.sh"
  exit 1
}

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

scalar() {   # 跑一句只回一個值的查詢
  echo "$1" > "${TMP}/q.sql"
  run_sql "${TMP}/q.sql" --format=csv | tail -n 1
}

if [[ "${MODE}" != "report" ]]; then
  gcloud workflows describe "${WORKFLOW}" --project "${PROJECT}" --location "${REGION}" >/dev/null 2>&1 || {
    echo "❌ 找不到流程 ${WORKFLOW}，請先 bash scripts/deploy_daily_report.sh"
    exit 1
  }
  TODAY="$(TZ=Asia/Taipei date +%F)"
  DONE="$(scalar "SELECT COUNT(*) FROM (SELECT execution_id FROM martech_dw.daily_reports WHERE report_date = DATE '${TODAY}' AND status = 'ok' GROUP BY execution_id HAVING COUNT(DISTINCT section_no) = ${QUESTIONS})")"
  ASK=${QUESTIONS}
  case "${MODE}" in
    free)   DATA='{"force": true, "test_break": [1, 2, 3]}'; ASK=0 ;;
    force)  DATA='{"force": true}' ;;
    break)  DATA="{\"force\": true, \"test_break\": [${BREAK}]}"; ASK=$((QUESTIONS - 1)) ;;
    normal)
      DATA='{}'
      if [[ "${DONE}" != "0" ]]; then ASK=0; fi ;;
  esac

  if [[ "${ASK}" == "0" ]]; then
    if [[ "${MODE}" == "free" ]]; then
      echo "🆓 不花錢的測試：三題都改打不存在的路徑，助理不會呼叫模型，這次執行預期以失敗結束"
    else
      echo "🆓 ${TODAY} 已經有一份三題都答完的日報，流程會直接跳過、不發問（要重問請用 --force）"
    fi
  else
    # 每日上限以服務上實際設定的為準，今天已經花的從 Day 25 的 view 讀
    CAP="$(gcloud run services describe "${SERVICE_NAME}" --project "${PROJECT}" --region "${REGION}" --format=json 2>/dev/null \
      | python3 -c 'import json,sys
try:
    env = json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0].get("env", [])
    print(float(next(e["value"] for e in env if e.get("name") == "DAILY_CAP_TWD")))
except Exception:
    pass' || true)"
    if [[ -z "${CAP}" ]]; then
      echo "❌ 讀不到助理服務設定的每日上限 DAILY_CAP_TWD，沒有啟動流程，請確認 Day 26 的服務還在"
      exit 1
    fi
    SPENT="$(scalar "SELECT ROUND(IFNULL(SUM(cost_twd), 0), 4) FROM martech_dw.v_llm_usage_daily WHERE job = 'agent/serve.py' AND usage_date = DATE '${TODAY}'")"
    python3 - "${ASK}" "${MAX_STEPS}" "${INPUT_CAP}" "${MAX_OUTPUT}" "${PRICE_IN}" "${PRICE_OUT}" "${FX}" "${CAP}" "${SPENT}" <<'PYEST'
import sys
ask, steps, cap_in, cap_out, p_in, p_out, fx, cap, spent = (float(x) for x in sys.argv[1:])
worst_call = (cap_in * p_in + cap_out * p_out) / 1e6 * fx
print(f"💰 這次會向助理問 {ask:.0f} 題，每題最多呼叫模型 {steps:.0f} 次，照 Day 26 的實測每題約新台幣 0.15 到 0.3 元，預期共約 {ask * 0.15:.2f} 到 {ask * 0.3:.2f} 元")
print(f"   最壞情況：每次輸入都頂到 {cap_in:,.0f}、輸出都寫滿 {cap_out:,.0f} 個 Token，{ask:.0f} × {steps:.0f} 次約新台幣 {ask * steps * worst_call:.2f} 元")
print(f"   助理的每日上限是新台幣 {cap:g} 元，今天（台北時間）已經花了 {spent:.4f} 元，剩下的額度不夠付一次最貴的呼叫（{worst_call:.2f} 元）它就不再呼叫模型")
print("   這個上限是估算值不是帳單，日報和同事的提問共用同一個額度，實際以帳單為準")
PYEST
    read -r -p "輸入 yes 啟動流程：" ANSWER
    if [[ "${ANSWER}" != "yes" ]]; then
      echo "已停在這裡，沒有啟動流程"
      exit 2
    fi
  fi

  echo "🚀 啟動流程（參數 ${DATA}），等它跑完⋯"
  # 流程以失敗結束時 gcloud 可能回傳非 0，所以不讓 set -e 在這裡停下來，結果自己讀
  gcloud workflows run "${WORKFLOW}" --project "${PROJECT}" --location "${REGION}" --data "${DATA}" --format=json \
    > "${TMP}/exec.json" 2> "${TMP}/exec.err" || true
  python3 - "${TMP}/exec.json" "${TMP}/exec.err" <<'PYEXEC'
import json, sys
try:
    e = json.load(open(sys.argv[1]))
except Exception:
    print("❌ 讀不到這次執行的結果：")
    print(open(sys.argv[2]).read()[-800:])
    sys.exit(1)
name = e.get("name", "").rsplit("/", 1)[-1]
open(sys.argv[1] + ".id", "w").write(name)
print(f"   執行編號 {name}｜狀態 {e.get('state')}｜{e.get('startTime', '')[:19]} → {e.get('endTime', '')[:19]}（UTC）")
if e.get("result"):
    print("   結果：" + e["result"])
if e.get("error"):
    print("   錯誤：" + str(e["error"].get("payload", e["error"]))[:600])
PYEXEC
  if [[ "${MODE}" == "free" ]]; then
    # 身分正確時三題都是 http_404（通過 Cloud Run 的身分檢查、進到程式、路徑不存在）
    # 403 是流程的服務帳號沒有 run.invoker，401 是權杖的對象不對，這兩種隔天排程真的跑也會三題全失敗
    EXEC_ID="$(cat "${TMP}/exec.json.id" 2>/dev/null || true)"
    if [[ ! "${EXEC_ID}" =~ ^[A-Za-z0-9-]+$ ]]; then
      echo "❌ 讀不到這次執行的編號，沒辦法確認測試結果"
      exit 1
    fi
    GOOD="$(scalar "SELECT COUNT(*) FROM martech_dw.daily_reports WHERE execution_id = '${EXEC_ID}' AND status = 'failed' AND detail = 'http_404'")"
    if [[ "${GOOD}" != "${QUESTIONS}" ]]; then
      echo "❌ 預期 ${QUESTIONS} 題都是 http_404，實際只有 ${GOOD} 題，請看下面報表第 2 段的 detail（http_403 是少了 run.invoker，http_401 是權杖的對象不對）"
      FREE_BAD=1
    else
      echo "✅ ${QUESTIONS} 題都是 http_404：流程的身分通過了助理的檢查，失敗有被記進日報表"
    fi
  fi
fi

echo "🧾 檢查（check.sql）"
run_sql check.sql --format=csv --max_rows=100 > "${TMP}/check.csv"
python3 - "${TMP}/check.csv" <<'PYCHECK'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    sys.exit("❌ check.sql 沒有回傳任何一列")
info = [r for r in rows if "(info)" in r["check_name"] and r["ok"] != "OK"]
bad = [r for r in rows if r["ok"] != "OK" and r not in info]
for r in rows:
    mark = "✅" if r["ok"] == "OK" else ("ℹ️" if r in info else "❌")
    print(f"  {mark} {r['check_name']}（預期 {r['expected']}，實際 {r['actual']}）")
print(f"{len(rows) - len(bad) - len(info)} 項通過、{len(bad)} 項不通過、{len(info)} 項提醒")
open(sys.argv[1] + ".bad", "w").write(str(len(bad)))
PYCHECK
BAD="$(cat "${TMP}/check.csv.bad")"

echo "📊 報表（report.sql）"
for N in 1 2 3 4; do
  sed -n "/^-- 第 ${N} 段/,/;/p" report.sql > "${TMP}/part.sql"
  head -n 1 "${TMP}/part.sql" | sed 's/^-- //'
  run_sql "${TMP}/part.sql" --format=pretty --max_rows=200
done
if [[ "${BAD}" != "0" ]]; then
  echo "❌ 有 ${BAD} 項檢查不通過，照上面的項目排除後再跑一次"
  exit 1
fi
if [[ "${FREE_BAD}" != "0" ]]; then
  echo "❌ 不花錢的測試沒有通過，先不要啟用排程"
  exit 1
fi
echo "✅ 完成，日報在 ${PROJECT}.${DATASET}.v_daily_report"
