# server-bootstrap

Takes a freshly installed Ubuntu server from "root with a password" to a baseline
hardened state, in one command, repeatably.

It is a teaching artifact. In practice this job belongs to cloud-init and Ansible —
the point here is to show the mechanics those tools wrap, in a form small enough to
read end to end.

## What it configures

| Step | What it does | Why it is ordered there |
|---|---|---|
| `ensure_user` | admin user, SSH key in `authorized_keys`, passwordless sudo for that user only | the key must exist before sshd is told to allow only this account |
| `setup_firewall` | installs `ufw`, allows the SSH port, default deny incoming | the port must be open before sshd starts listening on it |
| `harden_ssh` | drop-in `00-hardening.conf`: no passwords, no root, chosen port, `AllowUsers`; when sshd is socket-activated, the port moves in a `ssh.socket.d` drop-in instead | validated with `sshd -t` before anything is restarted — a bad config on a firewalled box means no way back in |
| `security_updates` | installs `unattended-upgrades`, declares `APT::Periodic::*`, enables the apt timers | |
| `install_monitoring` | `lab-monitor` script + systemd timer, health summary every 15 minutes | |
| `verify` | asserts effective state: `ss -ltn` for the port, plus `sshd -T`, `ufw status`, `apt-config dump`, timer state | a config file can be present, correct and completely ignored — and under socket activation `sshd -T` reports a port nothing is listening on |

## Requirements

- Ubuntu 24.04 LTS (developed and run on arm64; nothing in it is architecture-specific)
- root
- `monitor.sh` present next to `bootstrap.sh` — the script refuses to start without it

## Usage

Always dry-run first. It reports every change it would make and touches nothing:

```bash
sudo ./bootstrap.sh --user deploy --ssh-key /root/deploy.pub --ssh-port 2222 --dry-run
sudo ./bootstrap.sh --user deploy --ssh-key /root/deploy.pub --ssh-port 2222
```

| Option | Meaning |
|---|---|
| `-u, --user NAME` | admin user to create and configure (required) |
| `-k, --ssh-key PATH` | public key file to install for that user |
| `-p, --ssh-port PORT` | sshd listening port (default 22) |
| `-n, --dry-run` | report what would change, change nothing |
| `-h, --help` | usage and exit codes |

Exit codes: `0` success, `1` runtime failure, `2` usage error.

**Keep a second SSH session open the first time.** Changing `--user` or `--ssh-port`
rewrites `AllowUsers` and the listening port; if the new key or the firewall rule is
wrong, the open session is the only way back in.

Port 22 is deliberately left allowed in the firewall when a custom port is chosen, so
moving the port cannot lock anyone out. Closing it is a manual follow-up:
`ufw delete allow 22/tcp`.

## Idempotency

Every run prints the number of changes it applied:

```
[log]: done — changes applied: 7    # first run
[log]: done — changes applied: 0    # second run
```

`0` on the second run is the whole claim, and it is the only thing that proves it —
the state check is what makes a step idempotent, not the command. Files are compared
by content before being written; the sshd reload happens only when the config actually
changed; `daemon-reload` runs only when a unit file changed.

Two things are appended or created rather than rewritten, on purpose:

- `authorized_keys` — matched on the base64 key blob and appended, so keys added by
  hand survive.
- `/etc/lab-monitor.env` — created empty at mode `0600` if missing, never rewritten,
  because it holds the bot token.

## Monitoring

`lab-monitor` runs every 15 minutes (`OnBootSec=5min`, `OnUnitActiveSec=15min`) and
reports disk, inodes, `MemAvailable`, 5-minute load per core, failed units, and whether
a reboot is pending after a kernel update.

The summary goes to stdout, which under the timer means the journal:

```bash
journalctl -u lab-monitor -n 20
systemctl list-timers lab-monitor.timer
sudo /usr/local/sbin/lab-monitor --dry-run       # run it by hand, send nothing
sudo env DISK_PCT=0 /usr/local/sbin/lab-monitor  # force an alert
```

Telegram is used for alerts only, and only when the **set of active alerts changes** —
a problem notifies once, a recovery notifies once. State lives in
`/var/lib/lab-monitor/alerts` and is written only after a message is actually
delivered, so a failed send is retried rather than silently swallowed.

To enable alerts, fill in `/etc/lab-monitor.env` (mode `0600`, never committed):

```
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
```

With the file empty, the summary still goes to the journal and nothing is sent.

Thresholds default to disk 85%, inodes 85%, memory below 10% available, load above
`nproc × 1.5`, and are overridable per run via the environment (`DISK_PCT`,
`INODE_PCT`, `MEM_AVAIL_PCT`, `LOAD_FACTOR`, `MOUNT`).

## Files

| File | Role |
|---|---|
| `bootstrap.sh` | the artifact |
| `monitor.sh` | installed as `/usr/local/sbin/lab-monitor` |
| `monitor-v1.sh` | kept deliberately: the same job in 56 lines, the version worth writing first. The difference between it and `monitor.sh` is a list of concrete failures — alert spam, an alert lost when the network is down, the bot token visible in `ps` |
| `NOTES.md` | build log: what broke, and how it was found |

`monitor.sh` lives in its own file rather than a heredoc inside `bootstrap.sh` for one
reason: `shellcheck` cannot look inside a heredoc, and "passes shellcheck" has to mean
the whole artifact.

## What it deliberately does not do

- **It is not how servers are provisioned in practice.** cloud-init handles first boot,
  Ansible handles the rest, and both are declarative and idempotent by design. This
  script exists to show what they do underneath.
- **It is not monitoring.** Real monitoring is `node_exporter` + Prometheus +
  Alertmanager: history, one alerting pipeline for a whole fleet, grouping and silences.
  `lab-monitor` is a smoke alarm for a single machine that has no monitoring stack yet —
  deliberately dumb, so that it does not depend on the thing it watches.
- **It does not reboot.** Automatic security updates install a new kernel but keep
  running the old one; the monitor reports `reboot: required` and stops there. When to
  take the availability hit is the owner's call, not the script's.
- **It does not close port 22** after moving sshd to another port (see above).
- **It does not manage a second user, fail2ban, or TLS.** Each of those is a separate
  decision with its own failure modes.
- **It does not encrypt the bot token.** `systemd-creds` with
  `LoadCredentialEncrypted=` would bind it to the host or TPM; on a Pi 3B without a TPM
  the gain over a root-owned `0600` file is small, so the file is the honest choice.
- **It does not undo anything.** Moving a machine back to port 22, or from
  `ssh.socket` to `ssh.service`, leaves the drop-ins in place. Removal is a separate
  mode and it is not written.
- **It is idempotent, not transactional.** An interrupted run leaves whatever it had
  already applied; there is no rollback. Recovery is to run it again, which is the
  point of the second-run-changes-nothing property.
- **It has no tests.** `main` is guarded by `BASH_SOURCE` so the file can be sourced
  without configuring the machine, but no `bats` suite exists yet.

## Verified

| Check | Where |
|---|---|
| `shellcheck` clean (0.9.0), all three scripts | Raspberry Pi 3B, Ubuntu 24.04 LTS (arm64) |
| `--help`, usage errors exit 2, runtime errors exit 1 | same |
| dry-run leaves system state byte-identical | same |
| full run on a genuinely clean machine, `verified`, exit 0 | `lxc launch ubuntu:24.04` on that Pi, 2026-08-30 |
| second run reporting `changes applied: 0` | same, and again on a second container |
| the chosen port is actually listening (`ss -ltn`) | same |
| monitoring timer fires and writes a summary to the journal | same |
| interrupted mid-run, then converged on a re-run (7 changes, then 0) | same |

Not verified: nothing here has been run on a machine reachable from the public
internet, and `ufw` was exercised inside an unprivileged container, not on bare metal
with a hostile network on the other side.

See `NOTES.md` for what broke on those runs — including a `verify()` that passed while
nothing was listening on the port it had just configured.
