# Day 6 — journald, timers, sandboxing

Date:
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Answered aloud before any new material — all three correct, no corrections needed:

1. Day 3: `sudo -s` vs `sudo -i`/`sudo su -` — `-s` keeps `$HOME`/cwd/env as-is;
   the other two simulate a full root login (`$HOME=/root`, root's own environment).
2. Day 4: `ssh -A` risk — the remote can sign anything via the forwarded agent for as
   long as the session lives, without ever getting the actual private key file.
3. Day 4: TOFU — nothing to check on the first connection, fingerprint shown and
   pinned to `known_hosts` on trust; real verification happens from the second
   connection onward.

## What I did

1. journald query shapes: `journalctl -u labapp-demo -n 20`, `-p err`, `--since
   "10 min ago"`, `-f` (followed live from a second terminal), `-o json-pretty`,
   `--disk-usage`, and `-b -1` to read logs from the previous boot.
2. Checked persistent storage: `/var/log/journal`, `journald.conf`'s `Storage=`
   setting, then capped it with a drop-in — `/etc/systemd/journald.conf.d/
   size-limit.conf` setting `SystemMaxUse=200M`, restarted `systemd-journald`,
   confirmed the new budget with `--disk-usage`.
3. Built a real timer: `labapp-heartbeat.service` (`Type=oneshot`, `User=labapp`)
   paired with `labapp-heartbeat.timer` using `OnBootSec=`, `OnCalendar=*:0/2`,
   `Persistent=true`, `RandomizedDelaySec=10`. Sanity-checked the calendar syntax
   separately with `systemd-analyze calendar`.
4. Tested `Persistent=true`: stopped the timer, waited past an interval, restarted
   it, confirmed the missed run fired immediately via `journalctl -u
   labapp-heartbeat.service`.
5. Sandboxed `labapp-demo.service` (day 5's service): gave it a file to write
   (`/var/lib/labapp-demo/state.log`, owned by `labapp`), confirmed it wrote fine,
   then added `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`,
   `NoNewPrivileges=yes` via `systemctl edit`. Watched the write start failing under
   the sandbox, diagnosed and fixed the two bugs below, then closed the hole
   narrowly with `ReadWritePaths=/var/lib/labapp-demo` instead of removing the
   protections.
6. Scored the result with `sudo systemd-analyze security labapp-demo.service` —
   read through which remaining exposures were still costing points.

## What broke

Two separate bugs surfaced while sandboxing `labapp-demo.service`, found with
`systemd-analyze verify` (a real, useful catch — not in the original day plan):

1. **A bug in the day's own instructions.** The `sed` command given to append a
   `tee` pipe to the script's `echo` line didn't account for the closing `"` already
   present in `echo "$(date -Iseconds) alive"` — it only matched the bare word
   `alive`, leaving the original closing quote in place *and* adding another one,
   producing a dangling unmatched quote at end of line:
   `/opt/labapp-demo.sh: line 2: unexpected EOF while looking for matching '"'`.
   Fixed by rewriting the line directly instead of trusting the `sed` one-liner.
2. **`ReadWritePath=` instead of `ReadWritePaths=`** in the drop-in — a one-letter
   typo. systemd doesn't fail on an unrecognized directive, it silently ignores it
   with a log warning, so `ProtectSystem=strict` kept blocking the write and the
   intended exception never took effect. No crash, no obvious error — just a write
   that kept failing for a reason that looked, at a glance, like it should have been
   fixed already. `systemd-analyze verify` surfaced it explicitly.

## What surprised me

- `systemd-analyze verify` catches unit-file typos that would otherwise fail
  silently — an unknown directive like `ReadWritePath=` doesn't error, it's just
  ignored, which is a much sneakier failure mode than a hard crash.
- The timer↔service link needs no explicit wiring: `labapp-heartbeat.timer`
  activates `labapp-heartbeat.service` automatically because the names match — no
  `Unit=` directive required in `[Timer]`. `Unit=` only matters when the timer needs
  to trigger a service with a *different* name.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. Why is a systemd timer better than cron for a daily backup on a machine that gets
   shut down?

   `Persistent=true` fires the missed run as soon as the machine comes back if it was
   off when the timer should have fired — cron just silently misses it. Timers also
   have more expressive scheduling (`OnCalendar=`) with a dry-run check via
   `systemd-analyze calendar`, unlike cron's opaque 5-field syntax.

2. A service crashed overnight and the machine got rebooted. How do you look at its
   last logs?

   `journalctl -b -1 -u <unit>` — logs from the *previous* boot, filtered to that
   unit.

3. `systemd-analyze security` gives a unit 9.6 UNSAFE. Name three directives that
   would lower that fastest.

   `ProtectSystem=strict`, `NoNewPrivileges=yes`, `ProtectHome=yes` — confirmed
   against a real `systemd-analyze security labapp-demo.service` run as the three
   highest-weight exposures on an unhardened unit, not just named from a list.

## Open questions
