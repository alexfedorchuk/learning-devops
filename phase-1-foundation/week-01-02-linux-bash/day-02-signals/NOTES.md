# Day 2 — Signals, file descriptors, limits

Date: 2026-08-05
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## What I did

1. Signals basics — the polite kill vs the terminal interrupt:
   - `kill -l` — the full signal table
   - `sleep 300 &` → `kill -TERM %1` (job ids via `jobs`) — dies politely
   - `Ctrl-C` — SIGINT, same idea but sent by the terminal
2. Caught signals with `trap` in a test script:
   - INT handler → the script survives `Ctrl-C`
   - TERM handler → cleanup runs before exit
   - a trap on KILL never fired — SIGKILL is handled by the kernel, the process never
     sees it
3. Watched a graceful shutdown:
   - `systemctl stop cron` → `journalctl -u cron -n 5` — clean exit on SIGTERM
   - started it back afterwards
4. Explored my shell's fd table:
   - `ls -l /proc/$$/fd` — 0/1/2 point at the terminal (`/dev/pts/0`), plus bash's own
     fd 255 (its private copy of the tty)
   - `exec 3</etc/hostname` / `exec 3<&-` — opened and closed an extra descriptor
5. Sockets are fds too:
   - `sudo ss -tulpn` — every listening socket with its owning PID, matched each one
     back to the day-1 services table
6. The deleted-file trick — the anatomy of checkpoint question 1, felt by hand:
   - `dd if=/dev/zero of=~/big.log bs=1M count=300` — a 300 MB file
   - `tail -f ~/big.log &` — a process holds it open
   - `rm ~/big.log` → `df -h /` — no space freed
   - `sudo lsof +L1` — the file listed as `deleted` but still open, holder found
   - `kill %1` → `df -h /` — only now the 300 MB came back
7. Open file limits — soft vs hard:
   - `ulimit -a` — all limits at a glance
   - `ulimit -n` — the soft limit: enforced right now; the process itself may raise it,
     but only up to the hard limit
   - `ulimit -Hn` — the hard limit: the ceiling; only root can raise it
   - `cat /proc/$$/limits` — the same data for my shell, day-1 style


## What broke

- Exhausted the fd limit on purpose. In a fresh shell lowered the ceiling with
  `ulimit -n 50`, then opened descriptors in a loop —
  `for i in $(seq 1 100); do exec {fd}</etc/hostname; done` — and hit
  `Too many open files` at ~50. Diagnosed it like production:
  - `ls /proc/$$/fd | wc -l` — how many descriptors are open
  - `lsof -p $$ | tail` — what they actually are
- The naive-fix trap: put `ulimit -n 65535` into `.bashrc` — and it fixes nothing that
  matters. `.bashrc` runs only for interactive shells; a service started by systemd
  never passes through my shell, so it inherits limits from systemd itself. The real
  fix for a service is `LimitNOFILE=` on the unit
  (`systemd-run -p LimitNOFILE=100000 -t bash -c 'ulimit -n'` to see it applied).

## What surprised me

- `/proc` is a virtual filesystem: nothing there exists on disk — the kernel
  synthesizes every file on the fly when you read it.
- bash quietly keeps fd 255 open as its own spare handle on the terminal.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. You deleted a 20 GB log file, but `df` still shows the same 0 bytes free. Why, and
   how do you fix it?

   `rm` removes only the directory entry; the data lives until the last open fd on the
   file closes, and some process still holds one. Find it with `sudo lsof +L1` (deleted
   but open files), then either restart/kill the holder — or, gentler on prod, truncate
   the file through its descriptor: `: > /proc/<pid>/fd/<N>`. The systemic fix is log
   rotation so a single log can never grow to 20 GB.

2. What happens to a process when you close the SSH session it was started from? Why do
   `nohup`, `setsid` and `systemd-run` each solve this differently?

   The terminal goes away and every process in the session gets SIGHUP; the default
   action is death. `nohup` keeps the process in the session but makes it ignore
   SIGHUP (and redirects output away from the dead tty into `nohup.out`). `setsid`
   starts it in a new session with no controlling terminal, so no SIGHUP is ever
   generated for it. `systemd-run` hands it to systemd as a transient unit — it leaves
   my login session entirely and gains real lifecycle management (journal, restarts,
   resource limits).

3. Why can `SIGKILL` not be caught?

   SIGKILL is never delivered to the process — the kernel acts on it directly, so no
   handler could run, and `sigaction()` refuses to register one. By design: if a
   process could catch or ignore KILL, a hung or malicious process could make itself
   unkillable. Uncatchable KILL/STOP is the kernel's guarantee that the admin always
   has a last resort.

## Open questions
