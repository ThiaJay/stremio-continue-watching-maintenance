#!/usr/bin/env bash
set -euo pipefail

printf "deployment_check\n" > cw-v172-acceptance-stage.txt
for attempt in $(seq 1 30); do
  deployments="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/deployments")"
  active_info="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);const created=Date.parse(d.created_on||d.createdAt||d.created_at||"");if(!Number.isFinite(created))process.exit(3);process.stdout.write(JSON.stringify({id:String(d.id||""),created}))' "$deployments")"
  active_id="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$active_info")"
  deployment_ms="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).created))' "$active_info")"
  active_normalized="$(printf '%s' "$active_id" | tr -cd 'A-Za-z0-9')"
  case "$active_normalized" in
    "$EXPECTED_DEPLOYMENT_PREFIX"*) ;;
    *)
      current_prefix="$(printf '%s' "$active_normalized" | head -c 12)"
      printf 'deployment_mismatch_%s\n' "$current_prefix" > cw-v172-acceptance-stage.txt
      echo "::error::v1.7.2 expected deployment prefix does not match current deployment"
      exit 2
      ;;
  esac

  printf "backup_query\n" > cw-v172-acceptance-stage.txt
  export DEPLOYMENT_MS="$deployment_ms"
  backup_body="$(node -e 'console.log(JSON.stringify({sql:"SELECT created_at,item_hash FROM watch_backups WHERE item_hash = ? AND created_at >= ? ORDER BY created_at DESC LIMIT 1",params:[process.env.TARGET_ITEM_HASH,Number(process.env.DEPLOYMENT_MS)]}))')"
  backup="$(curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data "$backup_body" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

  printf "state_query\n" > cw-v172-acceptance-stage.txt
  state_body='{"sql":"SELECT last_run,batch_index,batch_count,scanned,candidates,attempted_writes,verified_writes,stopped,error_codes FROM maintenance_state WHERE state_key = ?","params":["latest"]}'
  state="$(curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' --data "$state_body" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query")"

  found="$(node -e 'const x=JSON.parse(process.argv[1]);const r=x.result?.[0]?.results?.[0];if(!x.success)process.exit(2);if(r)process.stdout.write(JSON.stringify({created_at:Number(r.created_at)||0,item_hash:String(r.item_hash||"")}))' "$backup")"
  if [ -n "$found" ]; then
    printf "verify\n" > cw-v172-acceptance-stage.txt
    node - <<'NODE' "$found" "$state"
const fs=require("fs");
const backup=JSON.parse(process.argv[2]);
const x=JSON.parse(process.argv[3]);
const r=x.result?.[0]?.results?.[0];
if(!x.success||!r) process.exit(2);
let errors=[];
try{errors=JSON.parse(r.error_codes||"[]")}catch{}
const bad=["WRITE_FAILED","WRITE_UNCONFIRMED","READBACK_OFFSET_MISMATCH","UNRELATED_STATE_CHANGED","ITEM_CHANGED_BEFORE_WRITE","ACCOUNT_CHANGED"];
const healthy=
  Number(r.last_run)>=Number(backup.created_at)-120000 &&
  Number(r.verified_writes)>0 &&
  Number(r.attempted_writes)>0 &&
  Number(r.stopped)===0 &&
  !bad.some(code=>errors.includes(code));
if(!healthy) process.exit(3);
const context=[
  "cw-v172-accepted",
  "b"+String(r.batch_index||0)+"of"+String(r.batch_count||0),
  "c"+String(r.candidates||0),
  "a"+String(r.attempted_writes||0),
  "v"+String(r.verified_writes||0)
].join("_");
fs.writeFileSync("cw-v172-acceptance.txt",context+"\n");
fs.writeFileSync("cw-v172-acceptance.json",JSON.stringify({
  backupCreatedAt:Number(backup.created_at),
  lastRun:Number(r.last_run),
  batchIndex:Number(r.batch_index||0),
  batchCount:Number(r.batch_count||0),
  scanned:Number(r.scanned||0),
  candidates:Number(r.candidates||0),
  attemptedWrites:Number(r.attempted_writes||0),
  verifiedWrites:Number(r.verified_writes||0),
  stopped:Number(r.stopped||0),
  errorCodes:errors
},null,2)+"\n");
NODE
    printf "passed\n" > cw-v172-acceptance-stage.txt
    echo "v1.7.2 exact-item acceptance passed"
    exit 0
  fi

  printf "waiting_%s\n" "$attempt" > cw-v172-acceptance-stage.txt
  echo "target not yet repaired attempt $attempt"
  sleep 30
done

echo "::error::No verified v1.7.2 target cleanup within bounded acceptance window"
exit 1
