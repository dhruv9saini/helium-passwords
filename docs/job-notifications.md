# Helium Build Terminal Monitor

Helium build completion monitoring is a local, content-free operations path. It
records what Chromiumer reports and never launches an assistant or sends a
message.

## Retirement boundary

The former OpenBubbles, activation-payload, Mailbridge, work-queue, email, and
personal-relay paths are retired. No Helium job may call them or recreate an
equivalent delivery path. Existing historical records are evidence only.

The retained boundary is deliberately narrow:

```text
chromiumer isolated job
  -> atomic terminal.env
  -> da persistent user timer
  -> mode-0600 local JSON state
```

Chromiumer owns the build result. The monitor does not diagnose, rewrite, or
publish it. A separate reviewed operator session may inspect that local state
and the underlying build evidence.

## State and behavior

Before a production job starts, `scripts/chromiumer-job.sh` registers its
product, summary, expected next action, and pinned source manifest. State lives
at:

```text
/home/d/.local/state/helium-job-notifier/jobs/<job>.json
```

Every 30 seconds, the timer asks the constrained Chromiumer worker for the
job's terminal record. While a job is nonterminal the local status remains
`watching`. Once Chromiumer returns a valid result, the monitor atomically
records:

- `success`, `failure`, `timeout`, or `cancellation`;
- duration and exit code;
- Chromiumer's recorded reason;
- the pinned product and source context; and
- `status: "terminal-recorded"`.

A temporary SSH or Chromiumer failure leaves the job watched with a visible
`last_poll_error`; a later poll retries. Concurrent polls serialize under a
local lock. Repeated polls cannot create a second terminal record.

Legacy delivery-era JSON is migrated in place to schema 3 by removing delivery
keys and retaining the underlying build result. No event prompt, recipient,
message body, account credential, or remote delivery record is produced.

## Installation on da

Install the reviewed monitor into the user systemd manager:

```sh
cd /home/d/coding/helium/helium-passwords
scripts/install-job-notifier.sh
systemctl --user status helium-job-notifier.timer --no-pager
systemctl --user list-timers helium-job-notifier.timer --no-pager
```

Installed paths are:

```text
/home/d/.local/libexec/helium-job-notifier
/home/d/.config/systemd/user/helium-job-notifier.service
/home/d/.config/systemd/user/helium-job-notifier.timer
```

The oneshot has a private umask, a 10% CPU quota, a 128 MiB memory maximum, a
32-task limit, and low scheduling priority. The persistent timer survives
detached shells and da restarts.

Content-free inspection is:

```sh
/home/d/.local/libexec/helium-job-notifier status "$job"
journalctl --user -u helium-job-notifier.service --since today --no-pager
```

## Starting jobs

The build wrapper requires operator context before it starts:

```sh
scripts/chromiumer-job.sh start "$job" \
  --summary "What this exact run tests or produces" \
  --next "The first useful action after a verified success" -- \
  <build-command> [arguments...]
```

Use a new job ID for every new run. Registration is idempotent only when all
bound context is byte-for-byte identical.

## Offline acceptance

```sh
scripts/tests/helium-job-notifier.test.sh
```

The simulation covers every terminal result, temporary Chromiumer loss,
concurrent/restart-style polling, immutable local records, and migration from
legacy delivery state. It performs no Chromium build, assistant invocation,
account access, network delivery, or external message.
