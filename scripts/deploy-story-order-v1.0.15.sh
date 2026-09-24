#!/usr/bin/env bash
set -euo pipefail

test -n "${CLOUDFLARE_API_TOKEN:-}"
test -n "${CLOUDFLARE_ACCOUNT_ID:-}"
test -d story-order/.git
cd story-order
test "$(git rev-parse HEAD)" = "a82f7b054a9bcb2a6543b175f07bbde006d2c21c"
test "$(node -p "require('./package.json').version")" = "1.0.15"

npm ci --ignore-scripts
npm run check
npm test
npm audit --audit-level=high

rm -rf dist
npx wrangler deploy --dry-run --outdir dist --config wrangler.example.toml >/tmp/story-order-dry-run.txt
mapfile -t bundles < <(find dist -maxdepth 1 -type f -name '*.js' -print)
test "${#bundles[@]}" -eq 1
bundle="${bundles[0]}"
node --check "$bundle"
bundle_hash="$(sha256sum "$bundle" | awk '{print $1}')"
test "${#bundle_hash}" -eq 64

auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
base="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/stremio-story-order"

settings_before="$(curl -fsS "${auth[@]}" "$base/settings")"
node - <<'NODE' "$settings_before" > /tmp/story-settings-before.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const r=x.result||{};
const bindings=(r.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name)||a.type.localeCompare(b.type));
process.stdout.write(JSON.stringify({bindings,compatibility_date:String(r.compatibility_date||""),compatibility_flags:[...(r.compatibility_flags||[])].sort()}));
NODE

deployments_before="$(curl -fsS "${auth[@]}" "$base/deployments")"
before_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_before")"
test -n "$before_id"

cp "$bundle" /tmp/story-order-worker.js
printf '%s' '{"main_module":"worker.js"}' >/tmp/story-order-metadata.json
http_code="$(curl -sS -o /tmp/story-order-deploy-response.json -w '%{http_code}' -X PUT   "${auth[@]}"   -F 'metadata=@/tmp/story-order-metadata.json;type=application/json'   -F 'worker.js=@/tmp/story-order-worker.js;filename=worker.js;type=application/javascript+module'   "$base/content")"
export DEPLOY_HTTP_CODE="$http_code"
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("/tmp/story-order-deploy-response.json","utf8"));
if(!x.success||!/^2\d\d$/.test(String(process.env.DEPLOY_HTTP_CODE||""))){
  console.error("deploy_rejected",process.env.DEPLOY_HTTP_CODE,JSON.stringify(x.errors||[]));
  process.exit(1);
}
NODE

settings_after="$(curl -fsS "${auth[@]}" "$base/settings")"
node - <<'NODE' "$settings_after" > /tmp/story-settings-after.json
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const r=x.result||{};
const bindings=(r.bindings||[]).map(v=>({name:String(v.name||""),type:String(v.type||"")})).sort((a,b)=>a.name.localeCompare(b.name)||a.type.localeCompare(b.type));
process.stdout.write(JSON.stringify({bindings,compatibility_date:String(r.compatibility_date||""),compatibility_flags:[...(r.compatibility_flags||[])].sort()}));
NODE
cmp /tmp/story-settings-before.json /tmp/story-settings-after.json

deployments_after="$(curl -fsS "${auth[@]}" "$base/deployments")"
after_id="$(node -e 'const x=JSON.parse(process.argv[1]);const ds=x.result?.deployments||x.result||[];const d=Array.isArray(ds)?ds[0]:null;if(!x.success||!d)process.exit(2);process.stdout.write(String(d.id||""))' "$deployments_after")"
test -n "$after_id"
test "$after_id" != "$before_id"

curl -fsS "${auth[@]}" -D /tmp/story-live-headers.txt "$base/content/v2" -o /tmp/story-live-content.bin
export EXPECTED_BUNDLE_HASH="$bundle_hash"
python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
import hashlib,re,os
headers=open("/tmp/story-live-headers.txt","rb").read()
body=open("/tmp/story-live-content.bin","rb").read()
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
if digest!=os.environ["EXPECTED_BUNDLE_HASH"]:
    raise SystemExit(f"bundle mismatch {digest}")
print("bundle_match",digest)
PY

public="https://stremio-story-order.storyorder.workers.dev/manifest.json"
version=""
for attempt in $(seq 1 12); do
  version="$(curl -fsS -H 'Cache-Control: no-cache' "$public?cb=$(date +%s)-$attempt" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).version||''))")" || true
  if [ "$version" = "1.0.15" ]; then break; fi
  sleep 5
done
test "$version" = "1.0.15"

echo "deployment_verified id_prefix=${after_id:0:12} bundle_hash=$bundle_hash live_version=$version"
