#!/usr/bin/env bash
set -euo pipefail

deployments="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/deployments")"
info="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);const created=Date.parse(d.created_on||d.createdAt||d.created_at||"");if(!Number.isFinite(created))process.exit(3);process.stdout.write(JSON.stringify({id:String(d.id||""),created}))' "$deployments")"
active_id="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$info")"
active_norm="$(printf '%s' "$active_id" | tr -cd 'A-Za-z0-9')"
case "$active_norm" in
  bc84b08545c9*) ;;
  *) echo "::error::Unexpected active deployment"; exit 4 ;;
esac
deployment_ms="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).created))' "$info")"
export DEPLOYMENT_MS="$deployment_ms"

python3 - <<'PY' > backup-query.json
import json, os
sql="""
SELECT item_hash, COUNT(*) AS c, MAX(created_at) AS latest
FROM watch_backups
WHERE created_at >= ? AND item_hash IN (?,?)
GROUP BY item_hash
"""
print(json.dumps({"sql":sql,"params":[int(os.environ["DEPLOYMENT_MS"]),"c13774ae113c75c9","d12921203e124b0e"]}))
PY
backups="$(curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data @backup-query.json "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

state_body='{"sql":"SELECT last_run,batch_index,batch_count,scanned,candidates,attempted_writes,verified_writes,stopped,error_codes FROM maintenance_state WHERE state_key = ?","params":["latest"]}'
state="$(curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data "$state_body" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

node - <<'NODE' "$backups" "$state"
const fs=require("fs");
const b=JSON.parse(process.argv[2]),s=JSON.parse(process.argv[3]);
if(!b.success||!s.success)process.exit(2);
const rows=b.result?.[0]?.results||[];
const map=new Map(rows.map(r=>[String(r.item_hash||""),{count:Number(r.c||0),latest:Number(r.latest||0)}]));
const state=s.result?.[0]?.results?.[0]||{};
let errors=[];try{errors=JSON.parse(state.error_codes||"[]")}catch{}
const safe={
  breakingBad:map.get("c13774ae113c75c9")||{count:0,latest:0},
  northernIreland:map.get("d12921203e124b0e")||{count:0,latest:0},
  maintenance:{
    lastRun:Number(state.last_run||0),
    batch:Number(state.batch_index||0),
    batches:Number(state.batch_count||0),
    scanned:Number(state.scanned||0),
    candidates:Number(state.candidates||0),
    attempted:Number(state.attempted_writes||0),
    verified:Number(state.verified_writes||0),
    stopped:Number(state.stopped||0),
    errors:errors.map(x=>String(x).replace(/[^A-Za-z0-9_]/g,"").slice(0,40)).slice(0,6)
  }
};
fs.writeFileSync("v172-live-receipt.json",JSON.stringify(safe,null,2)+"\n");
for(const [name,v] of Object.entries({bb:safe.breakingBad,ni:safe.northernIreland})){
  fs.writeFileSync("v172-"+name+".txt","v172_"+name+"_b"+v.count+"_latest"+v.latest+"\n");
}
const m=safe.maintenance;
fs.writeFileSync("v172-maintenance.txt","v172_run_b"+m.batch+"of"+m.batches+"_c"+m.candidates+"_a"+m.attempted+"_v"+m.verified+"_s"+m.stopped+(m.errors.length?"_e"+m.errors.join("-"):"") + "\n");
console.log(JSON.stringify(safe));
NODE
