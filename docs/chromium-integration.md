# Chromium / Helium Integration Notes

## Do Not Sync Raw Files

Avoid syncing these directly:

- `Login Data`
- `Network/Cookies`
- session files under `Sessions/`

Those files are implementation details. They can contain platform-encrypted blobs, WAL state, and version-specific schema changes. Copying them also skips Chromium validation and deletion behavior.

## Record Payloads

The payloads should be JSON because the daemon remains browser-agnostic.

### Tabs

Suggested key:

```text
<device-id>/window/<window-id>
```

Suggested payload:

```json
{
  "active_index": 0,
  "tabs": [
    {
      "url": "https://example.com",
      "title": "Example",
      "pinned": false,
      "last_active_unix_ms": 1760000000000
    }
  ]
}
```

### Passwords

Suggested key:

```text
<signon_realm>/<username_element>/<username_value>/<origin_url>
```

Suggested payload fields should mirror Chromium `PasswordForm` fields needed to reconstruct a login through `PasswordStoreInterface::AddLogin`, `UpdateLogin`, or `RemoveLogin`.

### Cookies

Suggested key:

```text
<partition-key>/<domain>/<path>/<name>
```

Suggested payload fields should mirror `net::CanonicalCookie` fields needed for `network::mojom::CookieManager::SetCanonicalCookie`.

## Build Strategy

Desktop Helium builds go through this repo's platform wrapper:

```sh
bash scripts/build.sh linux x86_64
gh workflow run build.yml -f platform=linux -f arch=x86_64 -f run-build=true
```

`scripts/prepare-platform.sh` clones the official Helium platform repo, removes
Helium's upstream password-disable patch, injects the restored-password patches,
and then injects `chromium/patches/*.patch` as `patches/helium/sync/`.

Android is still handled separately from the desktop Helium platform repos:

```sh
gh workflow run chromium-android.yml
```

The Android workflow uses a reduced Chromium Android checkout and builds
`HeliumSync.apk` by default. It applies `chromium/patches/*.patch`, uses
`chromium/overlay/` for local development parity, sets Chromium's checkout to
`small`, skips test-only Android CIPD payloads, changes the package to
`computer.helium.sync`, and adds `cc_wrapper = "ccache"` to generated GN args.

Full Chromium builds are expensive. Larger/self-hosted runners are preferred.
Standard `ubuntu-24.04` runners can smoke-test wiring, but previous full builds
timed out near GitHub's six-hour hosted-runner limit. The Android workflow keeps
source-specific Ninja output caches and ccache enabled so reruns can warm the
build state instead of starting completely over.
