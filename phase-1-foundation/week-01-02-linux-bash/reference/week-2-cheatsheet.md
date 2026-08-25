# Week 2 cheat sheet — journald, storage, packages, bash

Compressed from days 6–10. Full write-ups and command history live in each day's
`NOTES.md`; commands for mid-task lookup live in `commands.md`. This is the
reread-before-an-interview version: mechanisms and why they bite.

## journald, timers, sandboxing (day 6)

**journald is a structured, indexed store, not a text file.** Entries carry metadata
(unit, boot id, priority, PID), which is why `journalctl` can filter by unit and by
*boot* rather than by grepping strings. `-b -1` reads the previous boot — the answer
to "it crashed overnight and the machine rebooted". Text logs in `/var/log/` exist
only where `rsyslog` is installed alongside.

**Persistence is not automatic.** The journal is in-memory unless `/var/log/journal`
exists (`Storage=` in `journald.conf` controls it). Cap it with a drop-in rather than
editing the vendor file: `/etc/systemd/journald.conf.d/size-limit.conf` with
`SystemMaxUse=200M`. Same drop-in pattern as `systemctl edit` and
`sshd_config.d/` — it survives package upgrades.

**Timers over cron**, three concrete reasons:

| | cron | systemd timer |
|---|---|---|
| Missed while machine was off | silently skipped | `Persistent=true` runs it at next boot |
| Schedule syntax | opaque 5 fields | `OnCalendar=`, checkable with `systemd-analyze calendar` |
| Fleet-wide load | all machines fire at once | `RandomizedDelaySec=` spreads them |

A timer activates the service **of the same name** automatically — `foo.timer` starts
`foo.service` with no wiring. `Unit=` in `[Timer]` is needed only to trigger a
*differently* named service.

**Sandboxing.** `ProtectSystem=strict` (whole filesystem read-only), `ProtectHome=`,
`PrivateTmp=` (own mount namespace with private `/tmp`, destroyed on stop, both
directions of isolation), `NoNewPrivileges=`. When a protection breaks a legitimate
write, **narrow the exception, don't remove the protection**:
`ReadWritePaths=/var/lib/myapp`. Score a unit with `systemd-analyze security <unit>`.

**The trap worth remembering: systemd silently ignores unknown directives.**
`ReadWritePath=` (singular — a one-letter typo) does not error. It is skipped with a
log warning, so `ProtectSystem=strict` kept blocking the write while the drop-in
*looked* correct. `systemd-analyze verify <unit>` catches exactly this. A hard crash
would have been friendlier.

## Filesystems, disk, LVM (day 7)

**Inodes and blocks are separate budgets.** Inode count is fixed at `mkfs` time, so a
filesystem full of tiny files exhausts inodes with plenty of space left and `creat()`
returns ENOSPC. `df -h` looks fine; `df -i` shows 100%. Second cause of the same
symptom: ext4 reserves 5% of blocks for root, so an unprivileged writer hits ENOSPC
while `df` still reports free space.

**`du` and `df` disagree** — three reasons, and the *direction* of the mismatch tells
you which:

- `df` higher: a deleted file still held open by a process. The directory entry is
  gone (so `du` can't walk to it) but blocks stay allocated until the last fd closes.
  `sudo lsof +L1`.
- `du` lower: it silently skipped directories it couldn't read.
- Neither: scope mismatch — `du` measured a subtree, `df` reports the whole filesystem.

**`/etc/fstab` uses `UUID=`** because `/dev/sdX`/`/dev/mmcblkX` names are not stable
across boots. Test changes with `sudo mount -a` **before** rebooting; a bad fstab on a
machine with no console is unrecoverable.

**LVM: file → loop device → PV → VG → LV.** Four layers, and the point of them is
that a plain partition is fixed to one boundary on one disk. LVM makes space a
resizable pool: grow live with `lvextend -r` (the `-r` resizes the filesystem too, not
just the volume), or span several physical disks in one volume group. A loop device is
a regular file the kernel presents as a block device — how ISOs mount and how
container/VM images are backed, and a safe playground for exactly this kind of practice.

**Break-it finding.** Mounting a raw PV that LVM already owns fails with `Device or
resource busy`, not "no filesystem". The kernel checks exclusive access *before*
looking for a superblock — device-mapper already holds it. Worth internalising that
error ordering: the first error you get is not always about the thing you were
thinking about.

## Packages, updates, firewall (day 8)

| Command | Effect |
|---|---|
| `apt update` | refreshes the index only; nothing installed changes |
| `apt upgrade` | upgrades installed packages; installs no new ones, removes none, skips anything needing a removal |
| `apt full-upgrade` | will remove packages and pull new dependencies to complete the upgrade |
| `apt dist-upgrade` | the old `apt-get`-era name for `full-upgrade` |

**Why an unsupervised `apt upgrade` takes down production.** Replacing a shared
library on disk does nothing for a process that already has the old version mapped in
memory — it keeps running the old code until restarted, and `apt` does not restart it.
`needrestart` is what surfaces those. Separately, a version bump can change config
defaults with nobody reading the changelog.

**`make install` is invisible to the package manager.** No `dpkg` record, no manifest,
no `apt remove` path — `dpkg -l` shows nothing. Removal depends on the source tree
offering `make uninstall`, or manual deletion file by file. On a server use
`checkinstall`, which wraps the same build into a real `.deb`.

**ufw order is not stylistic:**

```
allow OpenSSH  →  default deny incoming  →  default allow outgoing  →  enable
```

`enable` with default-deny and no SSH rule locks you out of a remote box with no
console. Then verify from a **second** session before closing the first — same golden
rule as day 4's sshd hardening.

**An official archive can be internally inconsistent.** `ports.ubuntu.com` (arm64)
served a `bzip2` whose published build declared an exact dependency on an older
`libbz2-1.0` than the archive itself was shipping, which broke `build-essential`
entirely. Not a stale local index, not a `hold` collision — purely archive-side and
unfixable from the client. The lesson is diagnostic discipline: rule out the local
causes explicitly, then accept that upstream can simply be wrong, and work around it
(installed `gcc` and `make` directly instead of the meta-package).

## Bash: strict mode, traps, signals (day 9)

Bash is a **process-composition tool**, not a general-purpose language. Pipes,
redirection, `$(...)`, job control — that is what it is unmatched at. Everything else
(data structures, arithmetic, error handling) is where it costs you, which is the
signal to move to Python.

**`set -euo pipefail`, and where each letter stops working:**

- `-e` does **not** fire inside `if`/`while`/`until` conditions, on the left of
  `&&`/`||`, or on a pipeline's non-final command. All three are deliberate: you are
  explicitly examining the status there.
- `-u` catches **unset**, not set-but-empty. `DIR=""` passes. Guard separately with
  `[[ -n "${DIR:-}" ]]`.
- `pipefail` makes a pipeline's status the rightmost non-zero one. Without it,
  `false | true` is a success and `-e` is blind to it.
- `local x=$(false)` reports `local`'s status (always 0), masking the failure. Declare
  and assign on separate lines.

**Quoting:** `"$var"` always (unquoted values get word-split on `$IFS` and
glob-expanded). `"$@"` passes each argument as its own word, `$*` joins them into one
— always `"$@"`. `[[ ]]` is a bash keyword parsed separately, immune to word-splitting
and with native `=~`; `[ ]` is an ordinary command subject to every normal expansion
trap. `$(...)` nests without escaping and lacks backticks' extra backslash layer.

**Traps — three findings that cost real debugging time:**

1. **A trap's last command sets the script's exit code.** A `cleanup` ending on a
   failed `[[ ]]` makes a fully successful script exit 1 — and since the error paths
   also exit 1, a caller cannot distinguish success from failure at all. End cleanup
   with `return 0`.
2. **A signal trap that doesn't `exit` resumes at the interrupted line.** Observed:
   cleanup deleted the temp file, the trap returned, and execution continued into the
   `mv` that needed it. The handler sabotaged the code it returned into. Correct shape:

   ```bash
   trap cleanup EXIT
   trap 'exit 130' INT     # 128 + 2
   trap 'exit 143' TERM    # 128 + 15
   ```

   The `exit` fires the EXIT trap, so cleanup still runs exactly once.
3. **`trap ... INT` can be a silent no-op.** A signal ignored when the shell starts
   cannot be trapped or reset, and `&` without job control sets SIGINT and SIGQUIT to
   `SIG_IGN` in the child (POSIX). Confirmed via `SigIgn`/`SigCgt` in
   `/proc/<pid>/status`. Which context launches the script decides whether its signal
   handling exists at all — verify in the real launch context (systemd, cron), not
   interactively.

**`shellcheck` is a lexical reviewer.** It passed clean, zero warnings, on a script
that reported failure on every successful run and ignored Ctrl-C. It has no model of
trap semantics or signal delivery. Passing it is a floor, not evidence of correctness.

**Idempotency** — `mkdir -p`, check-before-act; the bar is that two consecutive runs
both succeed and the second changes nothing.

## Bash: streams, text, log parsing (day 10)

**The fd table explains all of redirection.** Every process starts with `0`=stdin,
`1`=stdout, `2`=stderr — indices into a table of pointers to open files. Redirection
repoints entries, **left to right**, and `2>&1` copies fd 1's *value at that moment*
(`dup2`), not a lasting link to it:

```
cmd >file 2>&1   fd1→file, then fd2→copy of fd1        both in the file
cmd 2>&1 >file   fd2→copy of fd1 (terminal), then fd1→file   stderr on terminal
```

Same model explains why `sudo cmd > /etc/foo` fails: the **shell** opens the file, as
you, before `sudo` runs. Use `cmd | sudo tee /etc/foo`. And `>` truncates *before* the
command runs, so `sort file > file` destroys it.

`<<EOF` expands variables, `<<'EOF'` is literal, `<<-EOF` allows a tab-indented
terminator, `<<<"$var"` feeds one line. Process substitution `<(cmd)` supplies a
*filename* where a pipe won't do: `diff <(a) <(b)`. It also fixes the subshell trap —
`cmd | while read` runs the loop in a subshell so variables don't survive; use
`while read; do ...; done < <(cmd)`.

**Counting idioms.** `uniq -c` counts only **adjacent** duplicates, so `sort` first,
always — otherwise the result is silently wrong. Canonical tail:
`| sort | uniq -c | sort -rn | head -10`. `cut` splits on one character and doesn't
collapse repeats; `awk` splits on runs of whitespace, which is why aligned logs need
awk. Count-and-group: `awk '{c[$1]++} END {for (k in c) print c[k], k}'`.

**`-0` is a contract between two commands.** `find | xargs` splits on any whitespace
(tabs and newlines included — both legal in filenames) *and* interprets quotes, so
`it's.txt` breaks with `unmatched single quote` despite containing no spaces at all.
`find -print0 | xargs -0` fixes it, but only if set on **both** sides: `-0` alone
swallows the whole newline-delimited stream as one argument.

**Log parsing is landmark selection, not regex.** Never use fixed field numbers:
positions shift with message shape (`Failed password for root` vs `for invalid user
admin`) and with the timestamp format (classic syslog is 3 fields, RFC3339 is 1, so
every tutorial's `$9` is off by two here). Anchor on a landmark whose neighbours are
fixed-length — `for` is followed by a variable-length phrase, `from` is always
preceded by exactly one word:

```awk
{ for (i=1; i<=NF; i++) if ($i == "from") print $(i-1), $(i+1) }   # user, ip
```

**Decide which line *is* the event before counting.** One SSH attempt writes several
lines; counting IP occurrences across all of them turned 3 real attempts into 8.

**Hardening removes the signature you were grepping for.** With
`PasswordAuthentication no`, sshd rejects before any password attempt, so
`Failed password` is never emitted again. Every "top brute-force IPs" one-liner built
on that string returns empty on a correctly configured server — and reads as "nobody
is attacking me" rather than "I am grepping for something that can no longer happen".
On a key-only box, count `Invalid user` and `[preauth]`.

## The thread running through this week

Three separate times in five days, configuration was **correct, present, and
completely ignored, with no warning**:

| Day | What looked right | Why it did nothing |
|---|---|---|
| 6 | `ReadWritePath=/var/lib/myapp` in a drop-in | unknown directive — systemd skips it, no error |
| 9 | `trap 'exit 130' INT` in a script | SIGINT already `SIG_IGN` on shell entry — untrappable |
| 10 | `PasswordAuthentication no` in `sshd_config.d/hardening.conf` | `50-cloud-init.conf` sorted first, and OpenSSH takes the **first** value obtained |

None of these produced an error. Each was found only by inspecting **effective state**
rather than the file that was written:

```bash
sudo sshd -T                    # not: cat sshd_config
systemd-analyze verify <unit>   # not: cat the drop-in
systemctl show <unit>
sudo ufw status verbose
grep -E '^Sig(Ign|Cgt)' /proc/<pid>/status
```

This generalises past these three cases and is the single most transferable habit of
the week: **writing a config proves nothing; assert on what the system reports back.**
It is also the design requirement carried into the days 11–12 bootstrap artifact —
verification steps must query effective state, never re-read the file they just wrote.
