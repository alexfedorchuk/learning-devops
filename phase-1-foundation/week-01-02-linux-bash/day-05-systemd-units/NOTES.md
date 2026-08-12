# Day 5 — systemd: units

Date:
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Three questions from previous days, answered aloud before any new material.

## What I did

1. PID 1, up close: `ps -p 1 -o pid,ppid,cmd`, `systemctl status`, `systemctl
   get-default`, `systemctl list-units --type=target` — systemd is PID 1 on this box.
2. Surveyed the five unit types with `systemctl list-unit-files --type=service|socket|
   timer|mount` and `systemctl list-units --type=target` — recognized the taxonomy
   without going deep on timer/mount (those are days 6–7).
3. Wrote a real `.service` running as `labapp` (day 3's system user, put to use):
   `/opt/labapp-demo.sh` looping every 5s, wired into `labapp-demo.service` with
   `Type=simple`, `Restart=on-failure`, `RestartSec=2`, enabled and started it.
4. Switched `labapp-demo.service` to `Type=forking` without `PIDFile=` and restarted
   it — recalled `systemctl status` showing `failed`, but not the exact wording.
   Likely mechanism, given the script (`while true; ... ; sleep 5; done`) never forks
   and never lets its original process exit: `Type=forking` makes systemd wait for
   exactly that fork-then-parent-exits handoff before considering the service
   started. Since this script does neither, systemd would keep waiting up to
   `TimeoutStartSec` (default 90s) for a signal that was never coming, then give up
   and mark the unit failed — even though the script itself was healthy and looping
   the whole time. Exactly the "systemd's belief desyncs from reality" failure mode
   `Type=` mismatches cause.
5. `Restart=` in action: `kill -9` on the main PID, watched systemd bring it back up
   on its own within seconds, restart count visible in `systemctl status`.
6. `Requires=` vs `Wants=`: wired `demo-b.service` to a deliberately-failing
   `demo-a.service` (`ExecStart=/bin/false`), compared outcomes under `Requires=`
   (b fails to start when a fails) vs `Wants=` (b starts regardless).
7. `systemctl edit labapp-demo.service` — added a `Restart=always` drop-in,
   confirmed the composed result with `systemctl cat`. Also found two diagnostic
   commands beyond the plan: `systemctl list-units --state=failed` (system-wide
   failure overview) and `systemctl status <unit>` for a single-unit deep dive.

## What broke

Wrote `crash-demo.service` with `ExecStart=/bin/false`, `Restart=always`,
`RestartSec=1` — a unit designed to crash-loop. It hit systemd's built-in rate
limiter and entered `start-limit-hit`, refusing further restart attempts (systemd's
default is 5 starts within a 10s window before it gives up and requires manual
intervention — confirm this matches what `man systemd.unit` showed you for
`StartLimitIntervalSec=`/`StartLimitBurst=`).

The real fix was replacing the crashing command, not just clearing the failure state:
changed `ExecStart` to `/bin/sleep infinity` (a command that actually stays running),
then `systemctl reset-failed crash-demo.service` to clear systemd's failure counter.
Confirmed the unit now starts cleanly and stays up — `reset-failed` alone would have
just re-armed a unit that was still guaranteed to crash-loop again immediately.

## What surprised me

- `daemon-reload` isn't about the service, it's about systemd's own memory. systemd
  parses unit files once and caches them; editing a `.service` file on disk changes
  nothing about what `systemctl` actually acts on until `daemon-reload` re-parses it.
  Hit this directly: edited `labapp-demo.service`, got "unit file ... changed on disk"
  from systemctl — a live warning that I was about to operate on a stale in-memory
  definition, not the file I'd just saved.
- Naming convention, confirmed by googling: `d` suffix = daemon (`sshd`, `systemd`,
  classic Unix convention predating systemd itself); `ctl` suffix = the CLI that
  controls a specific daemon (`systemctl`↔systemd, `journalctl`↔journald,
  `loginctl`↔logind, `networkctl`↔networkd, `resolvectl`↔resolved). Makes unfamiliar
  command names guessable on sight from now on.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. `After=network.target` doesn't guarantee the network is actually up. Why, and
   what should you use instead?

   `After=`/`Before=` is pure ordering — it says nothing about whether the referenced
   unit actually starts or succeeds, and `network.target` itself is reached quickly
   without meaning an interface has an IP. Need two things together:
   `Wants=network-online.target` + `After=network-online.target` — a target
   specifically meant to represent a genuinely usable network. `Wants=` rather than
   `Requires=` deliberately: making network readiness a hard dependency means the
   service never even attempts to start if the network is slow or absent; `Wants=`
   lets it try regardless — the safer default for boot.

2. What's the difference between `Requires=` and `Wants=` when the dependency fails?

   `Requires=` is a hard dependency: if the required unit fails or stops, this unit
   gets stopped too. `Wants=` is soft/best-effort: this unit starts and keeps running
   regardless of whether the wanted unit succeeded.

3. Why does systemd reliably kill every child process of a service, while SysV init
   often couldn't?

   systemd itself is a userspace process (PID 1), not kernel code — but every service
   it starts lives inside its own kernel-managed **cgroup**. To kill a service
   completely, systemd doesn't rely on remembering PIDs; it asks the kernel for every
   process in that cgroup, however deeply it forked. SysV init had no such
   kernel-backed grouping — it tracked one remembered PID and easily lost track of
   descendants that forked or re-parented.

## Open questions
