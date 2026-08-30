# artifact-server-bootstrap — build notes

Started: 2026-08-26 (day 11), finished: 2026-08-30 (day 12)
Target: Ubuntu 24.04 LTS (arm64). Developed against the Pi, verified on clean
LXD containers running on it.

## Status against the definition of done

`CURRICULUM.md`, days 11–12. All eleven closed.

| | Requirement | Where it was proven |
|---|---|---|
| ✅ | admin user with SSH key, passwordless sudo for that user only | clean container, run 1 of 3 |
| ✅ | sshd hardening: no passwords, no root, custom port, `AllowUsers` | clean container; port confirmed with `ss -ltn`, not with `sshd -T` |
| ✅ | firewall: default deny incoming, SSH allowed | clean container; `ufw` works in an unprivileged LXD container |
| ✅ | `unattended-upgrades` enabled and configured | clean container, `apt-config dump` |
| ✅ | monitoring timer: disk, memory, load, failed units + Telegram alert | clean container; timer fired, summary in the journal |
| ✅ | `set -euo pipefail`, `trap` cleanup, every step logged | |
| ✅ | `--dry-run` mode | dry-run predicted 10 changes, the real run applied exactly 10 |
| ✅ | passes `shellcheck` with no warnings | Pi, shellcheck 0.9.0, all three scripts |
| ✅ | runs twice, second run changes nothing | `changes applied: 0`, twice, on two separate containers |
| ✅ | verified on a genuinely clean machine | `lxc launch ubuntu:24.04`, destroyed and recreated between passes |
| ✅ | English README | `README.md` |

## Re-quiz (day 12, spaced retrieval)

Three questions from days 8–10, answered aloud before any new material — two
correct, one wrong.

1. Day 8: why can an unattended `apt upgrade` take down production? **Correct.**
   `unattended-upgrades` takes only the security pocket, `apt upgrade` takes
   everything. Sharpened: the real damage is not "unread changelog" but that a
   package upgrade **restarts its daemon** — `needrestart` will do it mid-day —
   and that a new kernel installs without taking effect until a reboot.
2. Day 9: `rm -rf "$DIR/"` with `DIR` unset — what happens, what saves you?
   **Wrong.** Answered `--preserve-root`. It is real and it is the default, but
   it only covers the literal `/`: `rm -rf "$DIR/logs"` expands to `/logs` and
   is deleted without a word, and BusyBox has no such check. The answer under my
   own control is `set -u` — the `u` in the `set -euo pipefail` already at the
   top of this artifact — or `${DIR:?message}` at the point of use.
3. Day 10: `2>&1 >file` vs `>file 2>&1`. **Correct.** Sharpened wording: `2>&1`
   *copies fd1's current target* into fd2. A copy, not a link — which is exactly
   why the later `>file` moves fd1 and fd2 stays on the terminal.

## Day 11 — what I did

1. Built `bootstrap.sh` around one idea: idempotency is a property of the
   **check**, not of the command. Prefer commands that are safe to repeat
   (`mkdir -p`, `chmod`, `apt-get install`, `ufw allow`) and only check state
   where repeating would actually do harm — creating a user, rewriting a config.
2. `write_file` writes only on a content difference and sets `LAST_CHANGED`, so
   `harden_ssh` can skip reloading sshd when nothing moved. A global `CHANGED`
   tally makes idempotency **observable**: a second run must print `0`.
3. Ordered `main` for lockout safety, each step gated by the previous one:
   `ensure_user` (the key must exist before `AllowUsers` names the account) →
   `setup_firewall` (the port must be open before sshd listens on it) →
   `harden_ssh` → `security_updates` → `verify`.
4. `verify` asserts **effective state** — `sshd -T`, `ufw status`,
   `apt-config dump`, `systemctl is-enabled` — never the files just written.
5. Verified on the Pi: `shellcheck` clean, `--help` works unprivileged, usage
   errors exit 2 and runtime errors exit 1, and a dry-run left
   `00-hardening.conf`, `/etc/sudoers.d/`, ufw state and the user list
   byte-identical.

## Day 11 — what broke

Every one of these was found by **running** the script, not by reading it.
`shellcheck` saw none of them.

1. **`pipefail` turned a normal situation fatal.** `home="$(getent passwd "$USER_NAME" | cut -d: -f6)"`
   — `getent` exits 2 for an unknown user, exactly the expected case in a
   dry-run, and `set -e` killed the script before the `${home:-...}` fallback on
   the next line could run. Fixed with `|| true`.
2. **`grep -q` killed its own producer — SIGPIPE, exit 141.** `sshd -T | grep -qix ...`
   failed while the value was correct: `grep -q` exits on the first match, the
   producer takes SIGPIPE, `pipefail` promotes 141. Worse than a consistent bug
   because it is a **race** — the short `ufw status` survived, the long
   `sshd -T` did not. Fixed by capturing output and grepping a herestring.
3. **`verify` asserted on the wrong unit.** It checked
   `unattended-upgrades.service`, which is only the *shutdown* handler. The
   periodic work is `apt-daily.timer` / `apt-daily-upgrade.timer` reading
   `APT::Periodic::*`. Demonstrated by switching upgrades fully off and watching
   `verify` still pass — the precise failure it exists to prevent.

## Day 12 — what I did

1. Split the monitor into its own file. `shellcheck` cannot look inside a
   heredoc, so a monitor embedded in `bootstrap.sh` would have been the one part
   of the artifact the linter never saw.
2. Decided the three things that make it an artifact rather than a script:
   credentials in a root-owned `0600` file outside the repo; the summary to
   stdout so journald owns history and rotation; Telegram **only on a change in
   the set of active alerts**, so an alert stays a signal.
3. Wrote `monitor-v1.sh` first — the same requirement in 56 lines — and kept it
   deliberately. The diff between it and `monitor.sh` is a list of concrete
   failures: alert spam every 15 minutes, an alert silently lost when the
   network is down, and the bot token visible in `ps` to every user on the box.
4. Verified on clean LXD containers: `lxc launch ubuntu:24.04`, dry-run, run,
   run again, destroy, repeat. Then broke it on purpose.

## Day 12 — what broke

1. **My own firewall broke the test environment.** The container could not
   resolve anything, and `apt-get update` reported four `W: Failed to fetch`
   lines. Cause: the Pi's `default deny incoming` from day 8 dropped DHCP and
   DNS coming from `lxdbr0`, so the container never got a lease. Fixed on the
   **host** with `ufw allow in on lxdbr0` + `ufw route allow in on lxdbr0` — and
   the container had to be restarted, because nothing re-requests a lease that
   was never granted. The symptom pointed at apt; the cause was three days old.

2. **`apt-get update` exits 0 when it cannot reach a single mirror.** Those `W:`
   lines are warnings by design: apt falls back to the indexes it already has.
   So the script sailed past a machine with no network at all and only failed
   later, with a message about a package. Fixed with
   `-o APT::Update::Error-Mode=any`, which turns those warnings into a real
   failure.

3. **`sshd -t` could not run: `Missing privilege separation directory: /run/sshd`.**
   `/run` is a tmpfs and `/run/sshd` is created by `RuntimeDirectory=sshd` when
   ssh starts. On a machine where sshd has never started, the *validation step*
   itself is impossible. Invisible on the Pi, where sshd has run since boot.
   Fixed with `install -d -m 0755 /run/sshd` before the check.

4. **sshd is socket-activated on Ubuntu 24.04 — and that silently defeated
   `verify`.** In the container `ssh.socket` is enabled and `ssh.service` is
   disabled: systemd owns the listening socket and hands the connection to
   `sshd -i`. The `Port` keyword in `sshd_config` is then **ignored entirely**.

   `sshd -T` still reports `port 2222`, so `verify` passed while nothing was
   listening on 2222 — the script would have declared success on a machine
   nobody could reach. This is week 2's "the file is right, nothing reads it"
   lesson, one level up: it walked straight through the check written to catch it.

   Fixed in three places: a `ssh.socket.d/00-port.conf` drop-in whose first line
   is an empty `ListenStream=` (the list is inherited and accumulates — without
   clearing it the socket keeps listening on 22 too), `restart` rather than
   `reload` because sockets cannot be reloaded, and `verify` now asserting
   against `ss -ltn` instead of `sshd -T`. Confirmed afterwards:
   `LISTEN 0 4096 0.0.0.0:2222 users:(("systemd",pid=1,fd=54))`, and nothing on 22.

5. **`trap ... INT` did nothing.** Sent SIGINT to a run 6 seconds in; the script
   kept going. Bash starts a background child in a non-interactive shell with
   SIGINT set to `SIG_IGN`, and a signal ignored on entry **cannot be trapped or
   reset** — the `trap 'exit 130' INT` at the bottom of the file was silently
   inert, exactly as suspected on day 11. SIGTERM worked and exited 143. The
   lesson is not "add a trap" but that a trap is only as real as the launch
   context allows, and nothing warns you.

6. **A failed run leaves partial state.** Killed during `apt-get update`, the
   machine was left with the user and its sudoers rule created, no firewall, no
   sshd hardening. The controlled version — a missing key file — left `broke`
   created with no key and no sudo rule at all. The script is **idempotent, not
   transactional**: it does not roll back, it converges on the next run. Proved
   it: re-running after the interrupt applied 7 changes and the run after that
   applied 0.

7. **The two ssh units are not mutually exclusive — found on the Pi, not in the
   container.** Checking the lab server afterwards: `ssh` and `ssh.socket` are
   **both enabled and both active**, and `ss -ltnp` shows two owners of port 22 —
   `sshd` (pid 71254) and `systemd` (pid 1). My first fix used `if/elif` and
   treated them as alternatives, so on that machine it would have moved the
   socket to 2222 and left `ssh.service` serving 22. Rewritten as two
   independent checks: the socket gets its drop-in, a running `ssh.service` gets
   a reload, and `verify` now also warns when something is still listening on 22
   after the port has moved. The container only ever showed the socket-only
   case; the Pi is what showed the combination.

8. **The control channel died mid-run and the work kept going.** `lxc exec`
   dropped with `websocket: close 1006 (abnormal closure)` during
   `apt-get update` on a loaded Pi. The script's process went with it, but
   `apt-get` itself survived as an orphan, so the next run hit
   `Could not get lock /var/lib/apt/lists/lock. It is held by process 715`.
   Not a bug in the artifact — a reminder that killing the thing you started is
   not the same as killing what it started, and that "run it again" needs the
   previous run to be genuinely finished.

## Day 12 — what surprised me

- **`20auto-upgrades` was already byte-identical on the stock image.** The
  postinst had generated it from the debconf default. So the write is redundant
  on stock Ubuntu and load-bearing only where an image builder preseeded
  `enable_auto_updates` to false. That also answers the `dpkg-reconfigure -plow
  unattended-upgrades` question: it is the interactive front door to the same
  file, not a different mechanism.
- **`/proc/meminfo` and `/proc/loadavg` inside the container described the host.**
  `lab-monitor` reported 899 MiB total and a load of 1.96 on 4 cores — those are
  the Pi's numbers, not the container's. Monitoring from inside a container
  measures the wrong machine unless the tool reads cgroup limits.
- **The dry-run's own arithmetic is the proof it changed nothing.** It predicted
  10 changes; the real run that followed applied exactly 10. Had the dry-run
  leaked a single change, the second number would have been smaller.

## Open questions

- The both-units-enabled path is **written but not run**. Fixing it correctly
  would mean running the bootstrap against the Pi itself and moving the port on
  the machine this whole lab is reached through — not something to do casually,
  and not something to claim without doing. The container only proves the
  socket-only case.
- The script never reverts: moving a machine back from `ssh.socket` to
  `ssh.service`, or back to port 22, leaves the drop-ins in place. Removal is a
  separate mode and it is not written.
- `verify` does not assert that port 22 **stopped** listening after the move. It
  is deliberate — 22 is left open in the firewall so the move cannot lock anyone
  out — but "the old door is closed" is currently unchecked.
- `bats` is still not installed anywhere. `main "$@"` is guarded by
  `BASH_SOURCE` so the file can be sourced without configuring the machine, but
  no tests exist.
