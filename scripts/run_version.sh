# 給各天的 run.sh 用 source 載入：記下這次執行用的是哪個 commit、題目與判準的檔案有沒有未 commit 的修改
# 原本這幾天遇到未 commit 的修改就直接停下，連只是換個模型都會被擋住（Day 29 第 5 章），完賽後改成只提醒，
# 並把當下的版本寫進 martech_dw.ops_run_versions，事後要確認某次結果是不是用 commit 過的題目跑的，查這張表就好
#
# 用法（在 run.sh 裡）：
#   source ../scripts/run_version.sh
#   run_version "Day 19" answers.sql pages.sql compare.sql score.sql   # 檢查並提醒，不會停
#   run_version_record                                                 # 寫一列進 ops_run_versions（要先有 DATASET）
# 查詢與寫入都在 BigQuery 每月免費額度內

run_version() {
  RV_DAY="$1"; shift
  RV_SCRIPT="$(basename "$(pwd)")/$(basename "$0")"
  RV_COMMIT=""; RV_DIRTY=""; RV_FILES=""
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    RV_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
    RV_FILES="$(git status --porcelain -- "$@" 2>/dev/null | awk '{print $NF}' | paste -sd, - || true)"
    if [[ -n "${RV_FILES}" ]]; then
      RV_DIRTY="true"
      echo "⚠️  這些檔案有未 commit 的修改（或還沒 commit 過）：${RV_FILES}"
      echo "   照樣執行，但這次的結果會記成「未 commit 的版本」，看完結果再改題目或判準，結果就不能說是事先定好的"
    else
      RV_DIRTY="false"
    fi
    echo "📌 這次用的版本：commit ${RV_COMMIT:-（讀不到）}，題目與判準檔案$([[ "${RV_DIRTY}" == "true" ]] && echo "有" || echo "沒有")未 commit 的修改"
  else
    echo "⚠️  這裡不是 git 儲存庫，記不到這次用的是哪個版本，照樣執行"
  fi
}

run_version_record() {
  local ds="${DATASET:-martech_dw}" dirty="NULL"
  [[ "${RV_DIRTY}" == "true" || "${RV_DIRTY}" == "false" ]] && dirty="${RV_DIRTY}"
  if ! bq --headless --location=US query --nouse_legacy_sql --quiet --format=none \
      --parameter="day::${RV_DAY}" --parameter="script::${RV_SCRIPT}" --parameter="commit_sha::${RV_COMMIT}" \
      --parameter="dirty_files::${RV_FILES}" --parameter="flash_model::${GEMINI_MODEL_FLASH:-gemini-3.8-flash}" "
CREATE TABLE IF NOT EXISTS ${ds}.ops_run_versions (
  run_at TIMESTAMP, day STRING, script STRING, commit_sha STRING, dirty BOOL, dirty_files STRING, flash_model STRING
)
OPTIONS (description = '各天 run.sh 每次執行用的版本：commit、題目與判準檔案有沒有未 commit 的修改、Flash 模型名稱，只加不刪');
INSERT INTO ${ds}.ops_run_versions VALUES
  (CURRENT_TIMESTAMP(), @day, @script, NULLIF(@commit_sha, ''), ${dirty}, NULLIF(@dirty_files, ''), @flash_model);" >/dev/null 2>&1; then
    echo "⚠️  版本沒有寫進 ${ds}.ops_run_versions（不影響這次執行），版本是 commit ${RV_COMMIT:-（讀不到）}"
  fi
}
