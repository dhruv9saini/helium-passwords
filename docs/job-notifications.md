# Helium Build Completion Analysis

Every production Chromium or complete Helium job is armed for one real Codex
analysis turn. A terminal build record never sends a success, failure, timeout,
or cancellation template. The Codex final response is the only normal email,
and Mailbridge can route it only to `dhruv.codex@gmail.com`.

## Single Flow

```text
chromiumer job cgroup
  -> atomic terminal.env
  -> lm systemd timer (30 seconds, persistent)
  -> private immutable analysis prompt
  -> Mailbridge queue-event in state.sqlite3
  -> tmux + normal Codex runner in /home/d
  -> transactional Mailbridge outbox
  -> authenticated SMTP and Sent reconciliation
```

Chromiumer contains no mail address, mail credential, Mailbridge state, or
Codex credential. The repository-owned worker atomically records one of
`success`, `failure`, `timeout`, or `cancellation`, plus duration, exit code,
and a reason. That reason is evidence for Codex and is explicitly not treated
as a diagnosis.

The lm wrapper registers the build before it starts. Private producer state is
under:

```text
/home/d/.local/state/helium-job-notifier/jobs/<job>.json
/home/d/.local/state/helium-job-notifier/events/<job>.txt
```

The system timer polls the remote terminal record. Once terminal, the producer
atomically writes a mode-0600 prompt containing:

- product, job ID, terminal state, duration, exit code, and recorded reason;
- immutable source provenance and the intended artifact/test summary;
- public and private repository paths;
- exact build, watchdog, artifact, and retained-workspace commands/locations;
- the current end-to-end Helium objective; and
- instructions to inspect evidence, validate artifacts, fix or continue the
  next safe in-scope work, and report actual findings.

It then calls exactly this Mailbridge class of interface:

```sh
/home/d/coding/codex-mailbridge/.venv/bin/codex-mailbridge \
  --config /home/d/.config/codex-mailbridge/config.toml \
  queue-event \
  --key "helium-build:${job}:terminal" \
  --conversation 'Helium build operations' \
  --prompt-file "/home/d/.local/state/helium-job-notifier/events/${job}.txt" \
  --json
```

There is no recipient, cwd, send-now, subject, or static-body argument. The
literal conversation is persistent, so later terminal events resume the same
Codex operational context. Mailbridge fixes cwd at `/home/d` and snapshots its
single configured user address internally.

`queue-event` and the producer key are idempotent. Identical process, timer,
restart, or concurrent retries return the same event and turn. Rebinding the
key to changed prompt bytes, conversation, or recipient fails without
mutation. A crash after the SQLite commit but before producer-state update is
safe: the producer retains the exact prompt and retries the same key.

Mailbridge sends no receipt. Its durable status progresses through `queued`,
`running`, `completed`, and `emailed`; `completed` means the Codex final result
and outbox committed atomically. Normal delivery uses a stable Message-ID,
definite-failure retry, and Sent reconciliation for uncertain SMTP acceptance.

A static email is forbidden for product terminal states. Only Mailbridge may
create one diagnostic fallback, exactly once, after the Codex execution
infrastructure itself exhausts its bounded retries. The product build result
is never an infrastructure failure. Even after that fallback is sent,
`event-status` remains `failed`, preserving both facts. The lower-level
`queue-notification` interface rejects both historical `helium-job:` and
current `helium-build:` namespaces.

## Installation and Status

Install the reviewed public backbone on lm:

```sh
cd /home/d/coding/helium/helium-passwords
scripts/install-job-notifier.sh
systemctl status helium-job-notifier.timer --no-pager
systemctl list-timers helium-job-notifier.timer --no-pager
```

Installed paths are:

```text
/home/d/.local/libexec/helium-job-notifier
/etc/systemd/system/helium-job-notifier.service
/etc/systemd/system/helium-job-notifier.timer
```

The oneshot service runs as `d` with a 10% CPU quota, 128 MiB memory maximum,
32-task limit, low scheduling priority, private umask, and no credential
arguments. The persistent system timer runs at boot and every 30 seconds.
Detached shells, tmux disconnects, and lm restarts do not lose either the local
watch or the Mailbridge SQLite event.

Content-free inspection is:

```sh
/home/d/.local/libexec/helium-job-notifier status "$job"
/home/d/coding/codex-mailbridge/.venv/bin/codex-mailbridge \
  --config /home/d/.config/codex-mailbridge/config.toml \
  event-status --key "helium-build:${job}:terminal" --json
journalctl -u helium-job-notifier.service --since today --no-pager
journalctl -u codex-mailbridge.service --since today --no-pager
```

Temporary Chromiumer or queue-interface failures leave the producer in
`watching` or `terminal-pending` and retry on the next timer. After Mailbridge
accepts the event, it is the source of truth for Codex retry, outbox, fallback,
and delivery state. Notification failure can never change `terminal.env`.

## Starting Jobs

The wrapper requires operator context before start:

```sh
scripts/chromiumer-job.sh start "$job" \
  --summary "What this exact run tests or produces" \
  --next "The first useful action after a verified success" -- \
  <build-command> [arguments...]
```

Use a new job ID for each new run. Its ID is the immutable terminal-event
identity and cannot be reused with different source or operator context.

## Offline Acceptance

The repository simulation performs no Chromium build, Codex invocation,
mailbox access, or external mail:

```sh
scripts/tests/helium-job-notifier.test.sh
```

It synthesizes all four terminal states and proves:

- every result uses the same `queue-event` path;
- required terminal, provenance, objective, repository, log, and artifact
  fields appear in the protected prompt;
- repeated, concurrent, and restart-style polling queues one event;
- a temporary queue failure retains identical prompt bytes and retries;
- producer state mirrors Mailbridge's content-free lifecycle; and
- no recipient option, recipient environment path, static template, or
  `queue-notification` invocation remains.

Mailbridge's own fake-transport suite separately proves the normal Codex
runner, bounded retry, daemon/tmux restart recovery, atomic result/outbox
commit, exactly-once fallback, SMTP retry, and Sent reconciliation. Do not
queue a synthetic event in the live database: the supervised daemon would
correctly run Codex and send its final response.

No Codex project `Stop` hook is installed. Turn-scope hooks would be a second
path and create routine-agent mail rather than one analysis per terminal build.

## Historical Static Acceptance

The 2026-07-21 `hp-notify-accept-20260721-1829` proof and subsequent build
templates established the old static-notification path. That path is now
retired. Existing sent records remain historical evidence, but no new build
terminal event may use them or the `helium-job:` notification namespace.
