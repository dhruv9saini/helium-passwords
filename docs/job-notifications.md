# Helium Build Completion Analysis

Every production Chromium or complete Helium job is armed for one durable work
item in the already-running Codex session on `da`. A terminal build record
never starts an isolated Codex worker and never sends a success, failure,
timeout, cancellation, or Codex-final template. Outbound delivery requires an
explicit reviewed queue response.

## Single Flow

```text
chromiumer job cgroup
  -> atomic terminal.env
  -> lm systemd timer (30 seconds, persistent)
  -> private immutable analysis prompt
  -> dedicated restricted SSH key
  -> da queue-import-helium forced command
  -> canonical work-queue.sqlite3
  -> pinned already-running Codex tmux pane
```

Chromiumer contains no mail address, mail credential, work-queue state, or
Codex credential. The repository-owned worker atomically records one of
`success`, `failure`, `timeout`, or `cancellation`, plus duration, exit code,
and a reason. That reason is evidence for Codex and is explicitly not treated
as a diagnosis.

The lm wrapper registers the build before it starts. Private producer state is
under:

```text
/home/d/.local/state/helium-job-notifier/jobs/<job>.json
/home/d/.local/state/helium-job-notifier/events/<job>.txt
/home/d/.local/state/helium-job-notifier/events/<job>.queue.json
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

It then streams the protected immutable queue envelope through exactly this
SSH command:

```sh
ssh -F none -o BatchMode=yes -o IdentitiesOnly=yes \
  -o ClearAllForwardings=yes -o RequestTTY=no \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/home/d/.ssh/helium_queue_da_known_hosts \
  -i /home/d/.ssh/helium_queue_da_ed25519 d@da \
  queue-import-helium \
  <"/home/d/.local/state/helium-job-notifier/events/${job}.queue.json"
```

The dedicated key is not shared with either Mac integration key. Its
authorized-key line uses `restrict` and the forced command
`/home/d/coding/codex-mailbridge/scripts/remote-helium-queue-import.py`.
That gateway accepts no PTY, forwarding, shell, status, update, or delivery
command. It validates the full envelope and admits only
`local:helium-build:<job>:terminal`, `source_kind=local`, and
`response_policy=important_only`.

The producer key and complete queue envelope are idempotent. Identical timer,
process, restart, concurrent, or commit-before-local-state-update retries
return the same work item. Rebinding the key to changed immutable bytes fails
without mutation and moves the producer to visible terminal
`analysis-conflict`; it never invents another key or falls back to a template.
Network, SSH, or da-service failures leave the exact local prompt and envelope
in `terminal-pending` and retry on the next timer.

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
Detached shells, tmux disconnects, and lm restarts do not lose the local watch,
terminal evidence, import envelope, or da queue item.

Content-free inspection is:

```sh
/home/d/.local/libexec/helium-job-notifier status "$job"
journalctl -u helium-job-notifier.service --since today --no-pager
```

Temporary Chromiumer or queue-interface failures leave the producer in
`watching` or `terminal-pending` and retry on the next timer. After da accepts
the item, its canonical queue is the source of truth for work status and any
explicit response. Notification failure can never change `terminal.env`.

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

- every result uses the same restricted `queue-import-helium` path;
- required terminal, provenance, objective, repository, log, and artifact
  fields appear in the protected prompt;
- repeated, concurrent, and restart-style polling imports one immutable item;
- a temporary queue failure retains identical prompt bytes and retries;
- a changed immutable envelope fails closed without another key;
- existing terminal prompt bytes remain authoritative across an upgrade; and
- no local Mailbridge path, recipient, static template, isolated Codex worker,
  or automatic delivery invocation remains.

Mailbridge's own suite separately proves queue-import idempotence, immutable
conflict handling, restart-safe wake delivery, exact live-pane binding, and
explicit-only response delivery.

No Codex project `Stop` hook is installed. Turn-scope hooks would be a second
path and create routine-agent mail rather than one analysis per terminal build.

## Historical Static Acceptance

The 2026-07-21 `hp-notify-accept-20260721-1829` proof and subsequent build
templates established the old static-notification path. That path is now
retired. Existing sent records remain historical evidence, but no new build
terminal event may use them or the `helium-job:` notification namespace.
