#!/usr/bin/env bash
set -euo pipefail

printf "env_check\n" > queue-stage.txt
: "${CLOUDFLARE_API_TOKEN:?}"
: "${CLOUDFLARE_ACCOUNT_ID:?}"
: "${D1_DATABASE_ID:?}"
: "${REPORTED_TARGET_HASHES:?}"

now_ms="$(date +%s%3N)"
expires_ms="$((now_ms + 24*60*60*1000))"

printf "create_table\n" > queue-stage.txt
create_body='{"sql":"CREATE TABLE IF NOT EXISTS repair_targets_v1 (item_hash TEXT PRIMARY KEY, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_attempt INTEGER NOT NULL DEFAULT 0)"}'
create_http="$(curl -sS -o queue-create-response.json -w '%{http_code}' -X POST   -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   -H 'Content-Type: application/json'   --data "$create_body"   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"
export QUEUE_CREATE_HTTP="$create_http"
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("queue-create-response.json","utf8"));
const http=String(process.env.QUEUE_CREATE_HTTP||"unknown");
if(!x.success||!/^2\d\d$/.test(http)){
  const e=x.errors?.[0]||{};
  const code=String(e.code??"unknown").replace(/[^A-Za-z0-9]/g,"").slice(0,24);
  const safe=String(e.message||"")
    .replace(/https?:\/\/\S+/gi,"URL")
    .replace(/[A-Fa-f0-9]{24,}/g,"HEX")
    .replace(/[^A-Za-z0-9 ]/g," ")
    .replace(/\s+/g," ")
    .trim()
    .split(" ")
    .slice(0,10)
    .join("")
    .slice(0,64)||"nomessage";
  fs.writeFileSync("queue-stage.txt","create_http"+http+"_code"+code+"_"+safe+"\n");
  process.exit(2);
}
NODE

IFS=',' read -r -a hashes <<< "$REPORTED_TARGET_HASHES"
queued=0
index=0
for raw in "${hashes[@]}"; do
  hash="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cd '0-9a-f')"
  if ! [[ "$hash" =~ ^[0-9a-f]{16}$ ]]; then
    echo "::error::Invalid reported target hash"
    exit 3
  fi
  index=$((index+1))
  printf "insert_%s\n" "$index" > queue-stage.txt
  export ITEM_HASH="$hash" NOW_MS="$now_ms" EXPIRES_MS="$expires_ms"
  body="$(node -e 'console.log(JSON.stringify({sql:"INSERT INTO repair_targets_v1 (item_hash,created_at,expires_at,attempts,last_attempt) VALUES (?,?,?,?,0) ON CONFLICT(item_hash) DO UPDATE SET created_at=excluded.created_at,expires_at=excluded.expires_at,attempts=0,last_attempt=0",params:[process.env.ITEM_HASH,Number(process.env.NOW_MS),Number(process.env.EXPIRES_MS),0]}))')"
  response="$(curl -fsS -X POST     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"     -H 'Content-Type: application/json'     --data "$body"     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"
  node -e 'const x=JSON.parse(process.argv[1]);if(!x.success)process.exit(2)' "$response"
  queued=$((queued+1))
done

printf "passed\n" > queue-stage.txt
echo "reported_targets_queued=$queued"
