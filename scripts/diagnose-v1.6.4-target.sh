#!/usr/bin/env bash
set -euo pipefail

backupBody="$(node -e 'console.log(JSON.stringify({sql:"SELECT COUNT(*) AS c, MAX(created_at) AS latest FROM watch_backups WHERE item_hash = ? AND created_at >= ?",params:[process.env.TARGET_ITEM_HASH,Number(process.env.DEPLOYED_AT_MS)]}))')"
backup="$(curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data "$backupBody" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

obsBody="$(node -e 'console.log(JSON.stringify({sql:"SELECT time_offset,time_watched,times_watched,flagged_watched,duration,last_watched,mtime,changed_at FROM watch_observations_v2 WHERE item_hash = ? LIMIT 1",params:[process.env.TARGET_ITEM_HASH]}))')"
obs="$(curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data "$obsBody" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

stateBody='{"sql":"SELECT last_run,continue_watching_series,batch_index,batch_count,scanned,candidates,attempted_writes,verified_writes,stopped,error_codes FROM maintenance_state WHERE state_key = ?","params":["latest"]}'
state="$(curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data "$stateBody" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

node - <<'NODE' "$backup" "$obs" "$state"
const fs=require("fs");
const b=JSON.parse(process.argv[2]);
const o=JSON.parse(process.argv[3]);
const s=JSON.parse(process.argv[4]);
if(!b.success||!o.success||!s.success) process.exit(2);
const br=b.result?.[0]?.results?.[0]||{};
const or=o.result?.[0]?.results?.[0]||null;
const sr=s.result?.[0]?.results?.[0]||{};
const safe={
  backups:Number(br.c||0),
  backupLatest:Number(br.latest||0),
  observation:or?{
    offset:Number(or.time_offset||0),
    watched:Number(or.time_watched||0),
    times:Number(or.times_watched||0),
    flag:Number(or.flagged_watched||0),
    duration:Number(or.duration||0),
    last:Number(or.last_watched||0),
    mtime:Number(or.mtime||0),
    changed:Number(or.changed_at||0)
  }:null,
  maintenance:{
    lastRun:Number(sr.last_run||0),
    series:Number(sr.continue_watching_series||0),
    batch:Number(sr.batch_index||0),
    batches:Number(sr.batch_count||0),
    scanned:Number(sr.scanned||0),
    candidates:Number(sr.candidates||0),
    attempted:Number(sr.attempted_writes||0),
    verified:Number(sr.verified_writes||0),
    stopped:Number(sr.stopped||0)
  }
};
fs.writeFileSync("cw-diagnosis.json",JSON.stringify(safe,null,2)+"\n");
const o2=safe.observation;
const m=safe.maintenance;
let context="cw-target_b"+safe.backups;
context+=o2?"_off"+o2.offset+"_tw"+o2.watched+"_f"+o2.flag:"_obs-missing";
context+="_batch"+m.batch+"of"+m.batches+"_c"+m.candidates+"_v"+m.verified;
fs.writeFileSync("cw-diagnosis-context.txt",context.slice(0,96)+"\n");
console.log(JSON.stringify(safe));
NODE
