#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY' > query.json
import json
targets=["c13774ae113c75c9","d12921203e124b0e","d50710896150aed6"]
sql="""
SELECT d.item_hash,
       d.observed_at,
       d.payload,
       COALESCE(b.backup_count,0) AS backup_count,
       COALESCE(b.latest_backup,0) AS latest_backup
FROM diagnostic_results_v1 d
LEFT JOIN (
  SELECT item_hash, COUNT(*) AS backup_count, MAX(created_at) AS latest_backup
  FROM watch_backups
  GROUP BY item_hash
) b ON b.item_hash=d.item_hash
WHERE d.item_hash IN (?,?,?)
"""
print(json.dumps({"sql":sql,"params":targets}))
PY

response="$(curl -fsS -X POST   -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   -H 'Content-Type: application/json'   --data @query.json   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

node - <<'NODE' "$response"
const fs=require("fs");
const x=JSON.parse(process.argv[2]);
if(!x.success)process.exit(2);
const rows=x.result?.[0]?.results||[];
const expected=["c13774ae113c75c9","d12921203e124b0e","d50710896150aed6"];
const by=new Map(rows.map(r=>[String(r.item_hash||""),r]));
const out={};
for(const hash of expected){
  const r=by.get(hash);
  if(!r){out[hash]={present:false};continue;}
  let payload={};
  try{payload=JSON.parse(r.payload||"{}")}catch{}
  out[hash]={
    present:true,
    observedAt:Number(r.observed_at||0),
    offset:Number(payload.timeOffset||0),
    completionReason:String(payload.completionReason||""),
    allReleasedWatched:Number(payload.allReleasedWatched||0),
    pointerWatched:Number(payload.pointerWatched||0),
    backupCount:Number(r.backup_count||0),
    latestBackup:Number(r.latest_backup||0)
  };
}
fs.writeFileSync("final-cw-proof.json",JSON.stringify(out,null,2)+"\n");
for(const [hash,v] of Object.entries(out)){
  let context="cwfinal_"+hash+"_";
  if(!v.present)context+="missing";
  else context+="off"+v.offset+"_b"+v.backupCount+"_all"+v.allReleasedWatched+"_pw"+v.pointerWatched;
  fs.writeFileSync("cwfinal-"+hash+".txt",context.slice(0,96)+"\n");
}
console.log(JSON.stringify(out));
NODE
