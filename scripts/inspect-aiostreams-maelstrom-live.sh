#!/usr/bin/env bash
set -euo pipefail

curl -fsS \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -D live-headers.txt \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content/v2" \
  -o live-content.bin

python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
from pathlib import Path
import hashlib,re
headers=Path("live-headers.txt").read_bytes()
body=Path("live-content.bin").read_bytes()
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
text=found.decode("utf-8")
digest=hashlib.sha256(found).hexdigest()
checks={
  "generic_name": 'name: "Stream Compatibility"' in text,
  "upstream_name": 'name: String(m.name || "Maelstrom").trim() || "Maelstrom"' in text,
  "adapter_version": '"-adapter.8"' in text,
  "legacy_version": '"-compat.7"' in text,
  "strict_prefix": "function strictBingePrefix" in text,
  "fallback": "function applyBingeGroupFallback" in text,
  "stable_id": 'id: "org.thiajay.stream-compatibility"' in text,
  "adapter_user_agent": "Stremio-AIOStreams-Maelstrom-Adapter/0.2" in text
}
state="new" if checks["upstream_name"] and checks["adapter_version"] and checks["strict_prefix"] and checks["fallback"] and checks["stable_id"] else "old" if checks["generic_name"] and checks["legacy_version"] else "mixed"
parts=[
  "live"+state,
  "g"+str(int(checks["generic_name"])),
  "u"+str(int(checks["upstream_name"])),
  "a"+str(int(checks["adapter_version"])),
  "p"+str(int(checks["strict_prefix"])),
  "f"+str(int(checks["fallback"])),
  "id"+str(int(checks["stable_id"])),
  "ua"+str(int(checks["adapter_user_agent"])),
  "h"+digest[:16]
]
Path("live-adapter-state.txt").write_text("_".join(parts)+"\n",encoding="utf-8")
Path("live-adapter-hash.txt").write_text(digest+"\n",encoding="utf-8")
print("_".join(parts))
PY
