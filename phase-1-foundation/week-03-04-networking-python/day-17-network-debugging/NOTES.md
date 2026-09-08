# Day 17 — Network diagnostics, NAT, firewall

Date: 2026-09-08
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64), `192.168.0.197`; probes and
failed logins driven from the macOS workstation, `192.168.0.193`

## Re-quiz (spaced retrieval)

**Skipped, deliberately.** The questions picked (day 13's `/24` vs `/16`, the `/0` default
route, day 4's surviving SSH session) had already been answered as checkpoints on their own
days, and re-asking them was not worth the time today. Day 13's remaining checkpoints stay
in the pool.

## What I did

The day's designed break-it — real SSH brute force arriving from the internet — was blocked
before it started, and proving *why* became the first exercise instead. The rest of the day
kept its shape: NAT, conntrack, rule order, path diagnostics, `tcpdump`.

### 1. The day-16 blocker, measured rather than assumed

Three independent observations, each one sufficient:

| What | Value |
|---|---|
| Pi on the LAN | `192.168.0.197`, gateway `192.168.0.1` |
| WAN address of the home router | `172.22.76.133` — **RFC 1918, private** |
| Address the internet sees (`curl ifconfig.me`) | `178.151.120.5` |

The router has no public address at all. Translation happens **twice**:
`192.168.0.197 → 172.22.76.133 → 178.151.120.5`. `traceroute` confirmed it from a third
direction — hop 2 is `172.22.76.254`, the gateway of the same `/24` the WAN address lives
in, then four hops of `10.x` before the first public address at hop 7. The ISP's entire
core is privately addressed; the NAT boundary sits between hops 6 and 7.

The ISP uses RFC 1918 space rather than the `100.64.0.0/10` reserved for this (RFC 6598),
which is why the diagnosis needed the comparison rather than a single glance.

So the conclusion recorded on day 15 as a suspicion is now a measurement, and its exact
statement matters: **port forwarding on my own router cannot work, and the problem is not
configuration — it is that I do not own the box holding the translation table.** A packet
to `178.151.120.5:443` reaches the ISP's router, which finds no entry for port 443 and
drops it. It never travels as far as a rule I could write.

### 2. NAT and conntrack are one mechanism, not two

A NAT entry is created by an **outbound** packet. An unsolicited inbound packet does not
find one — and the failure is not a policy decision but an absence of information: the
destination reads "the public address, port 443" and nothing in the packet says which
internal host was meant. Port forwarding is that same table row, installed by hand and
permanently.

The same table is what makes a stateful firewall possible. With a default-deny inbound
policy, the reply to an outbound connection *is* an inbound packet; without state, allowing
it means allowing all of `1024–65535`, which is why stateless filters were useless in
practice. `ESTABLISHED,RELATED → ACCEPT` replaces that with one rule, because the decision
comes from memory of what this machine started.

In Linux these are literally the same machinery: **NAT is stored as an attribute of the
conntrack entry**. Reading one live row makes it obvious:

```
tcp 6 431999 ESTABLISHED
    src=192.168.0.193 dst=192.168.0.197 sport=61730 dport=22    ← original direction
    src=192.168.0.197 dst=192.168.0.193 sport=22 dport=61730    ← reply direction
    [ASSURED]
```

An entry is a **pair of tuples**: how the packet looks going out, and how the reply must
look coming back. On a machine doing no translation the reply is an exact mirror. On one
doing NAT it is not — and that is the diagnostic:

> **If the reply tuple is not a mirror of the original, translation happened, and the row
> shows exactly what it was rewritten to.**

Two numbers from the same output worth keeping:

- `431999` counts down from **432000 seconds — five days**
  (`nf_conntrack_tcp_timeout_established`). That is how long the kernel remembers an idle
  TCP connection. Home routers shorten it to minutes to save memory, which is the whole
  reason `ServerAliveInterval` and TCP keepalive exist.
- `[ASSURED]` means traffic was seen both ways. Under table pressure the kernel evicts
  non-assured rows **first**, so scan garbage dies before real sessions. Eviction is not
  random.

### 3. Rule order, proven with counters

Existing rules had `[1] OpenSSH ALLOW IN Anywhere` first. Added the classic real-world
mistake — a specific deny, appended the ordinary way:

```
sudo ufw deny from 192.168.0.193 to any port 22 proto tcp
```

Predictions stated before running: the rule lands last, new SSH still works, and its packet
counter stays at exactly zero. All three held:

```
1    4   256  ACCEPT  tcp dpt:22  /* 'dapp_OpenSSH' */
4    0     0  DROP    tcp dpt:22  src 192.168.0.193      ← zero
```

A syntactically perfect rule that has never seen a packet. Not wrong — **too late**. Which
is the contrast worth holding against day 13:

| | Which rule wins |
|---|---|
| Routing | **longest prefix** — position in the table is irrelevant |
| Firewall | **first match** — position is everything |

Moving it to position 1 made it fire: `10` packets, `640` bytes, all dropped.

### 4. `tcpdump` at a level worth trusting

`-nn` always (one `n` skips address resolution, two also skips ports; without it tcpdump
issues a DNS query per packet and, when debugging DNS, captures traffic it generated
itself). `-i any`. The filter is BPF and compiles **into the kernel**, so filtering happens
*at capture time* — anything not asked for never existed, and an over-specific filter
discards the packet that would have explained the problem. `-c N` to bound it, `-w file` to
capture on the server and analyse on the workstation.

Reading is by **shape**, not line by line: was there a handshake, what sizes, how long did
it last, how did it close. Eighty-four lines for three trivial connections is already past
what a human reads.

## What broke

Four separate failures, and by the end they were clearly one family.

### The capture fed itself

`tcpdump -nn -i any 'port 22 and host 192.168.0.193'` — run over an SSH session from
`192.168.0.193` on port 22. Every keystroke matched the filter, and worse, it was a closed
loop: tcpdump prints a line → the line is sent to the workstation over port 22 → that packet
matches the filter → tcpdump prints a line. The output never stopped because the capture was
watching itself.

Fix: exclude the control session by its own port, which `$SSH_CLIENT` supplies —

```
sudo tcpdump -nn -i any "port 22 and host 192.168.0.193 and not port $(echo $SSH_CLIENT | awk '{print $2}')"
```

The substitution runs in the login shell *before* `sudo`, which is why `$SSH_CLIENT` is
still visible despite `sudo` clearing the environment. **Silence is the correct state of a
capture** — everything appearing afterwards is the traffic actually under test.

General form of the rule: **never capture on the channel you are using to watch the
capture.** `-c` and `-w` exist for the cases where excluding it is not possible.

### The firewall forbade my access and kept talking to me

With the deny at position 1, the existing SSH session continued working — the whole session
after that point was conducted over a connection the firewall explicitly denies. That is not
a bug and not luck: the session's `[ASSURED]` row is accepted in `ufw-before-input`, several
chains before any user rule is consulted.

The counters proved the mechanism independently, and this was the day's best accidental
find. Every rule in `ufw-user-input` showed **exactly 64 bytes per packet**:

```
rule 1:   4 packets /  256 bytes  → 64 B/packet
rule 3:  26 packets / 1664 bytes  → 64 B/packet
```

64 bytes is a SYN. **Nothing but SYNs reaches the user chain** — everything else is matched
by the ESTABLISHED rule upstream and never arrives. So the counter on the rule that permits
SSH counts *connections*, not traffic: a session that moved tens of thousands of packets
reads `4`.

The operational statement:

> A firewall filters **connections, not people**. A live session is no evidence that the
> rules are right — it is evidence that conntrack remembers it. Only a **new** connection
> tests a rule.

The failure mode this produces is well known and now understood from the inside: change
rules, confirm the session is fine, conclude success, reboot, discover the table is empty
and the machine is unreachable.

The dropped rule also priced `DROP` against `REJECT` exactly: one `ssh` attempt produced
**10 SYNs over ~2 minutes** as TCP retransmitted with exponential backoff into silence.
`REJECT` would have cost one packet and returned an instant error. Day 16 measured this with
a stopwatch; here it is visible as a packet counter.

### The hardened server made the exercise impossible, and that was the finding

`ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no nosuchuser@lab`,
intending three password attempts. The capture showed three connections, each **168 ms**
long, each byte-for-byte identical, each closed with a clean `[F.]`.

168 ms means no human was involved. Day 16's hardening sets `PasswordAuthentication no`, so
the server offered only `publickey`, the client had no permitted method left, and it hung up
before any prompt could exist. The log agreed and named it:

```
sshd[6907]: Invalid user nosuchuser from 192.168.0.193 port 54755
sshd[6907]: Connection closed by invalid user nosuchuser 192.168.0.193 port 54755 [preauth]
```

Consequences worth more than the exercise:

- **On a key-only server `Failed password` never appears.** Any brute-force protection
  configured to look for that line is a control that reports healthy and bans nobody.
- **The source port is the join key between a packet capture and an application log.**
  Timestamps prove nothing at scale; `port 54755` appears in both views and identifies one
  connection.
- `Invalid user` is told to the **log**, never to the client — the client gets a flat
  `Permission denied`. Distinguishing the two in the reply would be a username-enumeration
  oracle.
- Three PIDs, `6907 / 6909 / 6911`, stepping by two: `sshd` forks a child per connection
  plus a privilege-separation child. This is day 4's checkpoint seen from the other side —
  the session is not the process listening on the port.

The wire also gave away, in cleartext and before any authentication,
`SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.19` — not just the version but the **exact package
revision**, i.e. a precise answer to "which CVEs are open here". Yesterday it was SNI, today
a version banner: encryption protects **content**, never the negotiation that establishes
it. This is how Shodan knows every SSH server's version; nobody broke in, it was volunteered
during introductions.

### `fail2ban` installed successfully and could not start

```
ERROR   No module named 'asynchat'
Active: failed (Result: exit-code)
```

`asynchat`/`asyncore` were removed from the standard library in **Python 3.12** (PEP 594);
Ubuntu 24.04 ships 3.12 and `fail2ban 1.0.2-3`, which still imports them.

`apt policy` held the real explanation in one word:

```
1.0.2-3  500  http://ports.ubuntu.com/ubuntu-ports noble/universe arm64
```

**`universe`.** Which corrects day 8's conclusion rather than repeating it. That day's rule
was "a package from the repository is maintained, one built by hand is not". More precisely:

| Component | Maintained by | Security updates |
|---|---|---|
| `main` | Canonical | guaranteed for the LTS lifetime |
| `universe` | the community | **best effort**; may be broken and stay broken |

The upstream issue tracker settled the rest — [#3755](https://github.com/fail2ban/fail2ban/issues/3755)
is this exact error at this exact version on this exact release, closed in a day as a
duplicate of [#3487](https://github.com/fail2ban/fail2ban/issues/3487):

| Date | Event |
|---|---|
| 2022-11-09 | fail2ban 1.0.2 released |
| 2023-04-01 | #3487 opened — fails on Python 3.12 |
| **2023-12-12** | **fixed upstream** |
| 2024-04-25 | fail2ban 1.1.0 released, containing the fix |
| 2024-04-25 | **Ubuntu 24.04 LTS released — the same day** |
| 2026-08-15 | 1.1.1 released; the project is active |
| 2026-09-08 | `apt policy` on this Pi says `1.0.2-3` |

The fix existed **four months before** Ubuntu 24.04 shipped, and the LTS was released with a
package that could not start. That much is real.

### The conclusion drawn from that was wrong, and the error is worth more than the fact

From `apt policy` showing `1.0.2-3` as both Installed and Candidate, with `universe` as the
only origin, the day concluded: **no fix exists, because a `universe` package that cannot
start never found a volunteer.** Launchpad disagrees:

```
1.0.2-3ubuntu0.1   pocket=Updates   Published   2024-06-27
1.0.2-3            pocket=Release   Published   2024-01-04
```

**The fix was published to `noble-updates` on 2024-06-27** — three weeks after the upstream
issue was filed, nine weeks after the LTS release. Somebody did the work, and it has been
sitting there for two years.

This machine never saw it, because `/etc/apt/sources.list.d/ubuntu.sources` reads:

```
Suites: noble             ← release pocket only
Suites: noble-security    ← security fixes
```

No `noble-updates`. The Pi receives security fixes and **no bug fixes at all**, and has
since it was installed. `artifact-server-bootstrap` is not the cause — it never touches apt
sources — so this arrived with the Raspberry Pi image.

The reasoning error generalises further than the packaging fact:

> **A diagnosis inherits the configuration of the tool that produced it.** `apt policy`
> answered honestly — *this machine* has no newer candidate — and that was read as a claim
> about what exists at all. The missing suite was visible in the very same `apt update`
> output used to reach the conclusion; it was noticed, written down as a side remark, and
> the conclusion drawn from the incomplete data anyway.

Which is day 16's false pass in different clothes. There, a broken chain was certified
healthy by an unrepresentative TLS stack; here, a package sitting in the archive was
declared nonexistent by an unrepresentative apt configuration. **A confident answer from a
misconfigured instrument is worse than no answer, because it closes the question.**

The `main`/`universe` distinction survives, but narrower: support levels genuinely differ,
and reading the component before installing is still the right habit. It simply was not the
explanation here. The one-word read of `universe` was a plausible story that arrived early
and stopped the investigation — which is its own hazard, separate from being wrong.

The one-line check that would have caught it:

```bash
grep '^Suites:' /etc/apt/sources.list.d/ubuntu.sources
```

`<release>`, `<release>-updates` and `<release>-security` should all be there.

Decision: `fail2ban` purged rather than replaced with the upstream `.deb`. The failure had
already produced every lesson it contained, and installing it would have added work, not
understanding. `ufw limit OpenSSH` covers the same ground with no third-party package — it
rate-limits new connections (6 in 30 s) through the same nftables read all day.

## What surprised me

- That **64 bytes per packet across every counter** is a readable fact. The user chain sees
  only SYNs, so those counters measure connection attempts; a rule permitting a busy service
  can legitimately read `4`.
- That the whole second half of the session ran over a connection the firewall denies at
  rule 1, and that this is correct behaviour rather than a leak.
- That loss in `mtr` **decreasing** down the path (55% → 40% → 0%) is by itself proof of
  rate limiting: real loss can only accumulate, because a lost packet does not reappear.
- That the ISP's core is entirely RFC 1918 — six private hops before the first public
  address.
- That an LTS release shipped a package fixed upstream four months earlier and left it
  broken for two years, and that `apt policy` says so in one word.
- That a hardened `sshd` silently invalidates the standard brute-force filter, so the
  protection everyone installs first is the one hardening quietly disarms.

## Checkpoint answers

**Not answered — carried to the opening of day 18**, where they double as the re-quiz.
Transcribed from the curriculum:

1. Why does an inbound connection not reach a machine behind NAT without explicit
   configuration?
2. `traceroute` shows 100% loss at hop 6, but the destination answers. What does that mean?
3. A firewall rule is added and traffic still flows. What do you check?
4. How do you see what is actually on the wire, without installing anything extra?

## Open questions

- **`noble-updates` is missing from the apt sources — confirmed, not yet fixed.** Adding the
  suite and running `apt upgrade` will pull a backlog accumulated since installation,
  possibly including a kernel, so it wants a moment when a reboot is acceptable. Worth
  deciding afterwards whether `artifact-server-bootstrap` should assert the suite list,
  given that the image it bootstraps shipped without it.
- **`ufw limit` was enabled but never triggered on purpose.** The intended demonstration —
  ten rapid connections from the workstation, blocking after the sixth, visible in the
  `ufw-user-limit` counters — was not run. It is five minutes whenever there is appetite.
- **CGNAT is now proven, not suspected.** The two ways out are unchanged: a public address
  as a paid option from the ISP, or a tunnel. Everything else in the day-16 configuration is
  complete and would work the moment packets can arrive.
- Whether `ufw`'s `limit` covers IPv6 the same way it covers IPv4 — the generated rules were
  not read for the v6 side.
- `nft list ruleset` was never read directly; the `iptables -L` view was used throughout
  because of its per-rule counters. Reading the native nftables form once is worth doing,
  since that is what is actually loaded.
