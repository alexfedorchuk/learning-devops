# artifact-server-bootstrap — build notes

Started: 2026-08-26 (day 11 of week 1–2)
Target: Ubuntu 24.04 LTS (arm64). Developed against the Pi, to be verified in a
clean LXD container.

## Status against the definition of done

`CURRICULUM.md`, days 11–12. Seven of eleven closed.

| | Requirement | State |
|---|---|---|
| ✅ | admin user with SSH key, passwordless sudo for that user only | written, dry-run verified |
| ✅ | sshd hardening: no passwords, no root, custom port, `AllowUsers` | written, dry-run verified |
| ✅ | firewall: default deny incoming, SSH allowed | written, dry-run verified |
| ✅ | `unattended-upgrades` enabled and configured | written, dry-run verified |
| ✅ | `set -euo pipefail`, `trap` cleanup, every step logged | done |
| ✅ | `--dry-run` mode | done, verified to leave system state byte-identical |
| ✅ | passes `shellcheck` with no warnings | clean, checked on the Pi (`/usr/bin/shellcheck`) |
| ❌ | monitoring timer: disk, memory, load, failed units + Telegram alert | **not started** |
| ❌ | runs twice, second run changes nothing | **not verified** — dry-run only |
| ❌ | verified on a genuinely clean machine | **not done** |
| ❌ | English README | **not written** |

Honest status: *passes shellcheck and has a correct dry-run*. It has never been
run for real. Nothing below the line has been demonstrated.

## What I did

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
   This is week 2's recurring lesson turned into a design requirement.
5. Verified on the Pi: `shellcheck` clean, `--help` works unprivileged, usage
   errors exit 2 and runtime errors exit 1, and a dry-run left
   `00-hardening.conf`, `/etc/sudoers.d/`, ufw state and the user list
   byte-identical.

## What broke

Every one of these was found by **running** the script, not by reading it.
`shellcheck` saw none of them.

1. **`pipefail` turned a normal situation fatal.** The first dry-run stopped
   silently after one step, exit 2:

   ```bash
   home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
   ```

   `getent` exits 2 for an unknown user — exactly the expected case in a dry-run
   for a user not created yet. Without `pipefail` the pipeline would return
   `cut`'s 0; with it the assignment fails and `set -e` kills the script, before
   the `${home:-/home/$USER_NAME}` fallback on the very next line could run. The
   comment promising that fallback was sitting right above the line that made it
   unreachable. Fixed with `|| true`.

2. **`grep -q` killed its own producer — SIGPIPE, exit 141.** `verify` failed its
   first sshd assertion even though the value was correct:

   ```bash
   sshd -T | grep -qix "passwordauthentication no"    # exit 141
   ```

   `grep -q` exits on the first match and closes the pipe; `sshd -T` is still
   writing, takes SIGPIPE, dies with 128+13; `pipefail` promotes that to the
   pipeline. A passing check reports failure.

   Worse than a consistent bug, because it is a **race**: `ufw status` is short
   enough to finish writing before grep exits, so that call worked, while the
   longer `sshd -T` did not. Fixed in all three places by capturing output first
   and grepping a herestring.

3. **`verify` asserted on the wrong unit entirely.** It checked
   `systemctl is-enabled unattended-upgrades`, but that unit is
   `Description=Unattended Upgrades **Shutdown**` — the handler that holds
   shutdown while an upgrade finishes. The periodic work is done by
   `apt-daily.timer` / `apt-daily-upgrade.timer` reading `APT::Periodic::*`.

   Demonstrated by switching automatic upgrades fully off and re-running:

   ```
   apt-config dump  ->  APT::Periodic::Unattended-Upgrade "0"
   verify           ->  passed
   ```

   So `verify` would have declared success on a machine with automatic upgrades
   disabled — the precise failure it exists to prevent. Now checks
   `apt-config dump` and `apt-daily-upgrade.timer`.

## What surprised me

- That strict mode bites for **expected** non-zero exits at least as often as it
  catches real bugs. Three times in two days: `local x=$(false)` masking a
  status, `getent` returning 2 for a missing user, `grep -q` SIGPIPE-ing its
  producer. `pipefail` is what converts each of them from harmless to fatal.
  The working rule: wherever a pipeline can legitimately end non-zero, say so
  explicitly (`|| true`) or remove the pipeline.
- That `/etc/apt/apt.conf.d/20auto-upgrades` is owned by no package at all
  (`dpkg -S` finds nothing). The postinst generates it by copying either
  `/usr/share/unattended-upgrades/20auto-upgrades` or `-disabled`, chosen by the
  debconf answer `unattended-upgrades/enable_auto_updates` (template default:
  true). So writing it is usually redundant — but the value depends on an answer
  an image builder can preseed to false. Declaring it means the outcome does not
  depend on someone else's default.
- How much of "is it configured?" is answered only by logs. The Pi's
  `unattended-upgrades.log` has 53 recorded runs and shows it removing superseded
  kernels. Config plus an enabled timer says it *should* work; the log is what
  says it *did*.

## Remaining work — day 12

In this order, because the clean-machine run should exercise the finished
artifact rather than half of it.

1. **Monitoring timer** — the only missing feature. A summary script (disk,
   memory, load, failed units) driven by a systemd timer, alerting to Telegram
   past thresholds. Add `/var/run/reboot-required` to the summary: a kernel
   security update installs but does not take effect until reboot, so "updates
   are automatic" is only half true without it.

   **Decide first:** the Telegram bot token is a secret and `.gitignore` blocks
   `.env*`. It has to reach the script from outside the repo — argument,
   environment variable, or a file mode 0600 that is never committed. First time
   this artifact touches secrets; worth doing deliberately.

2. **Clean machine.** LXD is installed on the Pi but not initialised
   (`lxd init` still to run). Check early whether `ufw` behaves inside an
   unprivileged container — netfilter in a network namespace may conflict with
   the LXD bridge. If it does, fall back to an LXD VM or a throwaway VPS.

3. **Run twice.** The second run must print `changes applied: 0`. This single
   line is the only real proof of idempotency — it is what caught the earlier
   `0644` vs `644` mode-comparison bug, which was invisible on a first run.

4. **Break it.** Interrupt mid-run and record what state the machine is left in.
   Check the traps in the real launch context rather than an interactive shell:
   a shell started with SIGINT already ignored cannot trap it, and nothing warns
   you.

5. **README + this write-up.** README needs what it does, how to run it, its
   assumptions, and what it deliberately does not do. Two entries for that last
   section are already established: it does not reboot after a kernel upgrade
   (availability is the owner's call, not the script's), and it is not how this
   is done in practice — cloud-init and Ansible are, and this exists to show the
   mechanics they wrap.

## Open questions

- Does `ufw` work correctly inside an unprivileged LXD container? Decides
  whether the clean-machine test can happen on the Pi at all.
- Should the monitoring summary go to the journal, a file, or both? The journal
  is queryable (`journalctl -u`) and rotates itself; a file is easier to `tail`
  but needs its own rotation.
- `bats` is still not installed anywhere. The `main "$@"` call is already
  guarded by `BASH_SOURCE` so the file can be sourced without configuring the
  machine, but no tests exist yet.
