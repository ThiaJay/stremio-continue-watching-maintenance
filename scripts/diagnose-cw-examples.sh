#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY' > query.json
import json
hashes=["d50710896150aed6","5802dbc5fda6b745","c13774ae113c75c9"]
sql="""
SELECT
  o.item_hash,
  o.media_type,
  o.time_offset,
  o.time_watched,
  o.times_watched,
  o.flagged_watched,
  o.duration,
  o.last_watched,
  o.mtime,
  o.changed_at,
  o.marker_hash,
  o.video_hash,
  COALESCE(b.backup_count,0) AS backup_count,
  COALESCE(b.latest_backup,0) AS latest_backup
FROM watch_observations_v2 o
LEFT JOIN (
  SELECT item_hash, COUNT(*) AS backup_count, MAX(created_at) AS latest_backup
  FROM watch_backups
  GROUP BY item_hash
) b ON b.item_hash=o.item_hash
WHERE o.item_hash IN (?,?,?)
"""
print(json.dumps({"sql":sql,"params":hashes}))
PY

response="$(curl -fsS -X POST   -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   -H 'Content-Type: application/json'   --data @query.json   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

node - <<'NODE' "$response"
const fs=require("fs");
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const rows=x.result?.[0]?.results||[];
const expected=["d50710896150aed6","5802dbc5fda6b745","c13774ae113c75c9"];
const by=new Map(rows.map(r=>[String(r.item_hash||""),r]));
const safe=expected.map(hash=>{
  const r=by.get(hash);
  if(!r)return {hash,present:false};
  return {
    hash,
    present:true,
    media:String(r.media_type||""),
    offset:Number(r.time_offset||0),
    watched:Number(r.time_watched||0),
    times:Number(r.times_watched||0),
    flag:Number(r.flagged_watched||0),
    duration:Number(r.duration||0),
    last:Number(r.last_watched||0),
    mtime:Number(r.mtime||0),
    changed:Number(r.changed_at||0),
    marker:String(r.marker_hash||"").slice(0,16),
    video:String(r.video_hash||"").slice(0,16),
    backups:Number(r.backup_count||0),
    latestBackup:Number(r.latest_backup||0)
  };
});
fs.writeFileSync("cw-example-diagnosis.json",JSON.stringify(safe,null,2)+"\n");
const now=Date.now();
for(const r of safe){
  let context="cwex_"+r.hash+"_";
  if(!r.present)context+="obs0";
  else {
    const lastAge=r.last>0?Math.floor((now-r.last)/60000):-1;
    const mtimeAge=r.mtime>0?Math.floor((now-r.mtime)/60000):-1;
    const changedAge=r.changed>0?Math.floor((now-r.changed)/60000):-1;
    const backupAge=r.latestBackup>0?Math.floor((now-r.latestBackup)/60000):-1;
    context+=["obs1","off"+r.offset,"tw"+r.watched,"dur"+r.duration,"f"+r.flag,"lm"+lastAge,"mm"+mtimeAge,"cm"+changedAge,"b"+r.backups,"bm"+backupAge].join("_");
  }
  fs.writeFileSync("cwex-"+r.hash+".txt",context.slice(0,120)+"\n");
}
console.log(JSON.stringify(safe));
NODE
