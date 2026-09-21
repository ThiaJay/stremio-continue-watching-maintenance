#!/usr/bin/env bash
set -euo pipefail

query(){
  local payload="$1"
  local response
  response="$(curl -fsS -X POST     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"     -H 'Content-Type: application/json'     --data "$payload"     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"
  node -e 'const x=JSON.parse(process.argv[1]);if(!x.success||(x.result||[]).some(r=>r.success===false))process.exit(2)' "$response"
}

query '{"sql":"CREATE TABLE IF NOT EXISTS diagnostic_targets_v1 (item_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)"}'
query '{"sql":"CREATE TABLE IF NOT EXISTS diagnostic_results_v1 (item_hash TEXT PRIMARY KEY, observed_at INTEGER NOT NULL, payload TEXT NOT NULL)"}'

expires="$(( $(date +%s%3N) + 6*60*60*1000 ))"
export DIAGNOSTIC_EXPIRES="$expires"
payload="$(node - <<'NODE'
const expiry=Number(process.env.DIAGNOSTIC_EXPIRES);
const hashes=["d50710896150aed6","5802dbc5fda6b745","c13774ae113c75c9"];
const values=hashes.map(()=>"(?,?)").join(",");
const params=[];
for(const h of hashes)params.push(h,expiry);
process.stdout.write(JSON.stringify({
  sql:"INSERT INTO diagnostic_targets_v1 (item_hash,expires_at) VALUES "+values+" ON CONFLICT(item_hash) DO UPDATE SET expires_at=excluded.expires_at",
  params
}));
NODE
)"
query "$payload"

cleanup="$(node -e 'process.stdout.write(JSON.stringify({sql:"DELETE FROM diagnostic_targets_v1 WHERE expires_at < ?",params:[Number(process.env.DIAGNOSTIC_EXPIRES)-6*60*60*1000]}))')"
query "$cleanup"

echo "diagnostic_targets_ready"
