# Helium Job Completion Notifications

Every production start is armed for one terminal notification to
`dhruv9saini@gmail.com`. This path is only for Chromium and complete Helium
jobs. It never sends mail for routine Codex turns.

## Single Flow

```text
chromiumer job cgroup
  -> atomic terminal.env
  -> lm systemd timer (30 seconds, persistent)
  -> protected lm watch record
  -> Mailbridge notifications.sqlite3
  -> authenticated SMTP and Sent reconciliation
```

Chromiumer contains no mail address, mail password, or Mailbridge state. Its
repository-owned worker atomically writes
`~/.local/state/helium-builds/<job>/terminal.env` with one of four results:
`success`, `failure`, `timeout`, or `cancellation`. The record also contains the
exit code, start and finish epochs, duration, and reason.

The lm control wrapper registers the job before starting it. Registration is
durable under `~/.local/state/helium-job-notifier/` and includes the product,
immutable source manifest fields, test or artifact summary, and the next useful
success action. If remote startup fails, a newly created watch is abandoned.

The system timer polls terminal state over the existing non-interactive SSH
connection. Once terminal, it invokes Mailbridge with the stable event key
`helium-job:<job-id>:terminal`. Repeated polls, process crashes, and lm restarts
cannot rebind that key to different content. Mailbridge stores the protected
body and delivery state in its independent
`~/.local/state/codex-mailbridge/notifications.sqlite3` queue. The existing
Mailbridge configuration and password file remain the only mail credential
source on lm.

SMTP acceptance marks the queue sent without affecting the already-recorded
build result. A definite temporary SMTP failure is retried with capped
exponential delay. If the connection fails after acceptance may have occurred,
Mailbridge uses the stable RFC Message-ID to reconcile against Sent and never
blindly resends an ambiguous delivery. An unresolved ambiguity becomes a
visible failed notification for manual review rather than risking a duplicate.

## Installation and Status

Install from the public backbone checkout on lm:

```sh
cd /home/d/coding/helium/helium-passwords
scripts/install-job-notifier.sh
systemctl status helium-job-notifier.timer --no-pager
systemctl list-timers helium-job-notifier.timer --no-pager
```

The installer places only code and unit files:

```text
/home/d/.local/libexec/helium-job-notifier
/etc/systemd/system/helium-job-notifier.service
/etc/systemd/system/helium-job-notifier.timer
```

The system service runs as `d` with a 10% CPU quota, 128 MiB memory limit,
32-task limit, low scheduling priority, a private umask, and no credential
arguments. The persistent timer runs at boot and every 30 seconds. A detached
shell or tmux disconnect is irrelevant; after an lm restart systemd resumes
polling the same watch files and Mailbridge resumes its SQLite queue.

Inspect state without exposing message bodies:

```sh
/home/d/.local/libexec/helium-job-notifier status "$job"
/home/d/coding/codex-mailbridge/.venv/bin/codex-mailbridge \
    --config /home/d/.config/codex-mailbridge/config.toml \
    notification-status --key "helium-job:${job}:terminal" --json
journalctl -u helium-job-notifier.service --since today --no-pager
journalctl -u codex-mailbridge.service --since today --no-pager
```

Notification polling deliberately exits successfully when chromiumer or
Mailbridge is temporarily unavailable. It records and logs a changed error
once, then retries on the next timer. Notification delivery can therefore
never replace or change the terminal build result.

## Starting Jobs

The wrapper requires notification content as part of the start contract:

```sh
scripts/chromiumer-job.sh start "$job" \
    --summary "What this exact run tested or the artifact it will produce" \
    --next "The first useful action after a successful run" -- \
    <build-command> [arguments...]
```

Use a new job ID for a new run. A job ID is the idempotency identity and cannot
be reused with different source or notification content.

## Source and Live Acceptance

The offline simulation is harmless and sends no mail:

```sh
scripts/tests/helium-job-notifier.test.sh
```

It synthesizes all four terminal results, proves each queues once across
repeated polls, and proves a temporary Mailbridge queue failure remains pending
and succeeds on the next poll. Mailbridge unit tests separately prove SQLite
restart recovery, stable Message-ID generation, definite SMTP retry, Sent
reconciliation after an uncertain result, and no resend after unresolved
ambiguity.

For a bounded live acceptance, stage one clean committed source tree with a
1 GiB job budget and run a short command through the production wrapper. This
exercises immutable source transfer, production cgroup policy, remote terminal
state, lm timer, SQLite queue, authenticated SMTP, and Sent reconciliation
without compiling Chromium. Record the unique job ID and Mailbridge status in
the completion report. Do not send a second acceptance message with another
job ID unless the first attempt fails before SMTP delivery.

No Codex `Stop` hook is installed. Official Codex project lifecycle hooks run
at turn scope and require project trust, so a Stop hook would be a second path
and would create the per-turn notifications this design excludes.

## Recorded Acceptance

On 2026-07-21, job `hp-notify-accept-20260721-1829` staged public commit
`3c3e6bcc96732ef16c19fa1ae8f30534473918ea` with a 1 GiB job budget and ran a
three-second harmless command under the production systemd profile. Chromiumer
wrote `result=success`, `exit_code=0`, and `duration_seconds=3`. The persistent
lm timer observed it, and Mailbridge notification key
`helium-job:hp-notify-accept-20260721-1829:terminal` reached `sent` with one
SMTP attempt and zero reconciliation attempts. A read-only Zoho Sent search
found exactly one message with its stable RFC Message-ID. Re-enqueueing the
same key and content returned the existing sent row; the attempt count and
single Sent match did not change. The disposable remote workspace and returned
fixture copy were removed through the normal verified-artifact cleanup path;
the remote job state, journal, manifest, hash, and receipt remain as evidence.
