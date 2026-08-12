# Week 1 cheat sheet — processes, permissions, SSH, systemd

Compressed from days 1–5. Full write-ups and command-by-command history live in each
day's `NOTES.md`; this is the reread-before-an-interview version.

## Processes & `/proc` (day 1)

**fork/exec.** `fork()` clones the calling process — new PID, copied page tables and
fd table, **zero bytes of memory copied**. Pages are shared read-only; a page is
duplicated only when either side writes (copy-on-write). Returns twice: `0` in the
child, child's PID in the parent. COW is a *necessity*, not an optimization: fork is
almost always immediately followed by `exec()`, which discards the child's memory
entirely — without COW, every shell command would mean physically copying the
parent's whole address space just to throw it away.

**Process states:**

| State | Meaning |
|---|---|
| `R` | Running/runnable — wants CPU now |
| `S` | Interruptible sleep — waiting on something (normal, most of the system) |
| `D` | Uninterruptible sleep — *inside* the kernel (usually I/O); signals, incl. `kill -9`, only act at safe points the process hasn't reached yet |
| `Z` | Zombie — already dead, just an exit-status entry waiting for the parent to `wait()`. Ignores all signals. Fix: reap via the parent, not `kill` |
| `T` | Stopped (`Ctrl-Z` / `kill -STOP`) |

**Load average** counts `R` **+** `D` processes, not just CPU demand. 8.0 on 4 cores
is only "2× overloaded" if they're mostly `R`; if mostly `D`, CPU may be idle and the
box is I/O-bound. Check `htop`/`ps` for states, `top`'s `wa` field for iowait.

**VSZ vs RSS.** VSZ = mapped address space, including memory never touched — costs
nothing. RSS = pages actually resident in RAM — the real number, though it still
counts pages shared with other processes (libc etc.), so even RSS overstates a
process's *private* footprint slightly.

**Orphans.** When a parent dies first, orphaned children are adopted by PID 1 —
unless a **subreaper** (`PR_SET_CHILD_SUBREAPER`, e.g. `systemd --user`, container
supervisors) intercepts adoption instead.

**Toolkit:**
- `ps aux` (BSD syntax) vs `ps -ef` (UNIX syntax) — different languages, not variants
- `pstree -p` — the parent chain
- `sudo cat /proc/<pid>/environ | tr '\0' '\n'` — env of a process you didn't start
  (NUL-separated, needs root: env often holds secrets)
- `/proc/<pid>/{status,fd,maps,limits}` — VmRSS/VmSize, open fds, memory map, limits

## Signals, file descriptors, limits (day 2)

**Core signals:**

| Signal | Meaning | Catchable? |
|---|---|---|
| `SIGINT` (2) | `Ctrl-C` | yes |
| `SIGTERM` (15) | polite "please exit", `kill`'s default | yes |
| `SIGHUP` (1) | terminal/session gone; daemons repurpose it as "reload config" | yes |
| `SIGKILL` (9) | kernel reclaims the process directly | **no — never delivered to the process** |

SIGKILL can't be caught **by design**: if a process could catch/ignore it, a hung or
malicious process could make itself unkillable. The kernel guarantees the admin a
last resort by never giving the process a chance to react.

**Surviving a closed SSH session** (all solve SIGHUP differently):
- `nohup` — stays in the session, makes the process ignore SIGHUP
- `setsid` — new session, **no controlling terminal at all**, so SIGHUP is never
  generated for it
- `systemd-run` — leaves the login session entirely, becomes a transient systemd unit
  with real lifecycle management

**Deleted-but-open file.** `rm` removes only the directory entry; data lives until
the **last open fd** on it closes. `df` won't drop until then.
`sudo lsof +L1` → find the holder → kill it, or gentler: `: > /proc/<pid>/fd/<N>` to
truncate without killing. Systemic fix: log rotation.

**fd limits.** Soft limit (`ulimit -n`) — enforced now, process can raise it up to
the hard limit (`ulimit -Hn`, root-only to raise). `ulimit -n 65535` in `.bashrc`
fixes nothing for a *service* — `.bashrc` only runs for interactive shells; a
systemd-started service never passes through it. Real fix: `LimitNOFILE=` on the unit.

## Users, permissions, sudo (day 3)

**The kernel only knows numbers.** UID/GID are the only truth; names are a lookup
table in `/etc/passwd`/`/etc/group`. System users (UID < 1000, shell = `nologin`)
exist so a compromised *service* can't touch another service's files — isolation
between services, not just from real users.

**rwx: files vs directories**

| Right | On a file | On a directory |
|---|---|---|
| `r` | read contents | list names inside |
| `w` | modify/truncate | create/delete/rename entries — **independent of the file's own permissions** |
| `x` | execute as program | enter the directory — required to resolve any path through it |

Classic trap: `chmod 777` file, still unreadable → missing `x` on a **directory** in
the path. Diagnose with `namei -l` (prints permissions of every path component).
Deleting a read-only (444) file still works — deletion is `w` on the directory, not
the file.

**chmod:** `7=rwx 6=rw- 5=r-x 4=r-- 0=---`. `755`=dirs/executables,
`644`=regular files, `750`=group-readable private.

**Special bits:** setuid (file runs as *owner's* UID, e.g. `passwd`) — **ignored on
any script starting with `#!`**, because script execution is two separate file
opens (kernel reads the shebang, then the interpreter re-opens the same path) with a
race window between them (TOCTOU/symlink swap) that setuid-on-binary doesn't have
(one atomic `execve()`). Sticky bit (`/tmp`): anyone creates, only owner deletes.

**sudo environments:** `sudo -s` keeps *your* `$HOME`/cwd/env, just runs as root.
`sudo -i` and `sudo su -` both reset to a full root login (`$HOME=/root`, root's own
profile). Looks the same at a glance ("I'm root") but very different state
underneath.

**SSH private key 644** → refused. Must be readable by owner only (`600`) — a
private key readable by others defeats asymmetric auth entirely; SSH fails loudly
rather than silently trust a possibly-compromised key.

## SSH (day 4)

**Two independent trust questions:** is the server who it claims (host keys, TOFU),
and is the client who it claims (keypair auth).

**TOFU.** First connection: nothing to check against — client shows the fingerprint,
you accept blindly, it's pinned to `known_hosts`. Only from the *second* connection
does a real check happen (compare against the pinned key); a mismatch means
reinstall **or** MITM, and the client can't tell which — so it refuses.

**Tunnels** (`-L`/`-R 8080:localhost:80`): the `8080` always names the port on the
side the connection *originates from*; `localhost:80` always names the side the
tunnel *reaches into*.
- `-L`: `me:8080 → tunnel → remote:80` — reach a remote service locally
- `-R`: `remote:8080 → tunnel → me:80` — expose a local service on the remote side

**Agent forwarding (`-A`) is a real hole.** Doesn't copy your key file — but root on
the remote can use your forwarded agent to *sign anything* for as long as the
session lives. Functionally equivalent to having the key. Don't leave it on.

**`authorized_keys` restrictions:** `command="..."` forces that key to always run one
command regardless of what's requested; `from="ip"` restricts source IP.

**`restart` vs `reload`.** Each SSH connection is served by its own forked child
process, independent of the master once forked. `restart` only kills/replaces the
**listening master** — existing sessions (their own forks) are untouched; only *new*
connections see the new config. `reload` is different again: SIGHUP, same process
re-reads its config in place, no replacement at all.

**Hardening:** `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers`,
`KbdInteractiveAuthentication no`. Golden rule: verify via a **second session**
before closing the first.

## systemd units (day 5)

**Why systemd > SysV init:** dependency graph (parallel start, not strict sequence);
every service lives in a kernel-managed **cgroup**, so killing a service means
asking the *kernel* for every process in that cgroup — not remembering a PID, which
is how SysV init lost track of re-parented/double-forked descendants. Socket
activation: systemd owns the listening socket, starts the service lazily on first
connection.

**Unit types:** `.service` (a process), `.socket` (activation), `.timer` (cron
replacement — day 6), `.mount` (day 7), `.target` (named goalpost, no process).

**`Type=`** — how a service tells systemd "I'm up". Wrong `Type=` desyncs systemd's
belief from reality (e.g. breaks `Restart=` loops on a healthy process):

| Type | systemd considers it started when |
|---|---|
| `simple` (default) | `ExecStart` is forked — no confirmation |
| `exec` | the `execve()` call itself succeeds |
| `forking` | the *original* process forks and **exits** — needs `PIDFile=` or systemd tracks the wrong PID |
| `notify` | the daemon calls `sd_notify(READY=1)` itself |

**`After=`/`Before=` vs `Requires=`/`Wants=` — orthogonal axes.** Ordering says
nothing about whether the other unit starts; dependency says nothing about order —
real units usually need both. `network.target` is reached quickly and does **not**
mean an interface has an IP; use `Wants=network-online.target` +
`After=network-online.target` together (`Wants=`, not `Requires=` — don't hard-block
startup on network readiness).

**`Requires=` vs `Wants=` on failure:** `Requires=` — dependency fails, this unit
gets stopped too. `Wants=` — best-effort, this unit proceeds regardless.

**`daemon-reload` vs a service's own `reload`.** systemd parses unit files once and
caches them — editing a `.service` file on disk changes nothing until
`daemon-reload` re-parses it. Different from a service's own config reload (e.g.
sshd's SIGHUP) — two separate caching layers.

**`systemctl edit <unit>`** → drop-in under `/etc/systemd/system/<unit>.d/`, survives
package upgrades, doesn't touch the vendor file. Same pattern as day 4's
`sshd_config.d/hardening.conf`.

**Crash loops:** `start-limit-hit` after too many restarts in a window
(`StartLimitIntervalSec=`/`StartLimitBurst=`, default 5 within 10s).
`systemctl reset-failed` only clears the counter — fix the actual `ExecStart` first,
or it just loops again immediately.

**Naming convention:** `d` suffix = daemon (`sshd`, `systemd`); `ctl` suffix = the
CLI controlling a specific daemon (`systemctl`↔systemd, `journalctl`↔journald,
`loginctl`↔logind, `networkctl`↔networkd, `resolvectl`↔resolved).
