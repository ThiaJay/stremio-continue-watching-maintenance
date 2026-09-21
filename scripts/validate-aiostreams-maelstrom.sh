#!/usr/bin/env bash
set -euo pipefail

printf 'production_contract\n' > validation-stage.txt
settings="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/settings")"
node - <<'NODE' "$settings"
const x=JSON.parse(process.argv[2]);
if(!x.success) process.exit(2);
const actual=(x.result?.bindings||[])
  .map(v=>({name:String(v.name||""),type:String(v.type||"")}))
  .sort((a,b)=>a.name.localeCompare(b.name));
const expected=[
  {name:"ACCESS_PATH_TOKEN",type:"secret_text"},
  {name:"BINDINGS_DB",type:"d1"},
  {name:"MAELSTROM_ROOT",type:"secret_text"},
  {name:"METADATA",type:"service"}
];
if(JSON.stringify(actual)!==JSON.stringify(expected)) {
  console.error("binding contract changed");
  console.error(JSON.stringify(actual));
  process.exit(3);
}
if(String(x.result?.compatibility_date||"")!=="2026-09-18") {
  console.error("compatibility date changed");
  process.exit(4);
}
console.log("production_contract_ok");
NODE

curl -fsS   -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"   -D response-headers.txt   "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/content/v2"   -o worker-content.bin

python3 - <<'PY'
from email.parser import BytesParser
from email.policy import default
import hashlib, os
headers=open("response-headers.txt","rb").read()
body=open("worker-content.bin","rb").read()
msg=BytesParser(policy=default).parsebytes(headers+b"\r\n"+body)
found=None
if msg.is_multipart():
    for p in msg.iter_parts():
        name=p.get_param("name", header="content-disposition") or p.get_filename() or ""
        if name=="worker.js":
            found=p.get_payload(decode=True) or b""
            break
else:
    found=body
if found is None:
    raise SystemExit("worker.js not found")
digest=hashlib.sha256(found).hexdigest()
expected=os.environ["EXPECTED_SOURCE_SHA256"]
if digest != expected:
    raise SystemExit(f"source hash changed: {digest}")
open("live-worker.mjs","wb").write(found)
print("source_hash_ok",digest)
PY

printf 'source_patch\n' > validation-stage.txt
python3 - <<'PY'
from pathlib import Path

path=Path("live-worker.mjs")
text=path.read_text(encoding="utf-8")

replacements=[
  (
    'headers.set("user-agent", "Stremio-Stream-Compatibility/0.1");',
    'headers.set("user-agent", "Stremio-AIOStreams-Maelstrom-Adapter/0.2");'
  ),
  (
    '    name: "Stream Compatibility",\n    version: String(m.version || "0.0.0") + "-compat.7",\n    description: "Private stream-only compatibility gateway. The current Maelstrom/AIOStreams adapter provides fail-safe episode mapping and debrid stream-readiness protection.",',
    '    name: String(m.name || "Maelstrom").trim() || "Maelstrom",\n    version: String(m.version || "0.0.0") + "-adapter.8",\n    description: "Private Maelstrom/AIOStreams adapter providing fail-safe episode mapping, debrid stream-readiness protection and conservative binge continuity.",'
  ),
  (
    '        const readiness = await rewriteReadinessUrls(result.payload, env, request.url);',
    '        const bingeHardened = result.translated || result.recoveryPreviousId ? result.payload : await hardenBingeGroups(result.payload, env, sm[1], decodeURIComponent(sm[2]), upstreamRequest);\n        const readiness = await rewriteReadinessUrls(bingeHardened, env, request.url);'
  ),
  (
    'export {\n  currentRoot,',
    'export {\n  applyBingeGroupFallback,\n  currentRoot,'
  ),
  (
    '  streamPayload,\n  titleMatches,',
    '  streamPayload,\n  strictBingePrefix,\n  titleMatches,'
  )
]
for old,new in replacements:
    count=text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one patch target, found {count}: {old[:80]}")
    text=text.replace(old,new,1)

marker='async function manifest(env, request) {'
if text.count(marker) != 1:
    raise SystemExit("manifest marker mismatch")

helper=r'''
function bingeGroupOf(stream) {
  const group = stream?.behaviorHints?.bingeGroup;
  return typeof group === "string" && group.length ? group : null;
}
function strictBingePrefix(current, nextGroups) {
  if (typeof current !== "string" || !current) return null;
  if (nextGroups.has(current)) return current;
  const parts = current.split("|");
  if (parts.length < 3 || !String(parts[0] || "").trim() || !String(parts[1] || "").trim()) return null;
  for (let length = parts.length - 1; length >= 2; length--) {
    const candidate = parts.slice(0, length).join("|");
    if (nextGroups.has(candidate)) return candidate;
  }
  return null;
}
function applyBingeGroupFallback(payload, nextPayload) {
  if (!Array.isArray(payload?.streams) || !Array.isArray(nextPayload?.streams)) return payload;
  const nextGroups = new Set(nextPayload.streams.map(bingeGroupOf).filter(Boolean));
  if (!nextGroups.size) return payload;
  let changed = false;
  const streams = payload.streams.map((stream) => {
    const current = bingeGroupOf(stream);
    if (!current || nextGroups.has(current)) return stream;
    const fallback = strictBingePrefix(current, nextGroups);
    if (!fallback || fallback === current) return stream;
    changed = true;
    return { ...stream, behaviorHints: { ...stream.behaviorHints || {}, bingeGroup: fallback } };
  });
  return changed ? { ...payload, streams } : payload;
}
function nextCanonicalId(meta, seriesId, season, episode) {
  const normal = (meta?.videos || []).map((v) => ({
    id: String(v.id || ""),
    season: Number(v.season ?? v.seriesInfo?.season),
    episode: Number(v.episode ?? v.seriesInfo?.episode)
  })).filter((v) => v.season > 0 && v.episode > 0).sort((a, b) => a.season - b.season || a.episode - b.episode);
  const i = normal.findIndex((v) => v.season === season && v.episode === episode);
  if (i < 0 || i + 1 >= normal.length) return null;
  const next = normal[i + 1];
  return next.id || seriesId + ":" + next.season + ":" + next.episode;
}
async function hardenBingeGroups(payload, env, type, id, request, fetchImpl = fetch) {
  try {
    if (type !== "series" || !Array.isArray(payload?.streams)) return payload;
    const currentGroups = payload.streams.map(bingeGroupOf).filter(Boolean);
    if (!currentGroups.length) return payload;
    const m = String(id).match(/^(tt\d{5,12}):(\d+):(\d+)$/);
    if (!m) return payload;
    const seriesId = m[1], season = Number(m[2]), episode = Number(m[3]);
    const meta = await metadata(env, seriesId);
    const nextId = nextCanonicalId(meta, seriesId, season, episode);
    if (!nextId) return payload;
    const r = await upstream(env, "/stream/series/" + encodeURIComponent(nextId) + ".json", request, fetchImpl);
    if (!r.ok) return payload;
    const nextPayload = await boundedJson(r);
    return applyBingeGroupFallback(payload, nextPayload);
  } catch {
    return payload;
  }
}
'''
text=text.replace(marker,helper+"\n"+marker,1)

if 'name: "Stream Compatibility"' in text:
    raise SystemExit("generic visible manifest name remains")
if "Stremio-Stream-Compatibility/0.1" in text:
    raise SystemExit("obsolete user agent remains")
if 'id: "org.thiajay.stream-compatibility"' not in text:
    raise SystemExit("stable addon id was lost")

Path("patched-worker.mjs").write_text(text,encoding="utf-8")
print("patch_applied")
PY

printf 'syntax_check\n' > validation-stage.txt
node --check patched-worker.mjs

printf 'regression_tests\n' > validation-stage.txt
cat > validate.mjs <<'NODE'
import assert from "node:assert/strict";
import crypto from "node:crypto";
globalThis.crypto=globalThis.crypto||crypto.webcrypto;

const mod=await import("./patched-worker.mjs");

const current={
  streams:[{
    name:"AIOStreams",
    url:"https://media.invalid/current",
    behaviorHints:{
      bingeGroup:"addon|1080p|MeGusta",
      filename:"episode.mkv"
    }
  }]
};
const next={streams:[{behaviorHints:{bingeGroup:"addon|1080p"}}]};
const hardened=mod.applyBingeGroupFallback(current,next);
assert.equal(hardened.streams[0].behaviorHints.bingeGroup,"addon|1080p");
assert.equal(hardened.streams[0].name,"AIOStreams");
assert.equal(hardened.streams[0].behaviorHints.filename,"episode.mkv");
assert.equal(hardened.streams[0].url,"https://media.invalid/current");

const exactPayload={streams:[{name:"Maelstrom",behaviorHints:{bingeGroup:"addon|720p|HEVC"}}]};
const exactNext={streams:[{behaviorHints:{bingeGroup:"addon|720p|HEVC"}}]};
assert.equal(mod.applyBingeGroupFallback(exactPayload,exactNext),exactPayload);

const missing={streams:[{name:"AIOStreams",behaviorHints:{filename:"x.mkv"}}]};
assert.equal(mod.applyBingeGroupFallback(missing,next),missing);

const noSafePrefix={streams:[{name:"AIOStreams",behaviorHints:{bingeGroup:"addon|AFG"}}]};
const bareOnly={streams:[{behaviorHints:{bingeGroup:"addon"}}]};
assert.equal(mod.applyBingeGroupFallback(noSafePrefix,bareOnly),noSafePrefix);

const emptyComponent={streams:[{name:"AIOStreams",behaviorHints:{bingeGroup:"addon|"}}]};
assert.equal(mod.applyBingeGroupFallback(emptyComponent,bareOnly),emptyComponent);

const longest={streams:[{behaviorHints:{bingeGroup:"addon|2160p|WEB|Group"}}]};
const prefixes={streams:[
  {behaviorHints:{bingeGroup:"addon|2160p"}},
  {behaviorHints:{bingeGroup:"addon|2160p|WEB"}}
]};
assert.equal(mod.applyBingeGroupFallback(longest,prefixes).streams[0].behaviorHints.bingeGroup,"addon|2160p|WEB");

const unrelated={streams:[{name:"Maelstrom",behaviorHints:{bingeGroup:"addon|1080p|MeGusta"}}]};
const unrelatedNext={streams:[{behaviorHints:{bingeGroup:"addon|720p"}}]};
assert.equal(mod.applyBingeGroupFallback(unrelated,unrelatedNext),unrelated);

assert.equal(mod.strictBingePrefix("addon|1080p|MeGusta",new Set(["addon|1080p"])),"addon|1080p");
assert.equal(mod.strictBingePrefix("addon|",new Set(["addon"])),null);

let upstreamName="AIOStreams";
globalThis.fetch=async (url) => {
  const u=String(url);
  if(!u.endsWith("/manifest.json")) throw new Error("unexpected fetch "+u);
  return new Response(JSON.stringify({
    id:"upstream.id",
    name:upstreamName,
    version:"9.1.0",
    resources:["stream"],
    types:["movie","series"],
    catalogs:[]
  }),{status:200,headers:{"content-type":"application/json"}});
};
const token="A".repeat(40);
const env={ACCESS_PATH_TOKEN:token,MAELSTROM_ROOT:"https://provider.invalid/stremio/private"};
const response=await mod.default.fetch(new Request("https://gateway.invalid/"+token+"/manifest.json"),env,{});
assert.equal(response.status,200);
const manifest=await response.json();
assert.equal(manifest.name,"AIOStreams");
assert.equal(manifest.id,"org.thiajay.stream-compatibility");
assert.equal(manifest.version,"9.1.0-adapter.8");
assert.notEqual(manifest.name,"Stream Compatibility");

upstreamName="Maelstrom";
const response2=await mod.default.fetch(new Request("https://gateway.invalid/"+token+"/manifest.json"),env,{});
const manifest2=await response2.json();
assert.equal(manifest2.name,"Maelstrom");

console.log("deterministic_regressions_ok");
NODE

node validate.mjs
printf 'passed\n' > validation-stage.txt
