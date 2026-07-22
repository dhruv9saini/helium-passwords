# Independent Tab Snapshots

`helium-tabs` is the implemented recovery-store portion of HS-004. It does not
read Chromium session files or accept a profile path. The native Chromium
bridge exports the bounded JSON model through session/tab APIs to a dedicated
file outside the profile and refreshes it every five minutes. The source exists
but has not passed a Chromium compile or disposable-profile run, so use only
synthetic exports until that validation is complete.

The store must live outside both the browser profile and `helium-syncd` data
directory. One store belongs to one logical device/profile namespace.

```sh
helium-tabs capture \
  --store "$HOME/.local/share/helium-sync/tab-snapshots/d-default" \
  --input /path/to/browser-api-session.json \
  --device d \
  --profile default \
  --browser-version 0.14.7 \
  --chromium-version 150.0.7871.128 \
  --reason scheduled

helium-tabs list \
  --store "$HOME/.local/share/helium-sync/tab-snapshots/d-default"

helium-tabs validate \
  --store "$HOME/.local/share/helium-sync/tab-snapshots/d-default" \
  --generation GENERATION
```

Capture validates window/tab/navigation bounds and rejects unsafe URL schemes.
It writes `session.json` and its hash/size manifest into a temporary directory,
syncs both files and the directory, atomically renames the generation, syncs
the parent directory, and validates the committed result. Each manifest links
to the latest valid parent generation.

Retention is a two-step fail-closed operation:

```sh
helium-tabs retention-plan \
  --store "$HOME/.local/share/helium-sync/tab-snapshots/d-default"

helium-tabs retention-apply \
  --store "$HOME/.local/share/helium-sync/tab-snapshots/d-default"
```

The implementation selects the newest valid generation, 24 hourly buckets, 14
daily buckets, 12 ISO-week buckets, every protected generation, and every
invalid generation. It refuses all retention if the newest generation fails
validation, re-plans immediately before deletion, never selects a protected or
invalid generation, and never removes the last valid generation. Pass
`--protected` to `capture` only for a known-good restore-drill generation.

After inspecting a suspect generation, preserve and remove it from active
retention consideration with an explicit quarantine. This is an atomic rename
inside the store; it never deletes or repairs the suspect bytes:

```sh
helium-tabs quarantine \
  --store "$HOME/.local/share/helium-sync/tab-snapshots/d-default" \
  --generation GENERATION --reason checksum-mismatch
```

Quarantine is not an automatic response to corruption. An invalid newest
generation keeps retention blocked until this explicit preservation step or a
storage repair.

Restore cannot target an existing directory:

```sh
helium-tabs restore \
  --store "$HOME/.local/share/helium-sync/tab-snapshots/d-default" \
  --generation GENERATION \
  --destination /path/to/new-disposable-state

helium-tabs validate-restore \
  --destination /path/to/new-disposable-state
```

It validates hashes and schema again, creates and syncs a temporary restore,
then atomically renames it to the requested new disposable-state directory.
The restore receipt binds the source generation, device/profile namespace,
session hash and size, validation marker, and restore time. The standalone
validator rejects symlinks, nonprivate files, extra inventory, schema drift,
and any receipt/content mismatch without consulting the source store. The
output is still the neutral JSON model; browser loading, second-restart
verification, drill recording, and promotion to a real stopped profile remain
unimplemented integration work. No automatic promotion path exists.
