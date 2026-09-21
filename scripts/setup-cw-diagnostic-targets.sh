#!/usr/bin/env bash
set -euo pipefail

expires="$(( $(date +%s%3N) + 6*60*60*1000 ))"
sql='
CREATE TABLE IF NOT EXISTS diagnostic_targets_v1 (
  item_hash TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS diagnostic_results_v1 (
  item_hash TEXT PRIMARY KEY,
  observed_at INTEGER NOT NULL,
  payload TEXT NOT NULL
);
INSERT INTO diagnostic_targets_v1 (item_hash,expires_at) VALUES
  (?,?),(?,?),(?,?)
ON CONFLICT(item_hash) DO UPDATE SET expires_at=excluded.expires_at;
DELETE FROM diagnostic_targets_v1 WHERE expires_at < ?;
'
python3 - <<PY > diagnostic-setup.json
import json
expiry=int("$expires")
hashes=["d50710896150aed6","5802dbc5fda6b745","c13774ae113c75c9"]
params=[]
for h in hashes:
    params.extend([h,expiry])
params.append(expiry-6*60*60*1000)
print(json.dumps({"sql":"""$sql""","params":params}))
PY

response="$(curl -fsS -X POST   -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   -H 'Content-Type: application/json'   --data @diagnostic-setup.json   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

node - <<'NODE' "$response"
const x=JSON.parse(process.argv[2]);
if(!x.success)process.exit(2);
const results=x.result||[];
if(!Array.isArray(results)||results.some(r=>r.success===false))process.exit(3);
console.log("diagnostic_targets_ready");
NODE
