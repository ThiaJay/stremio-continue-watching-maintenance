#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?}"
: "${CLOUDFLARE_ACCOUNT_ID:?}"
: "${SCRIPT_NAME:?}"

printf 'precheck\n' > secret-cleanup-stage.txt

fetch_live_source_hash(){
  curl -fsS     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"     -D cleanup-live-headers.txt     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content/v2"     -o cleanup-live-content.bin
  python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
import hashlib,re
headers=open("cleanup-live-headers.txt","rb").read()
body=open("cleanup-live-content.bin","rb").read()
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
node - <<'NODE' "$settings_before" > cleanup-settings-before.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const bindings=(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
if(!bindings.some(v=>v.name==="REPORTED_REPAIR_TARGETS"&&v.type==="secret_text")) process.exit(3);
process.stdout.write(JSON.stringify({bindings,compatibility_date:String(x.result?.compatibility_date||"")}));
NODE

schedules_before="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_before"

printf 'secret_delete\n' > secret-cleanup-stage.txt
delete_http="$(curl -sS -o secret-delete-response.json -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Accept: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/secrets/REPORTED_REPAIR_TARGETS")"
export SECRET_DELETE_HTTP="$delete_http"
node - <<'NODE'
const fs=require("fs");
const http=String(process.env.SECRET_DELETE_HTTP||"unknown");
let x={};
try{x=JSON.parse(fs.readFileSync("secret-delete-response.json","utf8"))}catch{}
if(/^2\d\d$/.test(http)&&x.success!==false)process.exit(0);
if(http==="404")process.exit(0);
const e=x.errors?.[0]||{};
const code=String(e.code??"unknown").replace(/[^A-Za-z0-9]/g,"").slice(0,24);
const safe=String(e.message||x.message||"")
  .replace(/https?:\/\/\S+/gi,"URL")
  .replace(/[A-Fa-f0-9]{24,}/g,"HEX")
  .replace(/[^A-Za-z0-9 ]/g," ")
  .replace(/\s+/g," ")
  .trim()
  .split(" ")
  .slice(0,10)
  .join("")
  .slice(0,64)||"nomessage";
fs.writeFileSync("secret-cleanup-stage.txt","secret_delete_http"+http+"_code"+code+"_"+safe+"\n");
process.exit(2);
NODE

printf 'verify_settings\n' > secret-cleanup-stage.txt
settings_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings_before" "$settings_after"
const before=JSON.parse(process.argv[2]),after=JSON.parse(process.argv[3]);
if(!before.success||!after.success)process.exit(2);
const b=(before.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
const a=(after.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
if(a.some(v=>v.name==="REPORTED_REPAIR_TARGETS"))process.exit(3);
const expected=b.filter(v=>v.name!=="REPORTED_REPAIR_TARGETS");
if(JSON.stringify(a)!==JSON.stringify(expected))process.exit(4);
if(String(before.result?.compatibility_date||"")!==String(after.result?.compatibility_date||""))process.exit(5);
NODE

schedules_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_after"

printf 'verify_source\n' > secret-cleanup-stage.txt
source_after="$(fetch_live_source_hash)"
test "$source_after" = "$source_before"

deployments_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/deployments")"
after_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_after")"
test -n "$after_id"

printf '%s\n' "$after_id" > reported-secret-cleanup-deployment-id.txt
printf '%s\n' "$source_after" > reported-secret-cleanup-source-hash.txt
printf 'passed\n' > secret-cleanup-stage.txt
echo "reported_repair_secret_removed_verified"
