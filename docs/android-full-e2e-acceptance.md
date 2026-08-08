# Fleet full end-to-end acceptance

This is the sole complete Helium Sync fleet test. A partial probe or a device
tested alone is not a pass. One invocation of
`scripts/android-acceptance/full-e2e.mjs` re-audits the returned Linux runtime,
both returned Android archives, d, da, and OnePlus evidence, then publishes one
create-new mode-0600 receipt.

The product remains the frozen commit passed as `--expected-source-commit`.
Newer build and runtime tooling is admitted separately and never changes that
product identity. No phase may read, clear, install into, or launch a personal
profile or the production Android package.

## Immutable artifacts

The fleet finalizer requires these exact build outputs:

- one `helium-sync-linux-x86_64.tar.xz`, its schema-2 build-produced deployment
  receipt, and the sibling private `helium-sync-linux-x86_64.full-graph/`
  evidence directory;
- the separately returned Sync and no-patch control Android archives; and
- both prepared Android acceptance directories.

The Linux archive is used by both d and da. Each machine still runs its own
verification, native-password, and local-tab drills. The finalizer rehashes
the archive, deployment receipt, both locally generated runtime receipts,
extracted schema-4 `provenance/manifest.env`, and every full-graph evidence
file. The
deployment, manifest, and graph job IDs must agree; the manifest must include the pinned depot_tools
commit. The full-graph inventory rehashes `build.ninja`, `toolchain.ninja`,
the rerun target query, DevTools CSS and AI source, platform bootstrap,
immutable build operator, Ninja shim, fresh or authenticated retained-repair
boundary, and every external capture/finalization/packaging/recovery tool. Its
schema-3 receipt must prove the `chrome,chromedriver` graph, every scoped
DevTools CSS action's tsconfig output, both Node-22 entrypoints, and the
complete one-job Ninja boundary. The deployment
receipt and internal manifest repeat the graph receipt and inventory hashes.

The Sync and control prepared directories must rehash completely and bind the
two supplied raw archives. They must agree on source/core/Chromium/version,
runtime kit, build tooling, `flags.gn`, and locked GN args.

## Ordered fleet run

1. Begin the unchanged-Serve guard with
   `scripts/tailnet-serve-acceptance.sh begin NEW_STATE_DIR`.
2. Run Sync and control through their artifact-carried disposable browser and
   device probe. The pair must cover the native CookieManager transaction,
   H2/H3, codecs and streaming, Service Worker, background/foreground, and
   Wi-Fi-to-cellular handoff, then produce one matched A/B receipt. The shared
   offline auditor imports and reruns the artifact-carried complete probe
   validator, rehashes both full acceptance/evidence inventories, and binds
   both runs to one physical OnePlus identity.
3. Use `reset-disposable-package.sh` to clear only
   `computer.helium.sync.test` from `media-cookie` to `password-sync`. The
   physical-USB receipt must prove the production package and Android global
   browser state did not change.
4. Run the three-client gate with the same admitted x86_64 runtime for d and
   da and the prepared Sync APK for OnePlus. Enroll d, da, then OnePlus and
   complete native password lifecycle, cookie convergence, pull-only joins,
   stale-write rejection, tombstones, no-op restarts, and private-Tailnet HTTP
   server evidence.
5. On d and da independently, run one headed native clean/crash/second-restart
   tab proof, two neutral proofs, and two full-profile proofs. The replica
   destinations are `nas-on-lm` plus `da-copy` for d and `nas-on-lm` plus
   `d-copy` for da. Emit all three status receipts from those authenticated
   evidence sets and retain each schema-3 full-profile backup receipt.
6. On each desktop, corrupt the newest neutral generation and recover a
   distinct previous generation, then corrupt one full-profile destination
   and recover the same generation from the other destination. Retain both
   authenticated fallback proofs and all four private HMAC-authenticated
   rejection/quarantine receipt directories.
   Each content-free `helium-desktop-tab-fault-matrix-v1` records the device,
   artifact hash, two cases, unchanged sibling mechanisms, and false for live
   or personal-profile access.
7. For d, da, and OnePlus, back up the browser-native neutral password and
   cookie snapshots as one stopped-profile generation to NAS and the fixed
   peer. Restore each kind from each destination into a fresh marked disposable
   profile and retain each device's final native-recovery receipt. These are
   four recovery drills per device and twelve fleet-wide; both desktop receipts
   must bind the admitted Linux browser executable and OnePlus must bind the
   prepared Sync APK. The finalizer also requires password and normalized
   cookie state to converge across all three devices.
8. Clear only the Sync `.test` package from `password-sync` to `tab-recovery`.
9. On OnePlus, run one native, two neutral, and two full-profile proofs against
   the exact Sync APK and one physical USB serial. Back up only the stopped
   synthetic `app_chrome` tree to NAS plus da, emit all three status receipts,
   and retain its schema-3 receipt.
10. Corrupt and recover the OnePlus neutral and full-profile inputs as described
   in the two-case `helium-android-tab-fault-matrix-v2`. Retain both fallback
   proofs and all four operation receipts. Production and personal data remain
   untouched.
11. Run `scripts/tailnet-serve-acceptance.sh verify STATE_DIR`; its before and
    after configuration hashes must be identical.

The desktop and Android fault matrices use the same two case names:
`neutral-corrupt-newest-generation` and
`full-profile-corrupt-destination`. The neutral case binds distinct damaged
and recovery generations. The full-profile case binds one generation and two
distinct admitted destinations. Each case hashes its rejection receipt,
quarantine receipt, and HMAC-authenticated fallback proof.

Create each operation receipt with
`scripts/tabs/tab-fault-operation.mjs record`. Its private input JSON contains
only the operation identity, exact negative/quarantine/recovery results,
generation/destination fields, and monotonic timestamps. The recorder itself
rehashes the pre-fault archive, damaged input, quarantined archive, fallback
`evidence.json`, and sibling-state snapshots supplied through
`--pre-fault-archive`, `--damaged-input`, `--quarantine-archive`,
`--fallback-evidence`, `--sibling-before`, and `--sibling-after`; those hashes
must prove damage, byte-identical quarantine, recovery, and unchanged sibling
state before the HMAC receipt directory is published. Do not put caller-made
hashes in the input JSON.

## One terminal receipt

Repeated options must be supplied the stated number of times. `--tab-*`
without a device prefix is the OnePlus evidence set.

```sh
node scripts/android-acceptance/full-e2e.mjs verify \
  --expected-source-commit "$frozen_sync_commit" \
  --expected-runtime-kit-commit "$runtime_kit_commit" \
  --linux-artifact "$linux_archive" \
  --linux-deployment-receipt "$linux_deployment_receipt" \
  --linux-full-graph-receipt "$linux_full_graph_receipt" \
  --d-tab-signing-key "$d_tab_key" \
  --d-tab-evidence "$d_native" \
  --d-tab-evidence "$d_neutral_nas" \
  --d-tab-evidence "$d_neutral_peer" \
  --d-tab-evidence "$d_full_nas" \
  --d-tab-evidence "$d_full_peer" \
  --d-tab-status "$d_native_status" \
  --d-tab-status "$d_neutral_status" \
  --d-tab-status "$d_full_status" \
  --d-tab-fault-evidence "$d_fault_matrix" \
  --d-fault-tab-evidence "$d_neutral_fallback" \
  --d-fault-tab-evidence "$d_full_fallback" \
  --d-fault-operation-receipt "$d_neutral_rejection" \
  --d-fault-operation-receipt "$d_neutral_quarantine" \
  --d-fault-operation-receipt "$d_full_rejection" \
  --d-fault-operation-receipt "$d_full_quarantine" \
  --d-profile-backup-receipt "$d_profile_backup" \
  --da-tab-signing-key "$da_tab_key" \
  --da-tab-evidence "$da_native" \
  --da-tab-evidence "$da_neutral_nas" \
  --da-tab-evidence "$da_neutral_peer" \
  --da-tab-evidence "$da_full_nas" \
  --da-tab-evidence "$da_full_peer" \
  --da-tab-status "$da_native_status" \
  --da-tab-status "$da_neutral_status" \
  --da-tab-status "$da_full_status" \
  --da-tab-fault-evidence "$da_fault_matrix" \
  --da-fault-tab-evidence "$da_neutral_fallback" \
  --da-fault-tab-evidence "$da_full_fallback" \
  --da-fault-operation-receipt "$da_neutral_rejection" \
  --da-fault-operation-receipt "$da_neutral_quarantine" \
  --da-fault-operation-receipt "$da_full_rejection" \
  --da-fault-operation-receipt "$da_full_quarantine" \
  --da-profile-backup-receipt "$da_profile_backup" \
  --d-native-recovery-receipt "$d_native_recovery_receipt" \
  --da-native-recovery-receipt "$da_native_recovery_receipt" \
  --oneplus-native-recovery-receipt "$oneplus_native_recovery_receipt" \
  --sync-archive "$sync_archive" \
  --sync-acceptance "$sync_acceptance" \
  --sync-evidence "$sync_evidence" \
  --control-archive "$control_archive" \
  --control-acceptance "$control_acceptance" \
  --control-evidence "$control_evidence" \
  --media-pair-receipt "$media_pair_receipt" \
  --three-client-run "$three_client_run" \
  --phase-reset-receipt "$reset_media_sync" \
  --phase-reset-receipt "$reset_sync_tabs" \
  --tab-signing-key "$oneplus_tab_key" \
  --tab-evidence "$oneplus_native" \
  --tab-evidence "$oneplus_neutral_nas" \
  --tab-evidence "$oneplus_neutral_da" \
  --tab-evidence "$oneplus_full_nas" \
  --tab-evidence "$oneplus_full_da" \
  --tab-status "$oneplus_native_status" \
  --tab-status "$oneplus_neutral_status" \
  --tab-status "$oneplus_full_status" \
  --tab-fault-evidence "$oneplus_fault_matrix" \
  --fault-tab-evidence "$oneplus_neutral_fallback" \
  --fault-tab-evidence "$oneplus_full_fallback" \
  --fault-operation-receipt "$oneplus_neutral_rejection" \
  --fault-operation-receipt "$oneplus_neutral_quarantine" \
  --fault-operation-receipt "$oneplus_full_rejection" \
  --fault-operation-receipt "$oneplus_full_quarantine" \
  --profile-backup-receipt "$oneplus_profile_backup" \
  --tailnet-serve-receipt "$serve_receipt" \
  --output "$new_fleet_receipt"
```

Pass `--linux-full-graph-receipt` the external evidence directory's exact
`receipt.env`; the finalizer re-audits its sibling inventory and requires it to
equal both archived copies used by d and da.

The finalizer enforces phase chronology, independent d and da machine
identities, one physical OnePlus USB serial/model/fingerprint across every
Android phase,
fresh authenticated tab statuses, the complete d/da/OnePlus device matrix,
both tab replica restores and both corruption fallbacks per device, and the
browser-native password/cookie restore from NAS and peer for every device. It
never overwrites an output. Only its schema-4
`helium-sync-fleet-full-e2e-v4` receipt is a complete fleet pass.
