# Day 10 — Bash: text, streams, testing

Date: 2026-08-24
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Three questions from previous days, answered aloud before any new material — one
correct, one partial, one wrong:

1. Day 6: what does `PrivateTmp=true` change for a service, and what does it protect
   against? **Partial.** Got the effect (the service can't reach other services' temp
   files) but not the mechanism or the other half. systemd puts the unit in its own
   **mount namespace** with a fresh private tmpfs over `/tmp` and `/var/tmp`. So the
   isolation is bidirectional — other processes also can't see or tamper with *this*
   service's temp files — and the whole thing is torn down when the unit stops, so
   nothing leaks between runs. That kills the classic `/tmp` symlink/predictable-name
   attack, where a local attacker pre-creates a file the service is about to write.
2. Day 7: `df -h` shows 40% free but a write fails with `No space left on device` —
   what do you check? **Wrong.** Answered "deleted-but-open file descriptors,
   `lsof +L1`". That's a real phenomenon but it explains the *opposite* discrepancy:
   deleted-but-open files make `df` report space as **used** that `du` can't find —
   they can't leave `df` showing free space. Direction of the mismatch is the tell.
   The answer is **inode exhaustion**: `df -i`. Inode count is fixed at `mkfs` time
   and is a separate budget from data blocks, so a filesystem full of tiny files runs
   out of inodes with blocks to spare and `creat()` returns ENOSPC. This was day 7's
   own break-it exercise (filled `/mnt/labvol` with empty files until it failed),
   which makes it a retention miss rather than a knowledge gap. Second legitimate
   cause worth having ready: ext4 reserves 5% of blocks for root by default, so an
   unprivileged writer gets ENOSPC while `df` still shows ~5% free.
3. Day 8: order of operations when enabling `ufw` over SSH. **Correct** —
   `allow OpenSSH` first, then the defaults, `enable` last. The reasoning is the part
   to say out loud: `enable` with a default-deny policy and no SSH rule cuts your own
   session and locks you out of a remote box with no console. Same golden rule as
   day 4's sshd hardening — and day 8's own notes add the verification step: confirm
   from a **second** SSH session before closing the first.

## What I did

1. File-descriptor experiment, both orders:
   `ls /nonexist >out.txt 2>&1` puts the error in the file; `ls /nonexist 2>&1 >out.txt`
   leaves it on the terminal and the file empty. `2>&1` copies fd 1's value *at that
   moment*, so the second form aims fd 2 at the terminal before fd 1 is moved.
2. Tried the real task against `/var/log/auth.log` — no output. Rather than assume the
   pipeline was wrong, built a mock `auth_mock.log` covering all three sshd line
   shapes (plain user, `invalid user`, accepted) and developed against it. Right call:
   the pipeline was fine, the log genuinely had nothing (see What broke).
3. Top-10 attacking IPs two ways: `grep -oE` on a dotted-quad pattern, and `awk`
   looping over fields testing each against an IP regex, both into
   `sort | uniq -c | sort -rn | head -10`.
4. Counted distinct usernames tried, and extracted them by scanning for the literal
   `for` and taking the next field.
5. `xargs` break-it: `touch "my secret file.txt"`, then `find | xargs ls -l`.
6. Fixed the sshd drop-in ordering (renamed to `00-hardening.conf`) and confirmed the
   effective config rather than the file: `sshd -T` now reports
   `passwordauthentication no`, `permitrootlogin no`, `allowusers alex`.
7. Generated **real** failure data instead of continuing with the mock — `ssh` to the
   Pi from itself as `test` and `test2`. Better than mock in a way that mattered: it
   exposed three things the hand-written mock had wrong (see What broke).

## What broke

1. **`/var/log/auth.log` had zero attack lines — the Pi is not actually reachable from
   the internet.** The curriculum assumes a publicly exposed box ("справжні атаки"),
   which is why the task is framed around brute-force traffic. Checked directly:

   ```
   1213 lines in /var/log/auth.log
   Failed password:      0
   Invalid user:         0
   authenticating user:  0
   preauth:              0
   ```

   Every `sshd` line is `Accepted publickey for alex from 192.168.0.193` — the
   workstation on the LAN. A box with port 22 open to the internet collects scan
   traffic within minutes, so 1213 lines across two days with none of it is
   conclusive. A `lab-ext` entry exists in `~/.ssh/config` so exposure was
   intended, but no port forward is in place.

   Not a mistake in the work — the mock was the correct response to an empty dataset.

2. **Day 4's SSH hardening is silently not in effect: password authentication is on.**
   Found while investigating the empty log. The config *files* say what was intended,
   but the running config disagrees:

   ```
   $ sudo sshd -T | grep -i passwordauth
   passwordauthentication yes          <- effective
   $ cat /etc/ssh/sshd_config.d/hardening.conf
   PasswordAuthentication no           <- intended, ignored
   ```

   Cause: `/etc/ssh/sshd_config` line 12 is `Include /etc/ssh/sshd_config.d/*.conf`,
   and that directory holds two files:

   ```
   50-cloud-init.conf   PasswordAuthentication yes   (root-only, 27 bytes, from the image)
   hardening.conf       PasswordAuthentication no    (written day 4)
   ```

   The glob expands in **lexical order**, so `50-cloud-init.conf` is parsed first — and
   OpenSSH takes the **first** value obtained for a keyword, not the last. Cloud-init
   wins. `PermitRootLogin no` and `AllowUsers alex` *do* take effect only because
   cloud-init doesn't set them, so the hardening looked like it worked.

   Fix is to make the filename sort earlier, e.g. rename to `00-hardening.conf`, or
   delete the cloud-init drop-in. Must be settled before the box is ever exposed:
   password auth open on port 22 is exactly what the day-10 task was supposed to be
   watching other people attack. Verify with `sshd -T`, never by reading the file.

3. **Username extraction was wrong on `invalid user` lines — field positions shift.**
   The IP-extraction pipeline was fine, but both username attempts assumed a fixed
   shape. sshd emits at least two:

   ```
   Failed password for root from 203.0.113.45 ...             -> $9  = root
   Failed password for invalid user admin from 198.51.100.23  -> $9  = invalid
   ```

   So `awk '{print $9}' | sort -u | wc -l` reported 4 distinct users
   (`invalid, root, test, user`) where the data holds 5 (`root, admin, test, support,
   user`) — `invalid` counted as a username, and `admin`/`support` never counted at
   all. Anchoring on the literal `for` and taking the next field has the same defect
   for the same reason.

   Fix — anchor on `from` and take the field **before** it. The username is the last
   token before `from` in every variant:

   ```awk
   { for (i=1; i<=NF; i++) if ($i == "from") print $(i-1) }
   ```

   Verified against all three line shapes: returns `root, admin, test, support, user`.
   The lesson is landmark choice — `for` is followed by a variable-length phrase,
   `from` is preceded by a fixed one.

4. **`xargs -0` was applied to only half the contract.** The break itself worked as
   intended:

   ```
   $ find . -name "*secret*" | xargs ls -l
   ls: cannot access './my': No such file or directory
   ls: cannot access 'secret': No such file or directory
   ls: cannot access 'file.txt': No such file or directory
   ```

   But the attempted fix was `find . -name "*secret*" | xargs -0 ls -l` — `-0` on
   `xargs` without `-print0` on `find`. That fails differently rather than working:

   ```
   ls: cannot access './my secret file.txt'$'\n': No such file or directory
   ```

   With no NUL anywhere in the stream, `xargs -0` treats the entire input as one
   argument, trailing newline included — which is now part of the filename. `od -c`
   shows the whole story: plain `find` ends the record with `\n`, `find -print0` ends
   it with `\0`. `-0` is a contract between two commands and both sides have to agree
   on the delimiter; setting it on one side alone converts one bug into another.

5. **Hardening the box deleted the signature the whole task greps for.** With
   `PasswordAuthentication no` in effect, sshd rejects the connection before any
   password is attempted, so `Failed password` is never emitted again. Same user, same
   client, before and after the fix:

   ```
   before (pid 20204, 4 lines, one connection):
     Invalid user test from 192.168.0.197 port 41516
     Failed password for invalid user test from 192.168.0.197 port 41516 ssh2
     Failed password for invalid user test from 192.168.0.197 port 41516 ssh2
     Connection closed by invalid user test 192.168.0.197 port 41516 [preauth]

   after  (pid 20318, 2 lines, one connection):
     Invalid user test from 192.168.0.197 port 42742
     Connection closed by invalid user test 192.168.0.197 port 42742 [preauth]
   ```

   So every "top SSH brute-force IPs" one-liner built on `grep "Failed password"`
   returns empty on a correctly hardened server — and reads as "nobody is attacking
   me" rather than "I am grepping for something that can no longer occur". On a
   key-only box the events to count are `Invalid user` and `... [preauth]`.

6. **Field positions from the mock don't apply to the real log — everything shifts by
   two.** The mock used the classic syslog timestamp (`Jan 10 05:01:22` — three
   fields); the Pi's rsyslog writes RFC3339 (`2026-08-25T12:07:20.884141+03:00` — one
   field). Real log:

   ```
   $1=2026-08-25T12:07:20.884141+03:00   $4=Invalid  $5=user  $6=test2
   $7=from   $8=192.168.0.197   $9=port   $10=38502
   ```

   Username is `$6` and IP is `$8` here, against `$9` and `$11` in the mock. Any
   tutorial one-liner using fixed `$9`/`$11` was written for the old format and is
   silently wrong on this system — which is the same lesson as defect 3, arriving
   from a second direction.

7. **One connection attempt writes several lines, so counting raw IP occurrences
   inflates the total.** Across all auth-failure lines the single test client counts
   as 8; counting only the canonical `Invalid user` line gives 3, the true number of
   attempts:

   ```
   naive (all auth lines):        8 192.168.0.197
   canonical (Invalid user only): 3 192.168.0.197
   ```

   Picking which line *is* the event has to come before any counting.

   The robust extraction — anchored on `from`, taking both neighbours, independent of
   timestamp format and of the `invalid user` phrase:

   ```awk
   /Invalid user/ { for (i=1; i<=NF; i++) if ($i == "from") print $(i-1), $(i+1) }
   ```

   Gives `test 192.168.0.197` ×2 and `test2 192.168.0.197` ×1. Verified against both
   timestamp formats in one pass. Note it finds nothing in `Connection closed by
   invalid user test 192.168.0.197 ...` — that line has no `from` at all, the IP
   follows the username directly. Harmless here since those lines shouldn't be counted
   anyway, but worth knowing the anchor drops them silently.

## What surprised me

- That a config file can be correct, present, and completely ignored — and that the
  system gives no hint. `hardening.conf` reads exactly as intended; only `sshd -T`
  reveals that cloud-init's drop-in beat it on lexical order. "First value wins" is
  the opposite of the last-wins intuition most config formats train, and the drop-in
  that overrides you is root-only readable, so it isn't even visible while poking
  around as a normal user.
- How much of log parsing is choosing a stable landmark rather than writing the regex.
  Both username attempts had correct syntax and ran without error — they just counted
  the wrong words, silently, and would have been believed if the dataset were real
  instead of a mock small enough to check by eye.
- That the absence of data was itself the finding. An empty result read as "my
  pipeline is broken", but the pipeline was right and the *premise* was wrong.
- That fixing the security hole broke the monitoring built to watch it. Disabling
  password auth is unambiguously correct, and it silently retired the log line the
  whole exercise depends on. Nothing warns you — the query keeps running and keeps
  returning zero. Any alerting built on a log string is coupled to a configuration
  that can legitimately change underneath it, which is a real argument for asserting
  on effective state rather than on log text wherever both are options.
- How much better real data was than a careful mock. The mock was reasonable, covered
  three line shapes, and was still wrong about the timestamp format, the field
  offsets, and how many lines one attempt produces. Three failures a mock cannot
  reveal by construction, because it encodes the same assumptions as the code it is
  meant to test.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. `2>&1 >file` vs `>file 2>&1` — explain the difference through the file-descriptor
   table model.

   Redirections are applied left to right, and `2>&1` **copies fd 1's current value**
   — it is not a lasting link to fd 1, which is the whole trap.

   - `2>&1 >file`: fd 2 takes a copy of fd 1, which at that moment is still the
     terminal, so fd 2 now points at the terminal. Then fd 1 is moved to the file.
     fd 2 does not follow it. Result: **stdout in the file, stderr on the terminal**.
   - `>file 2>&1`: fd 1 is moved to the file first, then fd 2 copies fd 1's new value.
     Result: **both in the file**, which is what people usually mean. `&>file` is the
     shorthand for this one.

   Same reasoning explains why `sudo cmd > /etc/foo` fails: the shell performs the
   redirection, as the invoking user, before `sudo` ever runs. `cmd | sudo tee /etc/foo`
   is the fix.

2. When does `xargs` without `-0` break?

   Three distinct classes, not just one:

   - **Any whitespace as a separator** — not only spaces. Tabs split too, and so do
     newlines, which are legal characters in Linux filenames.
   - **Quotes and backslashes, which `xargs` actively interprets.** This is the
     non-obvious one: a file named `it's.txt` contains no whitespace at all and still
     kills the command with `xargs: unmatched single quote`. Same for a double quote.
   - Consequently any filename that didn't originate from you — user input, an
     extracted archive, another system — makes `find | xargs` unsafe by default.

   `find . -print0 | xargs -0` handled all four test files, including one with a tab
   and one with an embedded quote. `-0` must be set on **both** sides: `-print0` alone
   still lets `xargs` split on whitespace, and `-0` alone makes `xargs` swallow the
   whole newline-delimited stream as a single argument.

## Open questions

- ~~Rename `hardening.conf` to sort ahead of `50-cloud-init.conf`.~~ **Done** —
  `00-hardening.conf`, verified via `sshd -T`: `passwordauthentication no`.
- Is there anything else cloud-init set that silently overrides work done by hand?
  `/etc/ssh/sshd_config.d/` was the only drop-in directory checked. Worth a sweep
  before days 11–12, since `artifact-server-bootstrap` will write config the same way
  and would inherit the same trap.
- How should the bootstrap artifact *verify* config it writes? Reading back the file
  it just wrote proves nothing, as this day shows — it needs to assert on effective
  config (`sshd -T`, `ufw status`) instead. Belongs with days 11–12.
- No public exposure means no attack data for the write-up. Set up the port forward,
  or accept mock data and say so explicitly in the write-up rather than implying the
  numbers are real.
