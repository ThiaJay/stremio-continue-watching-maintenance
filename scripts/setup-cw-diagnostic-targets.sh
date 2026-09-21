#!/usr/bin/env bash
set -euo pipefail

query(){
  local label="$1"
  local payload="$2"
  printf '%s\n' "$label" > cw-diagnostic-setup-stage.txt
  local http
  http="$(curl -sS -o d1-response.json -w '%{http_code}' -X POST     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"     -H 'Content-Type: application/json'     --data "$payload"     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"
  export D1_HTTP="$http"
  node - <<'NODE'
const fs=require("fs");
const http=String(process.env.D1_HTTP||"");
let x;
try{x=JSON.parse(fs.readFileSync("d1-response.json","utf8"));}catch{process.exit(2)}
const failed=!x.success||(x.result||[]).some(r=>r.success===false)||!/^2\d\d$/.test(http);
if(failed){
  const e=x.errors?.[0]||x.result?.find?.(r=>r.success===false)?.error||{};
  const code=String(e.code??e).replace(/[^A-Za-z0-9]/g,"").slice(0,32)||"unknown";
  const raw=String(e.message??e);
  const safe=raw.replace(/https?:\/\/\S+/gi,"URL").replace(/[A-Fa-f0-9]{24,}/g,"HEX").replace(/[^A-Za-z0-9 ]/g," ").replace(/\s+/g," ").trim().split(" ").slice(0,8).join("").slice(0,48)||"nomessage";
  const stage=fs.readFileSync("cw-diagnostic-setup-stage.txt","utf8").trim().replace(/[^A-Za-z0-9_-]/g,"");
  fs.writeFileSync("cw-diagnostic-setup-stage.txt",stage+"_http"+http+"_code"+code+"_"+safe+"\n");
  process.exit(3);
}
NODE
}

query "create_targets" '{"sql":"CREATE TABLE IF NOT EXISTS diagnostic_targets_v1 (item_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)"}'
query "create_results" '{"sql":"CREATE TABLE IF NOT EXISTS diagnostic_results_v1 (item_hash TEXT PRIMARY KEY, observed_at INTEGER NOT NULL, payload TEXT NOT NULL)"}'

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
query "insert_targets" "$payload"

cleanup="$(node -e 'process.stdout.write(JSON.stringify({sql:"DELETE FROM diagnostic_targets_v1 WHERE expires_at < ?",params:[Number(process.env.DIAGNOSTIC_EXPIRES)-6*60*60*1000]}))')"
query "cleanup_targets" "$cleanup"

printf 'passed\n' > cw-diagnostic-setup-stage.txt
echo "diagnostic_targets_ready"
