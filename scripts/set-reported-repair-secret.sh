#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?}"
: "${CLOUDFLARE_ACCOUNT_ID:?}"
: "${SCRIPT_NAME:?}"
: "${REPORTED_HASH_A:?}"
: "${REPORTED_HASH_B:?}"

printf 'precheck
' > secret-stage.txt

fetch_live_source_hash(){
  curl -fsS     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"     -D secret-live-headers.txt     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content/v2"     -o secret-live-content.bin
  python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
import hashlib,re
headers=open("secret-live-headers.txt","rb").read()
body=open("secret-live-content.bin","rb").read()
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
    raise SystemExit(2)
print(hashlib.sha256(found).hexdigest())
PY
}

source_before="$(fetch_live_source_hash)"
test "${#source_before}" -eq 64

settings_before="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings_before" > secret-settings-before.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const bindings=(x.result?.bindings||[])
  .map(v=>({name:String(v.name||""),type:String(v.type||"")}))
  .sort((a,b)=>a.name.localeCompare(b.name));
process.stdout.write(JSON.stringify({bindings,compatibility_date:String(x.result?.compatibility_date||"")}));
NODE

schedules_before="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_before"

deployments_before="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/deployments")"
before_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_before")"
test -n "$before_id"

printf 'build_payload
' > secret-stage.txt
expires_ms="$(( $(date +%s%3N) + 24*60*60*1000 ))"
export EXPIRES_MS="$expires_ms"
payload="$(node -e 'const hs=[process.env.REPORTED_HASH_A,process.env.REPORTED_HASH_B].map(x=>String(x||"").toLowerCase());if(hs.some(x=>!/^[0-9a-f]{16}$/.test(x)))process.exit(2);process.stdout.write(JSON.stringify({expiresAt:Number(process.env.EXPIRES_MS),hashes:[...new Set(hs)]}))')"

printf 'secret_put
' > secret-stage.txt
printf '%s' "$payload" | npx wrangler secret put REPORTED_REPAIR_TARGETS --name "$SCRIPT_NAME"

printf 'verify_settings
' > secret-stage.txt
settings_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings_before" "$settings_after"
const before=JSON.parse(process.argv[2]),after=JSON.parse(process.argv[3]);
if(!before.success||!after.success)process.exit(2);
const b=(before.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
const a=(after.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
const added=a.filter(v=>!b.some(x=>x.name===v.name&&x.type===v.type));
const missing=b.filter(v=>!a.some(x=>x.name===v.name&&x.type===v.type));
if(missing.length)process.exit(3);
if(!added.some(v=>v.name==="REPORTED_REPAIR_TARGETS"&&v.type==="secret_text"))process.exit(4);
if(added.some(v=>v.name!=="REPORTED_REPAIR_TARGETS"))process.exit(5);
if(String(before.result?.compatibility_date||"")!==String(after.result?.compatibility_date||""))process.exit(6);
NODE

schedules_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_after"

printf 'verify_source
' > secret-stage.txt
source_after="$(fetch_live_source_hash)"
if [ "$source_after" != "$source_before" ]; then
  echo "::error::Worker source changed while setting reported repair secret"
  exit 7
fi

deployments_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/deployments")"
after_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_after")"
test -n "$after_id"

printf '%s
' "$after_id" > reported-secret-deployment-id.txt
printf '%s
' "$expires_ms" > reported-secret-expires.txt
printf 'passed
' > secret-stage.txt
echo "reported_repair_secret_verified"
