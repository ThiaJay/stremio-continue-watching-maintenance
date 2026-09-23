import assert from "node:assert/strict";
const mod = await import("../patched-controller.mjs");

const descriptor = {
  transportUrl: "https://stremio-stream-compatibility.storyorder.workers.dev/private-token/manifest.json",
  manifest: {
    id: "org.thiajay.stream-compatibility",
    name: "Stream Compatability",
    version: "2.34.1-compat.7",
    resources: ["stream"],
    types: ["movie", "series"],
    catalogs: []
  }
};

const goodFetch = async () => new Response(JSON.stringify({
  id: "org.thiajay.stream-compatibility",
  name: "AIOStreams",
  version: "2.34.1-adapter.8",
  resources: ["stream"],
  types: ["movie", "series"],
  catalogs: []
}), { status: 200, headers: { "content-type": "application/json" } });

const refreshed = await mod.refreshWrapperDescriptor("maelstrom", descriptor, goodFetch);
assert.equal(refreshed.transportUrl, descriptor.transportUrl);
assert.equal(refreshed.manifest.name, "AIOStreams");
assert.equal(refreshed.manifest.version, "2.34.1-adapter.8");
assert.deepEqual(Object.keys(refreshed).sort(), Object.keys(descriptor).sort());

const badName = async () => new Response(JSON.stringify({
  id: "org.thiajay.stream-compatibility",
  name: "Stream Compatibility",
  version: "x",
  resources: ["stream"]
}), { status: 200, headers: { "content-type": "application/json" } });

await assert.rejects(
  () => mod.refreshWrapperDescriptor("maelstrom", descriptor, badName),
  (e) => e?.code === "WRAPPER_VISIBLE_NAME_INVALID"
);

const badHost = { ...descriptor, transportUrl: "https://example.invalid/private-token/manifest.json" };
await assert.rejects(
  () => mod.refreshWrapperDescriptor("maelstrom", badHost, goodFetch),
  (e) => e?.code === "WRAPPER_HOST_MISMATCH"
);

console.log("wrapper_refresh_regressions_ok");
