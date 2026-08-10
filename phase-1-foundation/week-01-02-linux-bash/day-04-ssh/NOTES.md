# Day 4 — SSH for real

Date:
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Answered aloud before any new material:

1. Day 1: who adopts orphaned processes, and why isn't it always PID 1 on modern
   systems? Got the base case (init/systemd), missed the nuance: a subreaper
   (`PR_SET_CHILD_SUBREAPER`, e.g. `systemd --user` or a container supervisor) can
   intercept adoption instead. On this headless Pi it was plain PID 1.
2. Day 2: why can't SIGKILL be caught? Refined: if a process could catch or ignore
   KILL, a hung or malicious process could make itself unkillable — the kernel
   guarantees the admin a last resort by never giving the process a chance to react.
3. Day 3: `chmod 777` on a file, user still can't read it — where's the problem?
   Right direction (a directory, not the file), sharpened: specifically the missing
   `x` (execute/enter) bit on some directory in the path, blocking path resolution
   regardless of the file's own permissions.

## What I did

1. Checked existing SSH state on the Mac:
   - `cat ~/.ssh/known_hosts | grep lab` — found the Pi's pinned host key
   - `ssh-keygen -lf ~/.ssh/known_hosts -F 192.168.0.198` — its fingerprint
   - `ls -la ~/.ssh/` — reviewed existing keypairs
2. Generated a dedicated ed25519 key for the lab:
   - `ssh-keygen -t ed25519 -C "raspberry-pi-lab" -f ~/.ssh/lab_ed25519`
   - `stat -f '%Lp' ~/.ssh/lab_ed25519` — confirmed 600, private key only readable by
     me
   - `ssh-copy-id -i ~/.ssh/lab_ed25519.pub alex@192.168.0.198` — copied the public
     half to the Pi
3. Created an alias for easier login, `~/.ssh/config`:
   ```
   Host lab
      Hostname 192.168.0.198
      User alex
      Port 22
      IdentityFile ~/.ssh/lab_ed25519
      IdentitiesOnly yes
   ```
4. `authorized_keys` restrictions — prefixed the lab key's line with
   `command="echo you can only run this"`, confirmed any requested command
   (`ssh lab whoami` etc.) always ran the forced command instead; removed the
   restriction and confirmed normal behavior returned. Reasoned through `from="<ip>"`
   without a live test (would reject the key outright from any other source IP,
   before even attempting authentication).
5. Tunnels, both directions (reconstructed from the day's plan — confirm/correct the
   actual ports and outcome):
   - `-L` (reach a remote service locally): on the Pi, `python3 -m http.server 8000`;
     on the Mac, `ssh -L 9000:localhost:8000 lab` then `curl localhost:9000` — hits
     the Pi's server through the tunnel.
   - `-R` (expose a local service to the Pi): on the Mac, `python3 -m http.server
     8001`; `ssh -R 9001:localhost:8001 lab`; on the Pi, `curl localhost:9001` — hits
     the Mac's server through the tunnel.
6. Agent forwarding — saw the risk directly (reconstructed, confirm/correct):
   - `ssh-add ~/.ssh/lab_ed25519` then `ssh-add -l` — local agent now holds the key
   - `ssh -A lab`, then on the Pi `ssh-add -l` — the same key listed remotely,
     without the private key file ever touching the Pi
   - cleaned up afterward with `ssh-add -D` (deletes all identities from the running
     agent) — corrected from `ssh-agent -D`, which is a foreground/debug flag for the
     agent process itself and doesn't clear any keys
7. SSH hardening via a drop-in file (`/etc/ssh/sshd_config.d/hardening.conf` — better
   than editing `sshd_config` directly, since a drop-in is easy to remove cleanly):
   ```
   PasswordAuthentication no
   PermitRootLogin no
   AllowUsers alex
   ```
   ```
   sudo sshd -t                    # syntax check the new version
   sudo systemctl reload sshd      # reload, not restart — keeps existing sessions alive
   sudo journalctl -u ssh -f       # watched logs live on the Pi
   ssh test                        # tried a user not in AllowUsers — confirmed it's rejected
   ```

## What broke

Deliberately broke sshd's config to rehearse the recovery discipline:

```
echo "ThisIsNotARealDirective yes" | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t
```

`sshd -t` caught it immediately, before touching the live process:

```
/etc/ssh/sshd_config: line 132: Bad configuration option: ThisIsNotARealDirective
/etc/ssh/sshd_config: terminating, 1 bad configuration options
```

Fixed by restoring the backup:

```
sudo cp /etc/ssh/sshd_config.bak2 /etc/ssh/sshd_config
sudo systemctl restart sshd
```

Confirmed: the original session survived the `restart`. Mechanism (this *is*
checkpoint question 4): each established SSH connection is handled by its own forked
child process of the sshd master, independent of the master once forked. `systemctl
restart` only kills and replaces the **listening master** process — already-open
sessions keep running on their own forked process, untouched. Only *new* connection
attempts go through the new master and see the new (or in this case, broken) config.
This is a different mechanism from `reload` (used in step 7's hardening), which sends
SIGHUP and makes the *same* process re-read its config in place — no process
replacement, no forking involved at all.

## What surprised me

- A forked per-connection process survives `systemctl restart` completely
  independently of the master — the master goes down and comes back, my live session
  never even noticed.
- How `ssh-agent` actually works: it's meant to be a short-lived convenience, not a
  background fixture. Leaving it holding a forwarded key for longer than a single
  session is a real security cost, not just theoretical — hence always `ssh-add -D`
  (the correct command, not `ssh-agent -D`) when done.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. What exactly does the client check on first connection, and what is TOFU?

   On the *first* connection there is nothing to check against — the client just
   displays the host key's fingerprint and asks the human to accept it, a blind trust
   decision. That's TOFU: Trust On First Use. Accepting pins the key into
   `~/.ssh/known_hosts`. Only from the *second* connection onward does the client do
   a real check: compare the presented key against what's pinned, and refuse loudly
   if it ever changes.

2. Difference between `-L 8080:localhost:80` and `-R 8080:localhost:80` — draw the
   arrows.

   - `-L 8080:localhost:80`: `me :8080 → tunnel → remote :80` — a remote service
     becomes reachable at a local port.
   - `-R 8080:localhost:80`: `remote :8080 → tunnel → me :80` — a local service
     becomes reachable at a port on the remote side. The `8080` always names the port
     on the side the connection *originates* from; `localhost:80` always names the
     side the tunnel *reaches into*.

3. Why does `ssh -A` to someone else's server effectively hand your key to that
   server's admin?

   `-A` forwards access to your local agent, not the private key file itself — but
   root on that remote server can use the forwarded agent to sign anything, for as
   long as the session lives. That's functionally equivalent to having the key: they
   can authenticate as you anywhere your key opens, including hopping onward under
   your identity.

4. You restarted `sshd` with a broken config. Why did your current session survive?

   `restart` only kills and replaces the master (listening) process. Each established
   connection is served by its own forked child process, independent of the master
   once forked — so my live session kept running untouched. Only new connections go
   through the new master and see the broken config.

## Open questions

- Redo the day-4 break-it as originally written (physical console recovery via
  keyboard+monitor on the Pi) once a cheap USB keyboard or USB-to-TTL serial adapter
  is available — today's version used a still-open second SSH session as the recovery
  path instead, since no physical keyboard was on hand (Bluetooth-only Magic Keyboard
  doesn't work at this boot stage — no pairing possible without existing input).
- Cloud equivalents of physical console recovery worth knowing by name for
  interviews: AWS EC2 Serial Console / Systems Manager Session Manager, GCP Cloud
  Shell serial port, Azure Serial Console, IPMI/iDRAC/iLO for real/colo hardware.
