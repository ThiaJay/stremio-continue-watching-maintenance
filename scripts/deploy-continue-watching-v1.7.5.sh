#!/usr/bin/env bash
set -euo pipefail

test -n "${EXPECTED_SOURCE_COMMIT:-}"
test -n "${CLOUDFLARE_API_TOKEN:-}"
test -n "${CLOUDFLARE_ACCOUNT_ID:-}"
test -n "${SCRIPT_NAME:-}"
test "$EXPECTED_SOURCE_COMMIT" = "f53d301db50f778aab20379f4c0c58a80e4c61d6"
git cat-file -e "$EXPECTED_SOURCE_COMMIT^{commit}"

git show "$EXPECTED_SOURCE_COMMIT:package.json" > release-package.json
git show "$EXPECTED_SOURCE_COMMIT:src/worker.js" > release-worker.js

version="$(node -p "require('./release-package.json').version")"
test "$version" = "1.7.5"
node --check release-worker.js
grep -Fq 'const NEAR_END_THRESHOLD=0.98;' release-worker.js
grep -Fq 'const NEAR_END_MAX_REMAINING_MS=2*60*1000;' release-worker.js
grep -Fq 'const MAX_FINISHED_RESUME_WRITES=4;' release-worker.js
grep -Fq 'resumeOnlyMutationInvariant' release-worker.js

source_hash="$(sha256sum release-worker.js | awk '{print $1}')"
test "${#source_hash}" -eq 64

auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
base="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME"

settings_before="$(curl -fsS "${auth[@]}" "$base/settings")"
node - <<'NODE' "$settings_before" > settings-before-safe.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const bindings=(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
if(!bindings.some(v=>(v.type==="d1"||v.type==="d1_database"))||!bindings.some(v=>v.name==="METADATA")) process.exit(3);
process.stdout.write(JSON.stringify({bindings,compatibility_date:String(x.result?.compatibility_date||"")}));
NODE

schedules_before="$(curl -fsS "${auth[@]}" "$base/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_before"

deployments_before="$(curl -fsS "${auth[@]}" "$base/deployments")"
before_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_before")"
test -n "$before_id"

printf '%s' '{"main_module":"worker.js"}' > metadata.json
http_code="$(curl -sS -o deploy-response.json -w '%{http_code}' -X PUT \
  "${auth[@]}" \
  -F 'metadata=@metadata.json;type=application/json' \
  -F 'worker.js=@release-worker.js;filename=worker.js;type=application/javascript+module' \
  "$base/content")"
export DEPLOY_HTTP_CODE="$http_code"
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("deploy-response.json","utf8"));
const http=String(process.env.DEPLOY_HTTP_CODE||"");
if(!x.success||!/^2\d\d$/.test(http)){
  const e=x.errors?.[0]||{};
  console.error("deploy_rejected",http,String(e.code||"unknown"));
  process.exit(1);
}
NODE

settings_after="$(curl -fsS "${auth[@]}" "$base/settings")"
node - <<'NODE' "$settings_after" > settings-after-safe.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const bindings=(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name));
process.stdout.write(JSON.stringify({bindings,compatibility_date:String(x.result?.compatibility_date||"")}));
NODE
cmp settings-before-safe.json settings-after-safe.json

schedules_after="$(curl -fsS "${auth[@]}" "$base/schedules")"
node -e 'const x=JSON.parse(process.argv[1]);const s=x.result?.schedules||[];if(!x.success||!s.some(v=>v.cron==="*/10 * * * *"))process.exit(2)' "$schedules_after"

deployments_after="$(curl -fsS "${auth[@]}" "$base/deployments")"
after_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_after")"
test -n "$after_id"
test "$after_id" != "$before_id"

curl -fsS "${auth[@]}" -D live-headers.txt "$base/content/v2" -o live-content.bin
export EXPECTED_SOURCE_HASH="$source_hash"
python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
import hashlib,re,os
headers=open("live-headers.txt","rb").read()
body=open("live-content.bin","rb").read()
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
digest=hashlib.sha256(found).hexdigest()
if digest!=os.environ["EXPECTED_SOURCE_HASH"]:
    raise SystemExit(f"source mismatch {digest}")
print("source_match",digest)
PY

echo "deployment_verified id_prefix=${after_id:0:12} source_prefix=${source_hash:0:16}"
