#!/usr/bin/env bash
set -euo pipefail

bash scripts/validate-aiostreams-maelstrom.sh

expected_source="$(tr -cd '0-9a-f' < source-hash.txt | head -c 64)"
test "${#expected_source}" -eq 64

settings_before="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings_before" > settings-before-safe.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const out={
  compatibility_date:String(x.result?.compatibility_date||""),
  bindings:(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name))
};
process.stdout.write(JSON.stringify(out));
NODE

deployments_before="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/deployments")"
before_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_before")"
test -n "$before_id"

fetch_live_hash(){
  curl -fsS \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -D current-headers.txt \
    "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content/v2" \
    -o current-content.bin
  python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
import hashlib,re
headers=open("current-headers.txt","rb").read()
body=open("current-content.bin","rb").read()
matches=re.findall(br"(?im)^content-type:\s*([^\r\n]+)",headers)
ctype=matches[-1].decode("latin1").strip() if matches else ""
found=None
if ctype.lower().startswith("multipart/"):
    synthetic=("Content-Type: "+ctype+"\r\nMIME-Version: 1.0\r\n\r\n").encode("latin1")+body
    msg=BytesParser(policy=default).parsebytes(synthetic)
    if not msg.is_multipart():
        raise SystemExit(2)
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

current_source="$(fetch_live_hash)"
if [ "$current_source" != "$expected_source" ]; then
  echo "::error::Production source changed after validation"
  exit 3
fi

candidate_hash="$(sha256sum patched-worker.mjs | awk '{print $1}')"
test "${#candidate_hash}" -eq 64

printf '%s' '{"main_module":"worker.js"}' > metadata.json
response="$(curl -fsS -X PUT \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -F 'metadata=@metadata.json;type=application/json' \
  -F 'worker.js=@patched-worker.mjs;type=application/javascript+module' \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content")"
node -e 'const x=JSON.parse(process.argv[1]);if(!x.success){console.error(JSON.stringify(x.errors||[]));process.exit(1)};console.log("content_update_accepted")' "$response"

settings_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings_after" > settings-after-safe.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const out={
  compatibility_date:String(x.result?.compatibility_date||""),
  bindings:(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name))
};
process.stdout.write(JSON.stringify(out));
NODE
cmp settings-before-safe.json settings-after-safe.json

deployments_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/deployments")"
after_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_after")"
test -n "$after_id"
if [ "$after_id" = "$before_id" ]; then
  echo "::error::No new deployment observed"
  exit 4
fi

post_hash="$(fetch_live_hash)"
if [ "$post_hash" != "$candidate_hash" ]; then
  echo "::error::Post deployment source does not match validated candidate"
  exit 5
fi

node --check patched-worker.mjs
printf '%s\n' "$after_id" > deployment-id.txt
printf '%s\n' "$candidate_hash" > deployed-source-hash.txt
echo "deployment_verified"
