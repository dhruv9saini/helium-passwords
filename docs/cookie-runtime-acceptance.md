# Desktop native cookie runtime acceptance

This is the executable desktop transport gate for the native Chromium
`CookieManager` bridge. It runs only after a private Linux artifact has passed
`verify-linux-runtime.sh` and the private password lifecycle has produced
`sync-receipt.json`. It never uses CDP, an extension, a cookie writer, a raw
profile database, or a personal profile.

Use the passed private-password profile on d and initialize a second fresh
Linux admission run on da with the same verified runtime. `d-test` is the
active seed; `da-test` starts pending and uses only its own enrollment
directory. The final cookie receipt binds da's untouched zero-capture
`run.json`, proving that its profile was created only after the da runtime and
complete receipt inventory were rehashed. The fixture binds to `127.0.0.1` on d. A temporary
strict Tailnet SSH local-forward on da exposes the same loopback host and port,
so Chromium sees one exact origin on both machines without making the fixture
public. Stop that forward during cleanup.

The ordered lifecycle is deliberately small and observable:

1. On d, visit `/d/set-initial`. The page requires an initially absent target
   cookie and sets one random host-only, HttpOnly, SameSite=Lax cookie.
2. Start the pending da profile. Wait for both native bridges to apply/read
   back one joint cursor and activate the enrollment. Visit
   `/da/observe-initial`; the fixture accepts only the exact cookie created on
   d.
3. On da, visit `/da/set-updated`; it first requires the received d value and
   then replaces it with a second random value.
4. After d pulls the next revision, visit `/d/observe-updated`.
5. On d, visit `/d/delete`; it first requires the received da value and then
   expires the cookie.
6. After da pulls the tombstone, visit `/da/observe-deleted`; the fixture
   accepts only an absent cookie and atomically creates final hash-only
   evidence.

Before advancing from each page, visually inspect it and capture the whole
browser window as a private PNG with these exact names:

```text
01-d-initial.png
02-da-initial.png
03-da-updated.png
04-d-updated.png
05-d-deleted.png
06-da-deleted.png
```

Start the fixture with the exact nonce from the private password run:

```sh
node scripts/cookie-runtime/fixture-server.mjs \
  --port 0 \
  --run-nonce "$(jq -er .run_nonce "$run/run.json")" \
  --evidence "$run/cookie-fixture-evidence.json"
```

The fixture never writes or prints either cookie value. Its evidence contains
only their SHA-256 fingerprints, fixed attributes, the loopback origin, the
shared run nonce, and six ordered booleans.

After both browsers have stopped, copy the terminal mode-0600
`cookie-state.json` files and a contemporaneous private copy of the complete
readable server journal into the evidence root. Final verification requires:

- the admitted browser to still hash to the passed private password receipt;
- the two schema-5 cookie states to be byte-identical, unblocked, and at the
  complete journal cursor;
- exactly three cookie journal records for one canonical key: d revision 1,
  da revision 2, then the d tombstone at revision 3;
- the two live payload values to hash to the fixture fingerprints without
  retaining those values in the receipt;
- valid, visually reviewed PNGs with the exact six-file inventory; and
- a create-new receipt path.

Run:

```sh
node scripts/cookie-runtime/acceptance.mjs verify \
  --sync-receipt "$run/sync-receipt.json" \
  --da-admission-run "$run/da-admission-run.json" \
  --artifact "$verified/helium-sync-linux-x86_64/runtime/helium-wrapper" \
  --artifact-receipt "$verified/artifact-receipt.env" \
  --fixture-evidence "$run/cookie-fixture-evidence.json" \
  --d-cookie-state "$run/d-cookie-state.json" \
  --da-cookie-state "$run/da-cookie-state.json" \
  --journal "$run/records.jsonl" \
  --screenshot-dir "$run/cookie-screenshots" \
  --output "$run/cookie-receipt.json"
```

This proves real pending-join pull, a bidirectional native cookie revision,
and a deletion tombstone between d and da. It does not replace the Android
marker-gated CookieManager transaction, partitioned-cookie matrix, device
background lifecycle, or exact-origin reauthentication evidence.
