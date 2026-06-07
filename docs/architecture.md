# Architecture

## Goal

Sync Helium browser state across Linux and Android Helium builds:

- open tabs
- Helium built-in password-manager entries
- cookies

The standalone sync layer must not scrape or copy raw Chromium profile SQLite files. Raw database copying is brittle across Chromium versions and bypasses validation, encryption, metadata, and deletion semantics. Helium integration should use Chromium APIs and serialize API-level records into `helium-syncd`.

## Components

### `helium-syncd`

`helium-syncd` is a localhost HTTP daemon. It owns the encrypted append-only store and exposes a minimal JSON API to Helium or test clients.

### `helium-sync`

`helium-sync` is a CLI for initialization and testing. It creates the passphrase and token files, pushes JSON records, pulls records, and inspects a browser profile without printing secrets.

### Store

The store is append-only:

- `config.json`: salt and KDF parameters
- `records.jsonl`: encrypted records

Each record contains unencrypted routing metadata and an AES-GCM encrypted payload. The metadata is authenticated as AEAD additional data so tampering with sequence, kind, key, version, deletion, updated time, or origin device causes decryption failure.

## Conflict Behavior

`pull` returns all records after a sequence number. `latest` collapses records by `(kind, key)` and picks:

1. highest `version`
2. highest append `seq`

Deleted records are tombstones. `latest` hides tombstones by default, but clients can request them with `include_deleted=true`.

## Browser Integration Path

Helium should add a browser-side sync service that:

1. Watches local browser changes.
2. Serializes changes into `PlainRecord` payloads.
3. Pushes them to `helium-syncd`.
4. Polls or subscribes for remote changes.
5. Applies remote records through Chromium APIs.

Recommended hooks:

- Passwords: `PasswordStoreInterface` and existing `PasswordForm` serialization, similar to Chromium's own password sync bridge path.
- Cookies: `network::mojom::CookieManager::GetAllCookies`, `SetCanonicalCookie`, and `AddGlobalChangeListener`.
- Tabs: `TabStripModelObserver`, `TabStripModel`, and session/navigation entries.

## Android

The same daemon can run in the Termux or chroot environment. Android Helium should talk to `127.0.0.1:<port>` over the same JSON API. If Android app sandboxing blocks direct localhost access from the browser process, the Android integration should use a small app-local bridge service and keep this daemon API unchanged.
