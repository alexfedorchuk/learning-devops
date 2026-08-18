# Day 8 — Packages, updates, firewall

Date:
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Three questions from previous days, answered aloud before any new material — all
three correct (one required a hint):

1. Day 3: why does SSH refuse a private key with `644` permissions? Group/other can
   read it, defeating asymmetric auth entirely; fix is `600`.
2. Day 5: `After=network.target` doesn't guarantee the network is actually up — what
   to use instead? `Wants=network-online.target` + `After=network-online.target`,
   deliberately `Wants=` and not `Requires=` — a slow/absent network shouldn't hard-
   block startup.
3. Day 6: a service crashed overnight, the machine rebooted — command to see its
   last logs? `journalctl -b -1 -u <service>`.

## What I did

1. `apt-cache policy <pkg>` and `apt-mark hold` — held `htop` to see the effect,
   confirmed with `apt-mark showhold`.
2. `needrestart` — flagged four services still running against outdated libraries
   (`dbus.service`, `systemd-logind.service`, `unattended-upgrades.service`,
   `wpa_supplicant.service`), all non-critical; restarted them, confirmed clean.
3. Built GNU Hello from source (`./configure && make && sudo make install`) — ran
   into a real dependency conflict along the way (see What broke). Once past it:
   verified with `which hello` / `hello`, then tested removal with `make uninstall`
   from the same source directory.
4. `ufw`: `allow OpenSSH` first, then `default deny incoming`, `enable` — verified
   access from a **second** SSH session before closing the first, same golden rule
   as day 4's sshd hardening.

## What broke

`make` wasn't installed yet; `sudo apt install build-essential` failed outright:

```
The following packages have unmet dependencies:
 dpkg-dev : Depends: bzip2 but it is not installable
E: Unable to correct problems, you have held broken packages.
```

Traced further — `apt install bzip2` directly gave the real error:

```
bzip2 : Depends: libbz2-1.0 (= 1.0.8-5.1) but 1.0.8-5.1build0.1 is to be installed
```

Ruled out the two obvious causes: not a stale local index (`apt update` reported
everything already up to date), not an `apt-mark hold` collision (`apt-mark
showhold` only listed `htop`, unrelated to bzip2). The real cause: the Ubuntu
**ports (arm64) archive itself** was internally inconsistent at that moment —
`bzip2`'s published build still declared an exact dependency on an older
`libbz2-1.0` build than the one the archive was actually serving, something purely
on the archive side and outside local control. Worked around it by installing only
what was actually needed, `gcc` and `make`, instead of the full `build-essential`
meta-package.

## What surprised me

- That an official architecture's package archive (`ports.ubuntu.com`, arm64) can
  itself be internally inconsistent — a published package and its own declared
  dependency temporarily out of sync with each other, not something fixable from
  the client side at all, only worked around.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. Difference between `apt update` / `apt upgrade` / `apt full-upgrade` / `apt
   dist-upgrade`.

   `update` only refreshes the package index (what's available), touches nothing
   installed — effectively always the first command run. `upgrade` updates
   already-installed packages to newer versions: installs no new packages, removes
   none, and skips any package whose upgrade would require a removal. `full-upgrade`
   is more aggressive: it will remove packages and pull in new dependencies if
   that's what completing the upgrade requires. `dist-upgrade` is the older
   `apt-get`-era name for the same behavior `full-upgrade` provides under the
   modern `apt` CLI.

2. Why can an unsupervised `apt upgrade` take down production?

   A process already running has the *old* version of a shared library loaded in
   memory — swapping the file on disk changes nothing for that process until it's
   restarted, which `apt upgrade` doesn't do on its own (that's exactly what
   `needrestart` surfaces). Beyond that, a version bump can silently change config
   defaults or behavior with nobody reviewing the changelog first — unsupervised
   means nobody catches either problem before it's live.

3. Where does a package installed via `make install` go when you want to remove it?

   Nowhere, in terms of tracking — `dpkg`/`apt` have zero record of it (confirmed:
   `dpkg -l | grep hello` returned nothing), so there's no manifest and no `apt
   remove` path. The only way out is whatever the source tree happens to provide
   (`make uninstall`, if the `Makefile` has that target) or manual deletion file by
   file. This is exactly why `checkinstall` is the better call on a server — it
   wraps the same build into a real `.deb`, so `dpkg -r` can clean it up properly
   later.

## Open questions
