#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="stremio-addon-binding-controller"
EXPECTED_SOURCE_SHA256="729ff9a59f1833a2ea8491f83b4795102607894d362bd48dfc0f5eb70015b5bc"

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
        if b"wrapper_manifest_refresh_failed" in raw and b"refreshWrapperDescriptor" in raw:
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

python3 scripts/patch-controller-wrapper-snapshot-recovery.py
node --check patched-controller.mjs

grep -q 'WRAPPER_MANIFEST_SNAPSHOT_RECOVERED' patched-controller.mjs
grep -q 'verified_binding_snapshot' patched-controller.mjs
grep -q 'name: "Maelstrom"' patched-controller.mjs
grep -q 'version: "2.34.1-adapter.8"' patched-controller.mjs

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
        if b"WRAPPER_MANIFEST_SNAPSHOT_RECOVERED" in raw and b"addonCollectionSet" in raw:
            found=raw; break
else:
    found=body
if found is None: raise SystemExit("deployed module missing")
digest=hashlib.sha256(found).hexdigest()
if digest != os.environ["CANDIDATE_HASH"]:
    raise SystemExit(f"post deploy hash mismatch: {digest}")
Path("ops-receipts").mkdir(exist_ok=True)
Path("ops-receipts/wrapper-snapshot-recovery-deployment-20260923.json").write_text(json.dumps({
  "schema":1,
  "result":"deployed",
  "sourceSha256":digest,
  "settingsPreserved":True,
  "recovery":"stale generic stream wrapper snapshot only, verified Maelstrom binding 2.34.1 to adapter.8, transport URL unchanged"
},indent=2)+"\n")
print("deployment_verified",digest)
PY
