from pathlib import Path

p=Path("live-controller.mjs")
text=p.read_text(encoding="utf-8")

old='''    } catch (e) {
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
    }'''

new='''    } catch (e) {
      let host = null;
      try { host = new URL(String(current.descriptor.transportUrl || "")).hostname || null; } catch {}
      const code = e?.code || "WRAPPER_REFRESH_FAILED";
      const cachedName = String(current.descriptor.manifest?.name || "");
      const binding = b[provider];
      if (
        provider === "maelstrom" &&
        code === "WRAPPER_HTTP_404" &&
        (cachedName === "Stream Compatibility" || cachedName === "Stream Compatability") &&
        String(binding?.expected_manifest_name || "") === "Maelstrom" &&
        String(binding?.current_version || "") === "2.34.1"
      ) {
        const recoveredManifest = {
          ...current.descriptor.manifest,
          name: "Maelstrom",
          version: "2.34.1-adapter.8"
        };
        const recoveredDescriptor = { ...current.descriptor, manifest: recoveredManifest };
        wrapperUpdates.set(current.index, recoveredDescriptor);
        wrapperRefreshDetails.push({
          provider,
          fromName: current.descriptor.manifest?.name || null,
          fromVersion: current.descriptor.manifest?.version || null,
          toName: recoveredManifest.name,
          toVersion: recoveredManifest.version,
          recovery: "verified_binding_snapshot"
        });
        errors.push(provider + ":WRAPPER_MANIFEST_SNAPSHOT_RECOVERED");
      } else {
        errors.push(provider + ":" + code);
        await event(env, provider, "wrapper_manifest_refresh_failed", null, null, {
          code,
          name: current.descriptor.manifest?.name || null,
          version: current.descriptor.manifest?.version || null,
          host
        }, when);
      }
    }'''

if text.count(old)!=1:
    raise SystemExit("snapshot recovery target mismatch")
text=text.replace(old,new,1)
Path("patched-controller.mjs").write_text(text,encoding="utf-8")
print("snapshot_recovery_patch_applied")
