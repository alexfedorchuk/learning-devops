# Command lookup card

**Purpose: you are stuck right now and need the command.** Organised by the question
you're asking, not by the day it was learned. Terse on purpose — no explanations, only
what each command answers and the traps that make it silently wrong.

This is the *lookup* half of the reference. The `week-N-cheatsheet.md` files are the
*retention* half — prose, mechanisms, and the "why" for rereading before an interview.
Different jobs; when in doubt, Cmd-F this file first.

Covers days 1–10. Append as later days land; keep it task-indexed, never
chronological.

---

## A process is misbehaving

```bash
ps aux                       # BSD syntax          } different languages,
ps -ef                       # UNIX syntax         } not variants of one flag set
pstree -p                    # parent/child chain with PIDs
top                          # watch the `wa` field for iowait
```

| Symptom | Check |
|---|---|
| High load, idle CPU | Process states — load counts `R` **and** `D`. Mostly `D` = I/O-bound, not CPU-bound |
| Process won't die, even `kill -9` | State `D` (uninterruptible, inside the kernel). Signals only act at safe points it hasn't reached |
| Process won't die, shows as defunct | State `Z` (zombie) — already dead. Ignores all signals; the *parent* must `wait()`. Kill the parent |
| Huge VSZ, normal RSS | Fine. VSZ is mapped address space, much of it never touched. RSS is what's resident |

```bash
cat /proc/<pid>/status                        # VmRSS, VmSize, state, threads
ls -l  /proc/<pid>/fd                         # what it has open
cat    /proc/<pid>/limits                     # effective limits, not the shell's
sudo cat /proc/<pid>/environ | tr '\0' '\n'   # env of a process you didn't start
grep -E '^Sig(Ign|Cgt|Blk)' /proc/<pid>/status  # which signals it ignores/catches
```

Signal numbers worth knowing: `INT`=2, `QUIT`=3, `KILL`=9, `TERM`=15, `CHLD`=17.
Exit code for a signal death is `128 + N` (`SIGINT` → 130, `SIGTERM` → 143).

## Keeping something alive after I log out

```bash
nohup cmd &        # stays in the session, ignores SIGHUP
setsid cmd         # new session, no controlling terminal — SIGHUP never generated
systemd-run --user --unit=name cmd   # leaves the login session, real unit lifecycle
```

## Disk is full / write fails

```bash
df -h                    # blocks free
df -i                    # INODES free  <- check this when df -h looks fine
du -sh /path/*           # what's big, one level down
sudo lsof +L1            # deleted-but-still-open files (space held with no filename)
```

| `df` says | `du` says | Cause |
|---|---|---|
| more used | less used | Deleted file still held open by a process — `lsof +L1`, kill or `: > /proc/<pid>/fd/<N>` |
| free space | — | Out of **inodes** (`df -i`), or ext4's 5% root reserve if you're not root |

Inode count is fixed at `mkfs` time — a filesystem full of tiny files runs out of
inodes with blocks to spare.

## Disks, mounts, LVM

```bash
lsblk -f                 # tree of devices + filesystems + UUIDs
blkid                    # UUIDs, one line per device
mount | column -t        # what's actually mounted right now
cat /etc/fstab           # what's mounted at boot — use UUID=, never /dev/sdX
sudo mount -a            # test fstab WITHOUT rebooting  <- do this before every reboot
```

LVM chain is **file → loop device → PV → VG → LV**:

```bash
sudo losetup -fP disk.img            # attach a file as a block device
sudo losetup -d /dev/loop0           # detach
sudo pvcreate /dev/loop0             # physical volume
sudo vgcreate myvg /dev/loop0        # volume group
sudo lvcreate -L 50M -n myvol myvg   # logical volume
sudo lvextend -r -L +50M /dev/myvg/myvol   # grow LV *and* filesystem (-r)
sudo lvremove / vgremove / pvremove  # teardown, in that order
```

`-r` on `lvextend` resizes the filesystem too — without it you grow the volume and
the filesystem still thinks it's the old size.

## Permissions denied and I don't see why

```bash
namei -l /full/path/to/file    # permissions of EVERY component in the path
id                             # my uid/gid/groups
```

Almost always a missing `x` on a *directory* in the path, not the file's own mode.
`x` on a directory = permission to traverse it.

| Mode | Use |
|---|---|
| `755` | directories, executables |
| `644` | regular files |
| `600` | SSH private keys — anything looser is **refused** |
| `750` | group-readable private |

Deleting a file needs `w` on the **directory**, not on the file — a 444 file is still
deletable. Setuid is ignored on any `#!` script.

## SSH

```bash
ssh -L 8080:localhost:80 host   # reach a remote service on my localhost:8080
ssh -R 8080:localhost:80 host   # expose MY local :80 on the remote's :8080
```

The first port is always on the side the connection **originates** from.

```bash
sudo sshd -t                     # syntax-check config before reloading
sudo sshd -T                     # EFFECTIVE config  <- the only source of truth
sudo sshd -T | grep -i passwordauth
sudo systemctl reload ssh        # SIGHUP, re-reads config in place
```

Hardening (`/etc/ssh/sshd_config.d/00-hardening.conf`):

```
PasswordAuthentication no
PermitRootLogin no
AllowUsers <user>
KbdInteractiveAuthentication no
```

**Drop-in ordering trap.** `Include /etc/ssh/sshd_config.d/*.conf` expands in lexical
order and OpenSSH takes the **first** value it obtains, not the last. Ubuntu cloud
images ship `50-cloud-init.conf` with `PasswordAuthentication yes` — name yours
`00-*` so it wins. Always confirm with `sshd -T`, never by reading your own file.

**Golden rule:** keep the first session open and verify from a **second** one before
closing it. Applies to sshd changes and to enabling a firewall.

`ssh -A` (agent forwarding) lets root on the remote sign anything with your key for
the life of the session. Leave it off.

## systemd services

```bash
systemctl status <unit>
systemctl cat <unit>             # the unit file(s) actually in use, drop-ins included
systemctl show <unit>            # every effective property
systemctl edit <unit>            # create a drop-in; survives package upgrades
systemctl daemon-reload          # REQUIRED after editing a unit file by hand
systemctl reset-failed <unit>    # clears the start-limit counter, fixes nothing else
systemctl list-units --failed
systemctl list-dependencies <unit>
```

`daemon-reload` re-parses unit files; a service's own `reload` re-reads *its* config.
Two separate caching layers — don't confuse them.

| Directive | Meaning |
|---|---|
| `After=` / `Before=` | ordering only, says nothing about whether the other unit runs |
| `Requires=` | hard dependency — if it fails, this unit is stopped too |
| `Wants=` | soft dependency — this unit proceeds regardless |

`network.target` does **not** mean an interface has an IP. Use
`Wants=network-online.target` + `After=network-online.target` — `Wants=`, so a slow
network doesn't hard-block startup.

`Type=`: `simple` (default, no confirmation), `exec` (execve succeeded), `forking`
(original process forked and exited — needs `PIDFile=`), `notify` (daemon calls
`sd_notify`).

Sandboxing worth knowing: `PrivateTmp=true` gives the unit its own mount namespace
with a private `/tmp` and `/var/tmp`, destroyed on stop — isolation in both
directions, and it kills `/tmp` symlink attacks.

## Logs

```bash
journalctl -u <unit>          # one unit
journalctl -u <unit> -f       # follow
journalctl -b                 # this boot
journalctl -b -1 -u <unit>    # PREVIOUS boot — what died before the reboot
journalctl --since "1 hour ago"
journalctl -p err             # priority err and worse
journalctl --disk-usage
```

`/var/log/auth.log` exists only if `rsyslog` is installed; otherwise everything is in
the journal.

## Timers (cron replacement)

```bash
systemctl list-timers --all
systemctl status <name>.timer
```

`Persistent=true` runs a missed occurrence at next boot; plain cron just skips a tick
that happened while the machine was off. `RandomizedDelaySec=` spreads load when many
machines share a schedule.

## Packages and updates

```bash
apt update                   # refresh the index only, changes nothing installed
apt upgrade                  # upgrade installed pkgs; never removes anything
apt full-upgrade             # will remove packages if that's what it takes
apt-cache policy <pkg>       # installed vs candidate vs available versions
apt-mark hold <pkg>          # pin
apt-mark showhold
needrestart                  # services still running against OLD library versions
dpkg -l | grep <pkg>
```

`apt upgrade` replaces files on disk; a running process keeps the **old** shared
library mapped until restarted — that's what `needrestart` surfaces.

`make install` leaves no package record at all — no `dpkg` manifest, no `apt remove`
path. Only `make uninstall` (if the Makefile has it) or manual deletion. Use
`checkinstall` on a server so it builds a real `.deb`.

## Firewall

```bash
sudo ufw allow OpenSSH       # FIRST, before anything else
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable              # LAST
sudo ufw status verbose      # effective state
```

Order is not stylistic: `enable` with default-deny and no SSH rule locks you out of a
remote box permanently. Verify from a second session before closing the first.

## Writing a bash script

Header, every time:

```bash
#!/bin/bash
set -euo pipefail
```

| Flag | Does | Does NOT |
|---|---|---|
| `-e` | exit on any non-zero command | fire inside `if`/`while` conditions, left of `&&`/`\|\|`, or on a pipeline's non-final command |
| `-u` | error on **unset** variable | catch set-but-empty (`VAR=""`) — use `[[ -n "${VAR:-}" ]]` |
| `pipefail` | pipeline status = rightmost non-zero | — |

Cleanup that actually works:

```bash
cleanup() {
  [[ -n "$tmpfile" && -f "$tmpfile" ]] && rm -f "$tmpfile"
  return 0                    # <- REQUIRED
}
trap cleanup EXIT
trap 'exit 130' INT           # 128 + 2
trap 'exit 143' TERM          # 128 + 15
```

Two traps that cost real debugging time:

- **A trap's last command sets the script's exit code.** `cleanup` ending on a failed
  `[[ ]]` makes a fully successful script exit 1. Always `return 0`.
- **A signal trap that doesn't `exit` resumes at the interrupted line** — so cleanup
  deletes the temp file and execution continues into the code that needed it. Signal
  traps must exit; the EXIT trap then runs cleanup once.
- `trap ... INT` is a **no-op** if the shell started with SIGINT ignored — which is
  what `&` without job control does. Nothing warns you. Verify in the launch context
  you'll actually use (systemd, cron), not just interactively.

Quoting:

- `"$var"` always — unquoted gets word-split on `$IFS` and glob-expanded.
- `"$@"` passes each argument as its own word; `$*` joins them into one. Always `"$@"`.
- `[[ ]]` over `[ ]` — a keyword, parsed by bash, immune to word-splitting; has `=~`.
- `$(...)` over backticks — nests without escaping, no extra backslash layer.
- `local x=$(false)` masks the exit status (`$?` is `local`'s, always 0). Split the
  declaration from the assignment.

Idempotency: `mkdir -p`, check-before-act, and the bar is that **two consecutive runs
both succeed and the second changes nothing**.

```bash
shellcheck script.sh    # free reviewer — but LEXICAL only
```

`shellcheck` will not catch trap semantics, exit-code overrides, or a swallowed
signal. It passed clean on a script that reported failure on every success. Passing it
is a floor, not evidence of correctness.

## Redirection and streams

Every process starts with fd `0`=stdin, `1`=stdout, `2`=stderr. Redirection just
repoints those entries, **left to right**. `2>&1` copies fd 1's *current value* — it
is not a lasting link.

```bash
cmd >file 2>&1     # fd1→file, then fd2→copy of fd1  =>  BOTH into file
cmd 2>&1 >file     # fd2→copy of fd1 (still terminal), then fd1→file  =>  stderr to terminal
cmd &>file         # shorthand for the first form
```

```bash
cmd 2>/dev/null              # discard stderr
cmd | tee file               # inspect mid-pipeline
cmd | tee -a file            # append
cmd | sudo tee /etc/foo      # write to a root-owned file
```

`sudo cmd > /etc/foo` fails — the **shell** opens the file, as you, before `sudo` even
starts. `| sudo tee` is the fix.

`>` truncates **before** the command runs, so `sort file > file` destroys it.

```bash
<<EOF        # heredoc, expands $vars
<<'EOF'      # heredoc, literal, no expansion
<<-EOF       # heredoc, allows the terminator to be tab-indented
<<<"$var"    # herestring, one line to stdin
```

Process substitution supplies a **filename** where a program won't take a pipe:

```bash
diff <(cmd1) <(cmd2)
while read x; do ...; done < <(cmd)   # NOT  cmd | while read
```

`cmd | while read` runs the loop in a subshell, so variables set inside don't survive.

## Text processing

```bash
grep -E 'pat'      # extended regex, no \( \| escaping
grep -o 'pat'      # print only the match, not the line
grep -c / -v / -F  # count / invert / fixed-string (fast, no regex)
cut -d' ' -f3      # splits on ONE char, does not collapse repeats
awk '{print $5}'   # splits on RUNS of whitespace — use on aligned logs
sort -n / -rn / -k2 / -u
uniq -c            # counts ADJACENT duplicates only — sort first, always
jq -r '.foo'       # -r for raw output, no quotes
```

Canonical counting tail:

```bash
... | sort | uniq -c | sort -rn | head -10
```

Count-and-group in awk:

```bash
awk '{count[$1]++} END {for (k in count) print count[k], k}'
```

**Never use fixed field numbers on logs.** Positions shift with message shape and with
the timestamp format — classic syslog (`Jan 10 05:01:22`) is 3 fields, RFC3339
(`2026-08-25T12:07:20+03:00`) is 1, so every `$9` from a tutorial is off by two.
Anchor on a stable landmark instead:

```bash
awk '{for (i=1;i<=NF;i++) if ($i=="from") print $(i-1), $(i+1)}'   # user and IP
```

Pick the landmark whose *neighbours* are fixed-length: `for` is followed by a
variable-length phrase (`invalid user admin`), `from` is always preceded by exactly
one word.

```bash
find . -name '*x*' -print0 | xargs -0 cmd
```

`-0` is a **contract between two commands** — both sides must agree on the delimiter.
`find | xargs` splits on whitespace (breaks names with spaces); `find | xargs -0`
with no `-print0` is worse, treating the whole stream as one argument including the
trailing newline. Setting it on one side alone just swaps one bug for another.

## Counting things in logs

Before counting, decide **which line is the event**. One SSH attempt writes several
lines, so counting IP occurrences across all of them multiplies the total (8 vs the
true 3, measured).

On a key-only server there is no `Failed password` line at all — sshd rejects before
any password is tried. Grep `Invalid user` and `[preauth]` instead. A one-liner built
on `Failed password` returns empty on a hardened box and reads as "nobody is
attacking me".

## The habit worth generalising

Read **effective state**, never the file you wrote:

```bash
sudo sshd -T              # not: cat sshd_config
sudo ufw status verbose   # not: cat the rules file
systemctl show <unit>     # not: cat the unit file
sudo sshd -t              # validate before reload, always
```

A config file can be correct, present, and completely ignored — with no warning.
