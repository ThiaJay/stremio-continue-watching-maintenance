#!/usr/bin/env bash
set -euo pipefail

payload='{"sql":"SELECT item_hash,observed_at,payload FROM diagnostic_results_v1 WHERE item_hash IN (?,?,?,?) ORDER BY item_hash","params":["d50710896150aed6","5802dbc5fda6b745","c13774ae113c75c9","d12921203e124b0e"]}'
response="$(curl -fsS -X POST   -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   -H 'Content-Type: application/json'   --data "$payload"   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

node - <<'NODE' "$response"
const fs=require("fs");
const x=JSON.parse(process.argv[2]);
if(!x.success)process.exit(2);
const rows=x.result?.[0]?.results||[];
const expected=["d50710896150aed6","5802dbc5fda6b745","c13774ae113c75c9","d12921203e124b0e"];
const by=new Map(rows.map(r=>[String(r.item_hash||""),r]));
for(const hash of expected){
  const row=by.get(hash);
  let context="cwdiag_"+hash+"_";
  if(!row){
    context+="pending";
  }else{
    let p={};
    try{p=JSON.parse(String(row.payload||"{}"));}catch{}
    if(!p.present)context+="absent";
    else{
      const reason=String(p.completionReason||p.transitionReason||p.aliasReason||"none").replace(/[^A-Za-z0-9_]/g,"").slice(0,36);
      const meta=String(p.metadataStatus||"").replace(/[^A-Za-z0-9_]/g,"").slice(0,22);
      context+=[
        "present",
        "off"+Number(p.timeOffset||0),
        "ageh"+Math.floor(Number(p.playbackAgeMs||0)/3600000),
        "rel"+Number(p.releasedCount||0),
        "wr"+Number(p.watchedReleasedCount||0),
        "all"+Number(p.allReleasedWatched||0),
        "pw"+Number(p.pointerWatched||0),
        "pf"+Number(p.pointerFinal||0),
        "anc"+Number(p.ancientSelector||0),
        "m"+meta,
        "r"+reason
      ].join("_");
    }
  }
  fs.writeFileSync("cwdiag-"+hash+".txt",context.slice(0,160)+"\n");
}
console.log("diagnostic_results_read");
NODE
