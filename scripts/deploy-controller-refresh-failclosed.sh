#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="stremio-addon-binding-controller"
EXPECTED_SOURCE_SHA256="764d05dad971e6c5ae87300dbc0ed0afb0e08dc444e5ff101840559a00130700"

curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -D headers.txt   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content/v2"   -o content.bin

python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
from pathlib import Path
import hashlib,re,os
headers=Path("headers.txt").read_bytes(); body=Path("content.bin").read_bytes()
matches=re.findall(br"(?im)^content-type:\s*([^\r\n]+)",headers)
ctype=matches[-1].decode("latin1").strip() if matches else ""
found=None
if ctype.lower().startswith("multipart/"):
    synthetic=("Content-Type: "+ctype+"\r\nMIME-Version: 1.0\r\n\r\n").encode("latin1")+body
    msg=BytesParser(policy=default).parsebytes(synthetic)
    for p in msg.iter_parts():
        raw=p.get_payload(decode=True) or b""
        if b"refreshWrapperDescriptor" in raw and b"addonCollectionSet" in raw:
            found=raw; break
else:
    found=body
if found is None: raise SystemExit("controller module not found")
digest=hashlib.sha256(found).hexdigest()
if digest != os.environ["EXPECTED_SOURCE_SHA256"]:
    raise SystemExit(f"production source changed: {digest}")
Path("live-controller.mjs").write_bytes(found)
print("source_hash_ok",digest)
PY

python3 scripts/patch-controller-refresh-failclosed.py
node --check patched-controller.mjs

grep -q 'wrapper_manifest_refresh_failed' patched-controller.mjs
grep -q 'errors.push(provider + ":" + code)' patched-controller.mjs
grep -q 'refreshWrapperDescriptor' patched-controller.mjs

settings_before="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings_before" > settings-before-safe.json
const x=JSON.parse(process.argv[2]); if(!x.success) process.exit(2);
process.stdout.write(JSON.stringify({
  compatibility_date:String(x.result?.compatibility_date||""),
  bindings:(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name))
}));
NODE

candidate_hash="$(sha256sum patched-controller.mjs | awk '{print $1}')"
printf '%s' '{"main_module":"worker.js"}' > metadata.json
curl -fsS -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   -F 'metadata=@metadata.json;type=application/json'   -F 'worker.js=@patched-controller.mjs;filename=worker.js;type=application/javascript+module'   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content"   > deploy-response.json
node -e 'const x=require("./deploy-response.json"); if(!x.success) process.exit(2)'

settings_after="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings_after" > settings-after-safe.json
const x=JSON.parse(process.argv[2]); if(!x.success) process.exit(2);
process.stdout.write(JSON.stringify({
  compatibility_date:String(x.result?.compatibility_date||""),
  bindings:(x.result?.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name))
}));
NODE
cmp settings-before-safe.json settings-after-safe.json

curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -D post-headers.txt   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content/v2"   -o post-content.bin

export CANDIDATE_HASH="$candidate_hash"
python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
from pathlib import Path
import hashlib,re,json,os
headers=Path("post-headers.txt").read_bytes(); body=Path("post-content.bin").read_bytes()
matches=re.findall(br"(?im)^content-type:\s*([^\r\n]+)",headers)
ctype=matches[-1].decode("latin1").strip() if matches else ""
found=None
if ctype.lower().startswith("multipart/"):
    synthetic=("Content-Type: "+ctype+"\r\nMIME-Version: 1.0\r\n\r\n").encode("latin1")+body
    msg=BytesParser(policy=default).parsebytes(synthetic)
    for p in msg.iter_parts():
        raw=p.get_payload(decode=True) or b""
        if b"wrapper_manifest_refresh_failed" in raw and b"addonCollectionSet" in raw:
            found=raw; break
else:
    found=body
if found is None: raise SystemExit("deployed module missing")
digest=hashlib.sha256(found).hexdigest()
if digest != os.environ["CANDIDATE_HASH"]:
    raise SystemExit(f"post deploy hash mismatch: {digest}")
Path("ops-receipts").mkdir(exist_ok=True)
Path("ops-receipts/wrapper-refresh-failclosed-deployment-20260923.json").write_text(json.dumps({
  "schema":1,
  "result":"deployed",
  "sourceSha256":digest,
  "settingsPreserved":True,
  "policy":"wrapper refresh failures are provider scoped, logged without private path, and do not stop unrelated maintenance"
},indent=2)+"\n")
print("deployment_verified",digest)
PY
