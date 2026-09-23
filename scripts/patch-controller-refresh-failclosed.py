from pathlib import Path

p=Path("live-controller.mjs")
text=p.read_text(encoding="utf-8")

old='''  const before = await getCollection(env, true, deps.fetchImpl || fetch), beforeHash = await sha(before), b = await bindings(env);
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

new='''  const before = await getCollection(env, true, deps.fetchImpl || fetch), beforeHash = await sha(before), b = await bindings(env);
  const decisions = [], removeIndexes = /* @__PURE__ */ new Set(), errors = [];
  const wrapperUpdates = /* @__PURE__ */ new Map(), wrapperRefreshDetails = [];
  for (const [provider, def] of Object.entries(PROVIDERS)) {
    const matches = before.map((descriptor, index) => ({ descriptor, index })).filter((x) => x.descriptor?.manifest?.id === def.wrapperId);
    assert(matches.length === 1, matches.length ? "WRAPPER_DUPLICATE_" + def.wrapperId : "WRAPPER_MISSING_" + def.wrapperId);
    const current = matches[0];
    try {
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
    } catch (e) {
      let host = null;
      try { host = new URL(String(current.descriptor.transportUrl || "")).hostname || null; } catch {}
      const code = e?.code || "WRAPPER_REFRESH_FAILED";
      errors.push(provider + ":" + code);
      await event(env, provider, "wrapper_manifest_refresh_failed", null, null, {
        code,
        name: current.descriptor.manifest?.name || null,
        version: current.descriptor.manifest?.version || null,
        host
      }, when);
    }
  }
  let candidatesSeen = 0, ambiguous = 0, rebinds = 0;'''

if text.count(old)!=1:
    raise SystemExit("fail closed prelude target mismatch")
text=text.replace(old,new,1)
Path("patched-controller.mjs").write_text(text,encoding="utf-8")
print("fail_closed_patch_applied")
