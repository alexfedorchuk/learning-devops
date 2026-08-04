# Day 1 — Processes and /proc

Date: 2026-08-04
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Baseline of a clean system

What was already running before I touched anything, and why:

`systemctl list-units --type=service --state=running`

| Service | What it does | Do I need it? |
|---|---|---|
| avahi-daemon.service | Advertises this machine on the LAN via mDNS (`hostname.local` names) and discovers others | don't know yet |
| cron.service | Runs scheduled jobs at configured times | yes - core |
| dbus.service | Message bus that system services use to talk to each other | yes - core |
| fwupd.service | Checks for and installs firmware updates | probably not |
| getty@tty1.service | Login prompt on the physical console (HDMI + keyboard) | yes - emergency console |
| ModemManager.service | Manages cellular/USB modems | don't know yet |
| netplan-wpa-wlan0.service | wpa_supplicant instance netplan started for `wlan0` — Wi-Fi auth for that interface | probably not |
| polkit.service | Decides whether an unprivileged process may do a privileged action | yes - core |
| rsyslog.service | Classic text-file logging — writes `/var/log/*.log` | yes - core |
| serial-getty@ttyS0.service | Login prompt on the serial port | don't know yet |
| snapd.service | Manages snap packages | don't know yet |
| ssh.service | SSH server — my way into the machine | yes - core |
| systemd-journald.service | Collects all logs into the binary journal | yes - core |
| systemd-logind.service | Tracks user logins and sessions | yes - core |
| systemd-networkd.service | Configures network interfaces — brings up `eth0`/`wlan0` per netplan config | yes - core |
| systemd-resolved.service | System DNS resolver | yes - core |
| systemd-timesyncd.service | Keeps the clock synced via NTP | yes - core |
| systemd-udevd.service | Reacts to device plug/unplug events, populates `/dev`, applies rules | yes - core |
| udisks2.service | Disk mounting/management service for desktop-style tools | yes - core |
| unattended-upgrades.service | Installs security updates automatically (unit ensures clean shutdown mid-upgrade) | yes - core |
| user@1000.service | Per-user systemd instance managing session services for UID 1000 (me) | yes - core |
| wpa_supplicant.service | Wi-Fi WPA authentication daemon — keeps the wireless connection up | probably not |


Boot time (`systemd-analyze`):
```
Startup finished in 9.247s (kernel) + 31.319s (userspace) = 40.567s 
graphical.target reached after 27.257s in userspace.
```

Memory at rest (`free -h`):

| | total | used | free | shared | buff/cache | available |
|---|---|---|---|---|---|---|
| Mem | 899Mi | 263Mi | 182Mi | 3.1Mi | 536Mi | 635Mi |
| Swap | 0B | 0B | 0B | | | |

## What I did

- Snapshotted the baseline: 22 running services (table above), boot in 40.6s, 899Mi RAM,
  no swap configured.
- Compared `ps aux` vs `ps -ef` — two different syntax families (BSD vs UNIX), not two
  variants of one command. Went through every `ps aux` column, incl. VSZ vs RSS and the
  extra `STAT` letters.
- Traced my shell's ancestry in `pstree -p`: systemd(1) → sshd (listener) → sshd (my
  session) → bash.
- Inspected a process I didn't start (cron, PID 740) through `/proc/<pid>/`: cmdline,
  environ (needed sudo), status (VmSize vs VmRSS), fd, maps, limits.
- Produced process states by hand and watched them live in htop: R (`yes > /dev/null`),
  S (`sleep 300`), T (`kill -STOP`), Z (`bash -c 'sleep 2 & exec sleep 300'`). Tried
  `kill -9` on the zombie — nothing happened; killing its parent made it disappear.
- Load average experiment: 4× `yes` on 4 cores — 1-min load climbed to ~4.0;
  added a 5th, then killed all and watched the 1/5/15 numbers decay at different speeds.
- Break-it: a bash forked three `sleep 600` children and exited; hunted down the orphans
  and their new parent (details in What broke).

## What broke

- Orphan experiment: a bash forked three `sleep 600` and exited immediately. The
  orphans' PPID became **1** — adopted directly by systemd. I'd been warned the
  textbook "init adopts orphans" isn't always literally true on modern systems (a
  subreaper like `systemd --user` can step in), but on this headless Ubuntu Server it
  was plain PID 1.
- Thought I killed a zombie — I didn't. `kill -9 %1` "worked", but `%1` was the live
  parent (the bash that exec'd into `sleep 300`), not the zombie. The zombie (`sleep 2`)
  ignores signals entirely — it's already dead. It vanished because killing its parent
  made systemd adopt it and immediately reap it via `wait()`. Expected "kill -9 kills
  anything"; learned "you can't kill what's already dead — remove the negligent parent
  instead".

## What surprised me

- Memory "pages". I used terms like COW and RSS all day before realizing I didn't
  actually know the unit they operate on: the kernel manages memory in fixed ~4 KB
  chunks, and everything from today — COW on fork, RSS vs VSZ, shared libraries being
  counted in every process — is just per-page bookkeeping in each process's page table.
  VSZ being "promises, not RAM" only clicked after that.
- `/proc/<pid>/environ` is not a text file: entries are separated by C-style NUL bytes
  (`\0`) — it's the raw memory of the process's environment block, not something
  formatted for humans. Hence the `tr '\0' '\n'` trick to read it.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. What exactly does `fork()` do, and why is copy-on-write a necessity rather than an
   optimisation?

   `fork()` clones the calling process: new PID, copied page tables and fd table, but
   zero bytes of memory copied — pages are shared read-only and duplicated only when
   either side writes. It returns twice: 0 in the child, the child's PID in the parent.
   COW is a necessity because fork is almost always followed immediately by `exec()`,
   which throws the child's memory away. Without COW every shell command would mean
   physically copying the parent's entire address space just to discard it — the
   fork/exec model only works because fork copies nothing upfront.

2. Load average 8.0 on a 4-core machine — is the system overloaded?

   Not necessarily. Linux load average counts processes in R (runnable) **plus** D
   (uninterruptible sleep, usually I/O). 8.0 on 4 cores means the CPU is 2×
   oversubscribed only if they are all R; if most are in D the CPU may be nearly idle
   and the box is bottlenecked on I/O. The number alone doesn't diagnose anything —
   check process states (`htop`, `ps`) and iowait (`top`, the `wa` field).

3. A process shows 2 GB RSS and 40 GB VSZ. How much memory does it actually use?

   ~2 GB. RSS is what actually sits in physical RAM; VSZ is mapped address space —
   allocations never touched, mmap'd files, the full size of every shared library — and
   costs nothing. Caveat: RSS also counts pages shared with other processes (libc
   etc.), so even RSS slightly overstates the process's private footprint.

4. How do you find the environment variables of a process you did not start?

   `sudo cat /proc/<pid>/environ | tr '\0' '\n'`. Root (or the process owner) is
   required because environments often contain secrets, so the file is not
   world-readable. The `tr` is needed because entries are NUL-separated, not
   newline-separated.

5. Why can a process in `D` state not be killed with `kill -9`?

   A `D` process is executing *inside* the kernel — typically mid-I/O in a driver code
   path that can't be abandoned without leaving kernel state inconsistent. Signals
   (including SIGKILL) are only acted on at safe points, so the kill just stays pending
   until the operation completes; if it never completes (dead disk, hung NFS), the
   process is stuck in `D` forever. Not to confuse with `Z`: a zombie is already dead
   and ignores signals entirely — the cure there is reaping via the parent, not `kill`.

## Open questions

- Both `eth0` and `wlan0` are up with different metrics (100 vs 600) — how does routing
  actually pick the interface for outbound traffic? (weeks 3–4, networking)
- How does virtual→physical address translation really work — page tables in hardware,
  TLB, what happens on a page fault, how swap fits in? (beyond day 1's scope)
