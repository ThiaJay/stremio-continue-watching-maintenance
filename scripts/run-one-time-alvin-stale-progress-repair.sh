#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN required}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID required}"
: "${CLOUDFLARE_D1_DATABASE_ID:?CLOUDFLARE_D1_DATABASE_ID required}"
: "${SCRIPT_NAME:?SCRIPT_NAME required}"
: "${PROD_SOURCE_COMMIT:?PROD_SOURCE_COMMIT required}"
: "${ALVIN_HASH:?ALVIN_HASH required}"

[[ "${ALVIN_HASH}" =~ ^[0-9a-f]{16}$ ]]

fetch_live_source_hash() {
  curl -fsS \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -D /tmp/live-headers.txt \
    "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/content/v2" \
    -o /tmp/live-content.bin
  python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
import hashlib,re
headers=open("/tmp/live-headers.txt","rb").read()
body=open("/tmp/live-content.bin","rb").read()
m=re.findall(br"(?im)^content-type:\s*([^\r\n]+)",headers)
ctype=m[-1].decode("latin1").strip() if m else ""
found=None
if ctype.lower().startswith("multipart/"):
    synthetic=("Content-Type: "+ctype+"\r\nMIME-Version: 1.0\r\n\r\n").encode("latin1")+body
    msg=BytesParser(policy=default).parsebytes(synthetic)
    for p in msg.iter_parts():
        name=p.get_param("name",header="content-disposition") or p.get_filename() or ""
        if name=="worker.js":
            found=p.get_payload(decode=True) or b""
            break
else:
    found=body
if found is None:
    raise SystemExit("worker source missing")
print(hashlib.sha256(found).hexdigest())
PY
}

deploy_worker() {
  local file="$1"
  cp "$file" /tmp/upload-worker.js
  printf '%s' '{"main_module":"worker.js"}' > /tmp/metadata.json
  local code
  code="$(curl -sS -o /tmp/deploy-response.json -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -F 'metadata=@/tmp/metadata.json;type=application/json' \
    -F 'worker.js=@/tmp/upload-worker.js;filename=worker.js;type=application/javascript+module' \
    "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/content")"
  DEPLOY_HTTP_CODE="$code" node -e '
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("/tmp/deploy-response.json","utf8"));
const http=String(process.env.DEPLOY_HTTP_CODE||"");
if(!x.success||!/^2\d\d$/.test(http)) process.exit(1);
'
}

d1_query() {
  local body="$1"
  curl -fsS -X POST \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$body" \
    "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/d1/database/${CLOUDFLARE_D1_DATABASE_ID}/query"
}

delete_target() {
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({sql:"DELETE FROM repair_targets_v1 WHERE item_hash=?",params:[process.env.ALVIN_HASH]}))')"
  d1_query "$body" >/tmp/delete-target.json || return 1
  node -e 'const x=JSON.parse(require("fs").readFileSync("/tmp/delete-target.json","utf8"));if(!x.success)process.exit(2)'
}

echo "stage=source_precheck"
git cat-file -e "${PROD_SOURCE_COMMIT}^{commit}"
git show "${PROD_SOURCE_COMMIT}:src/worker.js" > /tmp/prod-worker.js
prod_hash="$(sha256sum /tmp/prod-worker.js | awk '{print $1}')"
test "${#prod_hash}" -eq 64

echo "stage=live_source_hash_before"
live_before="$(fetch_live_source_hash)"
if [ "$live_before" != "$prod_hash" ]; then
  echo "::error::Production Worker source has drifted from the accepted v1.7.3 source"
  exit 2
fi

echo "stage=settings_before"
settings_before="$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/settings")"
node -e '
const x=JSON.parse(process.argv[1]);
if(!x.success)process.exit(2);
const bindings=(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
if(!bindings.some(v=>(v.type==="d1"||v.type==="d1_database")&&v.name==="BACKUP_DB"))process.exit(3);
if(!bindings.some(v=>v.name==="METADATA"))process.exit(4);
if(!bindings.some(v=>v.name==="STREMIO_AUTHKEY"&&v.type.includes("secret")))process.exit(5);
if(!bindings.some(v=>v.name==="BACKUP_ENCRYPTION_KEY"&&v.type.includes("secret")))process.exit(6);
if(!bindings.some(v=>v.name==="EXPECTED_ACCOUNT_FINGERPRINT"&&v.type.includes("secret")))process.exit(7);
process.stdout.write(JSON.stringify({bindings,compatibility_date:String(x.result?.compatibility_date||"")}));
' "$settings_before" > /tmp/settings-before-safe.json

echo "stage=schedules_before"
schedules_before="$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_before"

existing_body="$(node -e 'process.stdout.write(JSON.stringify({sql:"SELECT item_hash,attempts,last_attempt,expires_at FROM repair_targets_v1 WHERE item_hash=?",params:[process.env.ALVIN_HASH]}))')"
echo "stage=d1_existing_target"
existing="$(d1_query "$existing_body")"
node -e 'const x=JSON.parse(process.argv[1]);if(!x.success)process.exit(2);if((x.result?.[0]?.results||[]).length)process.exit(3)' "$existing"

python3 - <<'PY'
from pathlib import Path
source=Path("/tmp/prod-worker.js").read_text()
rule=Path("scripts/one-time-alvin-stale-progress-rule.js").read_text()
anchor="async function reportedRepairDecision(item,byId,observations,env,now,deps={}){"
if source.count(anchor)!=1:
    raise SystemExit("reported repair anchor missing or ambiguous")
source=source.replace(anchor,rule+"\n"+anchor,1)
nearzero="  const nearZero=nearZeroResumeDecision(item,now);"
replacement='  const oneTimeReported=oneTimeReportedWatchedMovieProgressDecision(item,now);\n  if(oneTimeReported)return oneTimeReported;\n'+nearzero
if source.count(nearzero)!=1:
    raise SystemExit("reported repair decision insertion anchor missing or ambiguous")
source=source.replace(nearzero,replacement,1)
Path("/tmp/repair-worker.js").write_text(source)
PY

node --check /tmp/repair-worker.js
repair_hash="$(sha256sum /tmp/repair-worker.js | awk '{print $1}')"

restore_required=0
target_inserted=0
cleanup() {
  local rc=$?
  set +e
  if [ "$target_inserted" = "1" ]; then
    delete_target
  fi
  if [ "$restore_required" = "1" ]; then
    deploy_worker /tmp/prod-worker.js
  fi
  exit "$rc"
}
trap cleanup EXIT

echo "stage=deploy_temporary_worker"
deploy_worker /tmp/repair-worker.js
restore_required=1
live_repair="$(fetch_live_source_hash)"
test "$live_repair" = "$repair_hash"

settings_repair="$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/settings")"
node -e '
const before=JSON.parse(require("fs").readFileSync("/tmp/settings-before-safe.json","utf8"));
const after=JSON.parse(process.argv[1]);
if(!after.success)process.exit(2);
const bindings=(after.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
const safe={bindings,compatibility_date:String(after.result?.compatibility_date||"")};
if(JSON.stringify(before)!==JSON.stringify(safe))process.exit(3);
' "$settings_repair"

schedules_repair="$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_repair"

started="$(date +%s%3N)"
expires="$(( started + 30*60*1000 ))"
insert_body="$(STARTED="$started" EXPIRES="$expires" node -e 'process.stdout.write(JSON.stringify({sql:"INSERT INTO repair_targets_v1 (item_hash,created_at,expires_at,attempts,last_attempt) VALUES (?,?,?,0,0)",params:[process.env.ALVIN_HASH,Number(process.env.STARTED),Number(process.env.EXPIRES)]}))')"
insert_response="$(d1_query "$insert_body")"
node -e 'const x=JSON.parse(process.argv[1]);if(!x.success)process.exit(2)' "$insert_response"
target_inserted=1

echo "alvin_repair_target_armed"

success=0
for attempt in $(seq 1 52); do
  check_body="$(node -e 'process.stdout.write(JSON.stringify({sql:"SELECT item_hash,attempts,last_attempt FROM repair_targets_v1 WHERE item_hash=?",params:[process.env.ALVIN_HASH]}))')"
  check="$(d1_query "$check_body")"
  count="$(node -e 'const x=JSON.parse(process.argv[1]);if(!x.success)process.exit(2);process.stdout.write(String((x.result?.[0]?.results||[]).length))' "$check")"
  if [ "$count" = "0" ]; then
    backup_body="$(STARTED="$started" node -e 'process.stdout.write(JSON.stringify({sql:"SELECT backup_key,created_at,item_hash FROM watch_backups WHERE item_hash=? AND created_at>=? ORDER BY created_at DESC LIMIT 5",params:[process.env.ALVIN_HASH,Number(process.env.STARTED)]}))')"
    backups="$(d1_query "$backup_body")"
    backup_count="$(node -e 'const x=JSON.parse(process.argv[1]);if(!x.success)process.exit(2);process.stdout.write(String((x.result?.[0]?.results||[]).length))' "$backups")"
    if [ "$backup_count" -ge 1 ]; then
      success=1
      echo "alvin_progress_repair_verified backup_count=${backup_count}"
      break
    fi
    echo "::error::Repair target cleared without a new encrypted backup"
    exit 8
  fi
  sleep 15
done

if [ "$success" != "1" ]; then
  state_body="$(node -e 'process.stdout.write(JSON.stringify({sql:"SELECT attempts,last_attempt FROM repair_targets_v1 WHERE item_hash=?",params:[process.env.ALVIN_HASH]}))')"
  state="$(d1_query "$state_body")"
  attempts="$(node -e 'const x=JSON.parse(process.argv[1]);const r=x.result?.[0]?.results?.[0]||{};process.stdout.write(String(Number(r.attempts)||0))' "$state")"
  echo "::error::Alvin repair did not verify within the guarded window, attempts=${attempts}"
  exit 9
fi

target_inserted=0
deploy_worker /tmp/prod-worker.js
restore_required=0

live_after="$(fetch_live_source_hash)"
test "$live_after" = "$prod_hash"

settings_after="$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/settings")"
node -e '
const before=JSON.parse(require("fs").readFileSync("/tmp/settings-before-safe.json","utf8"));
const after=JSON.parse(process.argv[1]);
if(!after.success)process.exit(2);
const bindings=(after.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
const safe={bindings,compatibility_date:String(after.result?.compatibility_date||"")};
if(JSON.stringify(before)!==JSON.stringify(safe))process.exit(3);
' "$settings_after"

schedules_after="$(curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_after"

final_target_body="$(node -e 'process.stdout.write(JSON.stringify({sql:"SELECT item_hash FROM repair_targets_v1 WHERE item_hash=?",params:[process.env.ALVIN_HASH]}))')"
final_target="$(d1_query "$final_target_body")"
node -e 'const x=JSON.parse(process.argv[1]);if(!x.success)process.exit(2);if((x.result?.[0]?.results||[]).length)process.exit(3)' "$final_target"

echo "production_worker_restored_and_alvin_repair_closed"
