#!/usr/bin/env bash
# Day 20（選配）：用 colab run 在 Colab 的 GPU 上跑 Gemma 4，跑完自動釋放 VM
# 用法：bash benchmark/run_gemma_colab.sh              （在自己的電腦、儲存庫根目錄執行，需先安裝並登入 google-colab-cli）
#       GPU=L4 MODEL=google/gemma-4-E4B-it bash benchmark/run_gemma_colab.sh
#       IMAGES=3 bash benchmark/run_gemma_colab.sh     （只跑 3 張，先確認流程）
# 會消耗 Colab 的運算單元（CU），不會產生 Google Cloud 費用，CU 餘額沒有指令可以查，跑前跑後請到 Colab 網頁各記一次
# 結果存在 benchmark/gemma_out/ 底下（RESULT 開頭的每一行是一張圖），這支腳本不讀答案
set -uo pipefail

cd "$(dirname "$0")"
GPU="${GPU:-T4}"
MODEL="${MODEL:-google/gemma-4-E2B-it}"
IMAGES="${IMAGES:-24}"
RUN_TIMEOUT="${RUN_TIMEOUT:-1500}"   # colab run 自己的 --timeout（秒），預設只有 30 秒
MAX_SECS="${MAX_SECS:-1800}"         # 外層硬上限，超過就強制釋放 VM
SESSION="d20-$(date +%H%M%S)"        # 替 session 命名，收尾時可以指名釋放
mkdir -p gemma_out
LOG="gemma_out/${SESSION}-${GPU}.log"

command -v colab >/dev/null 2>&1 || {
  echo "❌ 找不到 colab 指令，請先照 https://github.com/googlecolab/google-colab-cli 的說明安裝並登入"
  exit 1
}

CLEANED=0
WATCHDOG=""
cleanup() {
  [[ "${CLEANED}" == 1 ]] && return
  CLEANED=1
  [[ -n "${WATCHDOG}" ]] && kill "${WATCHDOG}" 2>/dev/null
  echo "== 收尾：確認 session 已經釋放 =="
  colab stop -s "${SESSION}" >/dev/null 2>&1 || true
  colab sessions || true      # 應該顯示 No active sessions（或只剩你自己另外開的）
  echo "== 請到 Colab 網頁記下「跑後」的 CU 餘額 =="
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "== 請先到 Colab 網頁記下「跑前」的 CU 餘額 =="
echo "== GPU=${GPU}｜模型=${MODEL}｜${IMAGES} 張｜session=${SESSION}｜紀錄檔 benchmark/${LOG} =="

# 超過 MAX_SECS 還沒結束：直接指名釋放這個 session，再請 colab run 結束
# colab run 留在前景執行，按 Ctrl-C 時它收得到訊號，會自己釋放 VM
( sleep "${MAX_SECS}"
  echo "⏰ 超過 ${MAX_SECS} 秒，強制釋放 ${SESSION}"
  colab stop -s "${SESSION}" >/dev/null 2>&1
  pkill -INT -f "colab run -s ${SESSION}" 2>/dev/null ) &
WATCHDOG=$!

START="$(date +%s)"
colab run -s "${SESSION}" --gpu "${GPU}" --timeout "${RUN_TIMEOUT}" gemma_bench.py "${MODEL}" "${IMAGES}" 2>&1 | tee "${LOG}"
RC="${PIPESTATUS[0]}"
echo "== colab run 結束，結束碼 ${RC}，從配 VM 到結束共 $(( $(date +%s) - START )) 秒 =="
echo "== 成功的張數：$(grep -c '^RESULT' "${LOG}" || true) 行 RESULT，摘要：$(grep '^SUMMARY' "${LOG}" || echo 沒有) =="
exit "${RC}"
