#!/usr/bin/env bash
# Day 10：建立、刪除、列出明確快取（explicit context cache）
# 用法（在儲存庫根目錄執行）：
#   bash caching/cache.sh create   從 martech_dw.cache_context 讀出固定內容建一個快取，名稱寫進 caching/.cache_name
#   bash caching/cache.sh delete   刪掉 caching/.cache_name 記錄的快取，停止收儲存費
#   bash caching/cache.sh list     列出這個專案還活著的快取
# 注意：
#   1. gemini-3.5-flash-lite 沒有 us-central1 版本（建快取會回 404），所以快取建在 global
#   2. 快取有儲存費（每百萬 Token 每小時約 1 美元），預設只活 30 分鐘（TTL=1800s），用完一定要 delete
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
DATASET="${DATASET:-martech_dw}"
MODEL="${MODEL:-gemini-3.5-flash-lite}"
TTL="${TTL:-1800s}"
NAME_FILE="${DIR}/.cache_name"
API="https://aiplatform.googleapis.com/v1"
BASE="${API}/projects/${PROJECT_ID}/locations/global/cachedContents"
TOKEN="$(gcloud auth print-access-token)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

case "${1:-}" in
  create)
    if [[ -f "${NAME_FILE}" ]]; then
      echo "  上一次建的快取還沒刪，先刪掉再建新的"
      bash "$0" delete
    fi
    bq --headless --location=US query --nouse_legacy_sql --format=json --quiet \
      "SELECT context FROM ${DATASET}.cache_context" > "${TMP}/ctx.json"
    python3 - "${PROJECT_ID}" "${MODEL}" "${TTL}" "${TMP}/ctx.json" > "${TMP}/req.json" <<'EOF'
import json, sys
pid, model, ttl, path = sys.argv[1:]
ctx = json.load(open(path, encoding="utf-8"))[0]["context"]
print(json.dumps({
    "model": f"projects/{pid}/locations/global/publishers/google/models/{model}",
    "displayName": "day10-diag-context",
    "contents": [{"role": "user", "parts": [{"text": ctx}]}],
    "ttl": ttl,
}, ensure_ascii=False))
EOF
    curl -sS -m 240 -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json; charset=utf-8" \
      "${BASE}" -d @"${TMP}/req.json" > "${TMP}/resp.json"
    python3 - "${NAME_FILE}" "${TMP}/resp.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[2], encoding="utf-8"))
if "name" not in r:
    print("❌ 建立失敗：", json.dumps(r, ensure_ascii=False)[:800]); sys.exit(1)
open(sys.argv[1], "w").write(r["name"])
print("  快取名稱：", r["name"])
print("  Token 數：", r.get("usageMetadata", {}).get("totalTokenCount"))
print("  到期時間：", r.get("expireTime"))
EOF
    ;;
  delete)
    [[ -f "${NAME_FILE}" ]] || { echo "  沒有要刪的快取"; exit 0; }
    NAME="$(cat "${NAME_FILE}")"
    CODE="$(curl -sS -m 60 -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${TOKEN}" "${API}/${NAME}" || echo 000)"
    case "${CODE}" in
      200) rm -f "${NAME_FILE}"; echo "  已刪除：${NAME}" ;;
      404) rm -f "${NAME_FILE}"; echo "  已經過期或不存在，不用刪：${NAME}" ;;
      *)   echo "  ❌ 刪除失敗（HTTP ${CODE}）：${NAME}，請再跑一次 bash caching/cache.sh delete，或用 list 確認" >&2
           exit 1 ;;
    esac
    ;;
  list)
    curl -fsS -m 60 -H "Authorization: Bearer ${TOKEN}" "${BASE}" \
      | python3 -c 'import json,sys; r=json.load(sys.stdin); c=r.get("cachedContents",[]); [print("  ", x["name"], x.get("expireTime"), x.get("usageMetadata",{}).get("totalTokenCount")) for x in c]; print(f"  還活著的快取：{len(c)}")'
    ;;
  *)
    echo "用法：bash caching/cache.sh create|delete|list"; exit 1 ;;
esac
