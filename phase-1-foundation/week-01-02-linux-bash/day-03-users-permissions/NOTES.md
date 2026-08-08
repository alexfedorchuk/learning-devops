# Day 3 — Users, permissions, sudo

Date: 2026-08-06
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Answered aloud before any new material — all three correct on the first pass:

1. Day 1: RSS vs VSZ (2 GB RSS / 40 GB VSZ) — process uses ~2 GB; RSS is what's
   actually resident, VSZ is mapped-but-not-necessarily-touched address space.
2. Day 1: reading a process's env vars — `sudo cat /proc/<pid>/environ | tr '\0' '\n'`.
3. Day 2: SSH session closes — SIGHUP to every process in it; `nohup` ignores it,
   `setsid` avoids it entirely (no controlling terminal), `systemd-run` removes the
   process from the login session altogether.

## What I did

1. Identity — the kernel only knows numbers:
   - `id`, `id alex`, `getent passwd alex root www-data nobody` — compared UIDs, saw
     names are just a lookup table over `/etc/passwd`
   - `getent group sudo` — found which group actually grants sudo
   - peeked at `/etc/shadow` (root-only) — password hashes live there, not in
     world-readable `passwd`

2. File vs directory `rwx` — the asymmetry that break-it depends on:
   - built `~/permlab/inner/file.txt`, toggled the directory's bits independently:
     no `x` → can't `cat` the file even knowing the exact path (can't enter);
     `x` without `r` → `cat` a known filename still works, but `ls` is denied
     (can't list, can still enter)
   - `chmod 444` on the file, then `rm` it anyway — deleting is governed by `w` on the
     **directory**, not by any permission on the file itself
   - practiced numeric↔symbolic `chmod` both directions and `chown` while setting
     these up (`stat -c '%a %A'` to check)

3. `namei -l` — walked a full path component by component, permissions of every
   segment printed at once. This is the tool that turns "denied somewhere" into
   "denied exactly here" — used it as the diagnostic in break-it below.

4. Special bits:
   - `ls -l /usr/bin/passwd` — found the `s` (setuid): it runs as root's UID no
     matter who invokes it, which is how an unprivileged user can edit
     root-owned `/etc/shadow`
   - `ls -ld /tmp` — found the sticky bit (`t`): anyone can create files, only the
     owner can delete their own

5. `umask` — checked the default, then created a file and a directory and watched
   666/777 minus the mask land on 644/755.

6. sudo as a policy engine:
   - `sudo -l`, read (never edited directly) `/etc/sudoers` — found the grant tied
     back to membership in the `sudo` group from step 1
   - compared `sudo -s` / `sudo -i` / `sudo su -` back to back — checked `$HOME`,
     `pwd`, `whoami` in each to see which environment survives (checkpoint 1)

7. Created a real system user:
   `sudo useradd --system --no-create-home --shell /usr/sbin/nologin labapp` —
   `sudo -u labapp whoami` works, `su - labapp` is refused because of `nologin`.
   This is the identity used to test break-it below as a genuinely different user.

## What broke

Goal: make a file `chmod 777` that `labapp` still can't read — proving it was never
about the file.

```
mkdir -p ~/permlab/secret_dir
echo "Top secret data" > ~/permlab/secret_dir/target_file
chmod 777 ~/permlab/secret_dir/target_file    # file itself is wide open
chmod o-x ~/permlab/secret_dir                # but "other" can't enter the directory

sudo -u labapp cat ~/permlab/secret_dir/target_file   # Permission denied
namei -l ~/permlab/secret_dir/target_file             # shows exactly where: 'd---rwx'
                                                       # on secret_dir for "other"

chmod o+x ~/permlab/secret_dir                # fix
sudo -u labapp cat ~/permlab/secret_dir/target_file   # now works
```

Expected the file's own `777` to be the whole story; the real gate was the
**directory's** execute bit for "other" — without `x` on `secret_dir`, `labapp` can
never resolve the path to `target_file`, regardless of what the file itself allows.
`namei -l` made the exact broken link in the path obvious instead of guessing.

## What surprised me

- A `777` file can still be completely unreachable — permission to read a file and
  permission to *get to* a file are two separate checks, and the second one (`x` on
  every directory in the path) is checked first.
- `rm` on a `444` (read-only) file succeeded. Deleting isn't "permission to modify
  the file" at all — it's permission to modify the **directory entry**, controlled
  by `w` on the directory.
- `x` without `r` on a directory lets you open a file if you already know its exact
  name, but `ls` on that same directory is refused. Knowing a path can get you further
  than browsing it.

`rwx` on a file vs a directory:

| Right | On a file | On a directory |
|---|---|---|
| `r` | read the file's contents | list the names inside |
| `w` | modify/truncate contents | create, delete, rename entries — independent of the target file's own permissions |
| `x` | execute as a program | enter the directory — required to resolve any path through it |

`chmod` numeric ↔ symbolic:

| Octal | Symbolic | Meaning |
|---|---|---|
| 7 | `rwx` | read + write + execute |
| 6 | `rw-` | read + write |
| 5 | `r-x` | read + execute |
| 4 | `r--` | read only |
| 0 | `---` | nothing |

Common combos: `755` = `rwxr-xr-x` (owner full, everyone else read+execute — typical
for directories/executables); `644` = `rw-r--r--` (owner read/write, everyone else
read-only — typical for regular files); `750` = `rwxr-x---` (owner full, group
read+execute, others nothing).

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. `sudo su -` vs `sudo -i` vs `sudo -s` — what's the difference in the resulting
   environment?

   `sudo su -` and `sudo -i` both simulate a full root login: `$HOME` becomes `/root`,
   cwd becomes `/root`, environment variables reset to root's own profile. `sudo -s`
   runs a shell as root but resets nothing — it keeps my `$HOME`, my cwd, my
   environment. Looks the same at a glance ("I'm root now") but the state underneath
   is very different — a script that trusts `$HOME` after `sudo -s` is reading the
   invoking user's home, not root's.

2. Why does a service need its own user when `nobody` already exists?

   `nobody` is one shared, generic UID. If two different services both ran as
   `nobody`, they'd be indistinguishable to the kernel — same UID means same
   permissions, so a compromise of one gives an attacker access to the other's files
   and the ability to signal its processes. A dedicated UID per service isolates
   services from *each other*, not just from real users.

3. Why does setuid on a shell script not work in Linux?

   For a compiled binary, `execve()` checks the setuid bit and elevates the process's
   UID atomically as part of loading and running it — one step, no gap. A script is
   different: the kernel reads the `#!` line and re-execs the interpreter (e.g.
   `bash`), which then opens the *same path again itself* to read and run it — two
   separate opens. If setuid were honored here, an attacker with write access to that
   path could swap the file between the kernel's check and the interpreter's read
   (a TOCTOU / symlink race), making the interpreter run attacker-controlled content
   with elevated privileges. Linux avoids the whole vulnerability class by simply
   ignoring the setuid bit on any file starting with `#!`.

4. A private SSH key with 644 permissions — why does SSH refuse to use it?

   A private key must be known only to its owner — that's the entire premise of
   asymmetric auth. `644` grants read to group and other, so anyone else on the
   machine could copy it and authenticate as me. SSH refuses to even attempt using
   such a key: a safe-by-default check that fails loudly (`Permission denied`) rather
   than silently trusting a key that may already be compromised. Fix: `chmod 600`
   (owner read/write only).

## Open questions
