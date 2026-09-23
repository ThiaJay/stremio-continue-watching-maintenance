from pathlib import Path

SOURCE = Path("live-controller.mjs")
TARGET = Path("patched-controller.mjs")

text = SOURCE.read_text(encoding="utf-8")

marker = '__name(validateRoot, "validateRoot");\n'
helper = r'''async function refreshWrapperDescriptor(provider, descriptor, fetchImpl = fetch) {
  const def = PROVIDERS[provider];
  assert(def && descriptor?.manifest?.id === def.wrapperId, "WRAPPER_DESCRIPTOR_INVALID");
  let u;
  try {
    u = new URL(String(descriptor.transportUrl || ""));
  } catch {
    throw new BindError("WRAPPER_TRANSPORT_INVALID");
  }
  assert(u.protocol === "https:" && !u.username && !u.password && !u.search && !u.hash, "WRAPPER_TRANSPORT_INVALID");
  const allowedHost = provider === "maelstrom"
    ? "stremio-stream-compatibility.storyorder.workers.dev"
    : "aiometadata-smart-specials.storyorder.workers.dev";
  assert(u.hostname.toLowerCase() === allowedHost, "WRAPPER_HOST_MISMATCH");
  assert(u.pathname.endsWith("/manifest.json"), "WRAPPER_MANIFEST_PATH_INVALID");
  const r = await fetchImpl(descriptor.transportUrl, {
    redirect: "manual",
    signal: AbortSignal.timeout(8000),
    headers: { "user-agent": "Stremio-Binding-Controller/1.1" }
  });
  if (r.status >= 300 && r.status < 400) throw new BindError("WRAPPER_REDIRECT");
  if (!r.ok) throw new BindError("WRAPPER_HTTP_" + r.status);
  const m = await boundedJson(r), rs = resources(m);
  assert(m.id === def.wrapperId, "WRAPPER_ID_MISMATCH");
  assert(def.requiredResources.every((x) => rs.includes(x)), "WRAPPER_RESOURCE_MISMATCH");
  const name = String(m.name || "").trim();
  assert(name && name !== "Stream Compatibility" && name !== "Stream Compatability", "WRAPPER_VISIBLE_NAME_INVALID");
  return { ...descriptor, manifest: m };
}
__name(refreshWrapperDescriptor, "refreshWrapperDescriptor");
'''
if text.count(marker) != 1:
    raise SystemExit("validateRoot marker mismatch")
text = text.replace(marker, marker + helper, 1)

old = '''  const before = await getCollection(env, true, deps.fetchImpl || fetch), beforeHash = await sha(before), b = await bindings(env);
  for (const def of Object.values(PROVIDERS)) assert(before.some((x) => x?.manifest?.id === def.wrapperId), "WRAPPER_MISSING_" + def.wrapperId);
  const decisions = [], removeIndexes = /* @__PURE__ */ new Set(), errors = [];
  let candidatesSeen = 0, ambiguous = 0, rebinds = 0;'''
new = '''  const before = await getCollection(env, true, deps.fetchImpl || fetch), beforeHash = await sha(before), b = await bindings(env);
  const wrapperUpdates = /* @__PURE__ */ new Map(), wrapperRefreshDetails = [];
  for (const [provider, def] of Object.entries(PROVIDERS)) {
    const matches = before.map((descriptor, index) => ({ descriptor, index })).filter((x) => x.descriptor?.manifest?.id === def.wrapperId);
    assert(matches.length === 1, matches.length ? "WRAPPER_DUPLICATE_" + def.wrapperId : "WRAPPER_MISSING_" + def.wrapperId);
    const current = matches[0];
    const freshDescriptor = await refreshWrapperDescriptor(provider, current.descriptor, deps.fetchImpl || fetch);
    if (await sha(freshDescriptor.manifest) !== await sha(current.descriptor.manifest || {})) {
      wrapperUpdates.set(current.index, freshDescriptor);
      wrapperRefreshDetails.push({
        provider,
        fromName: current.descriptor.manifest?.name || null,
        fromVersion: current.descriptor.manifest?.version || null,
        toName: freshDescriptor.manifest?.name || null,
        toVersion: freshDescriptor.manifest?.version || null
      });
    }
  }
  const decisions = [], removeIndexes = /* @__PURE__ */ new Set(), errors = [];
  let candidatesSeen = 0, ambiguous = 0, rebinds = 0;'''
if text.count(old) != 1:
    raise SystemExit("run prelude target mismatch")
text = text.replace(old, new, 1)

old = '''  let duplicatesRemoved = 0;
  if (removeIndexes.size) {
    const next = before.filter((_, i) => !removeIndexes.has(i));
    const expectedRemoved = before.length - next.length;'''
new = '''  let duplicatesRemoved = 0;
  if (removeIndexes.size || wrapperUpdates.size) {
    const next = before.map((x, i) => wrapperUpdates.get(i) || x).filter((_, i) => !removeIndexes.has(i));
    const expectedRemoved = before.length - next.length;'''
if text.count(old) != 1:
    raise SystemExit("collection write target mismatch")
text = text.replace(old, new, 1)

old = '''    if (afterHash === nextHash) {
      duplicatesRemoved = expectedRemoved;
      for (const def of Object.values(PROVIDERS)) assert(after.some((x) => x?.manifest?.id === def.wrapperId), "WRAPPER_REMOVED");'''
new = '''    if (afterHash === nextHash) {
      duplicatesRemoved = expectedRemoved;
      for (const def of Object.values(PROVIDERS)) assert(after.some((x) => x?.manifest?.id === def.wrapperId), "WRAPPER_REMOVED");
      for (const detail of wrapperRefreshDetails) {
        await event(env, detail.provider, "wrapper_manifest_refresh", null, null, detail, when);
      }'''
if text.count(old) != 1:
    raise SystemExit("readback target mismatch")
text = text.replace(old, new, 1)

old = '''  return { candidatesSeen, rebinds, duplicatesRemoved, ambiguous, errorCodes: [...new Set(errors)].slice(0, 20) };'''
new = '''  return { candidatesSeen, rebinds, duplicatesRemoved, wrapperRefreshes: wrapperRefreshDetails.length, ambiguous, errorCodes: [...new Set(errors)].slice(0, 20) };'''
if text.count(old) != 1:
    raise SystemExit("return target mismatch")
text = text.replace(old, new, 1)

old = '''  rollbackBinding,
  run,
  safeTransportRoot,'''
new = '''  rollbackBinding,
  run,
  refreshWrapperDescriptor,
  safeTransportRoot,'''
if text.count(old) != 1:
    raise SystemExit("export target mismatch")
text = text.replace(old, new, 1)

TARGET.write_text(text, encoding="utf-8")
print("patch_applied")
