# Command lookup card — networking and Python

**Purpose: you are stuck right now and need the command.** Organised by the question
you're asking, not by the day it was learned. Terse on purpose — no explanations, only
what each command answers and the traps that make it silently wrong.

This is the *lookup* half of the reference. The `week-N-cheatsheet.md` files are the
*retention* half — prose, mechanisms, and the "why", for rereading weeks later.

Covers days 13 onward. Days 1–12 (processes, permissions, SSH, systemd, disk, packages,
bash) live in `week-01-02-linux-bash/reference/commands.md` — when a search here comes up
empty, that is the other file to open.

---

## What addresses and interfaces this machine has

```bash
ip -br addr    # one line per interface: name, state, addresses — start here
ip addr show   # full: scope, broadcast address, DHCP lease lifetimes
ip link        # MAC and MTU, no addresses
ip -s link     # RX/TX counters — is this interface actually carrying anything
```

`ifconfig` and `route` are deprecated and absent on modern Ubuntu. `ip` replaced both.

Large RX with small TX = the interface hears the segment's broadcast traffic but is never
chosen for sending. Normal for a second interface with a worse metric, and the quickest
confirmation of which path is really in use.

MAC: first three bytes are the vendor (OUI), last three the device. If the second-lowest
bit of the first byte is set the address is locally administered — randomised, OUI means
nothing.

## Where will this packet actually go

```bash
ip route                   # the rules
ip route get <ip>          # the DECISION for one address  <- ask this, don't apply the rules by hand
ip route show table local  # loopback and local addresses — `ip route` never shows these
```

| In `ip route get` | Meaning |
|---|---|
| `via <ip>` | destination is **not** local — frame goes to that router's MAC |
| no `via` | destination is a neighbour — ARP it directly |
| `dev <iface>` | interface it leaves by |
| `src <ip>` | source address written into the packet |

Lookup: **longest matching prefix wins; equal prefixes break on lowest `metric`.**
`default` is `0.0.0.0/0` — zero fixed bits, the shortest possible prefix, so it can only
win when nothing else matched. Not a flag, arithmetic.

`src` is why connections die with an interface: a connection is a 4-tuple containing that
source address, so when the address goes the tuple belongs to nobody.

## Two machines in one segment can't talk

```bash
ip neigh                  # ARP cache, one state per entry  <- FIRST command, it halves the problem
ip neigh flush dev eth0   # drop entries, force re-resolution
arping -D -I eth0 <ip>    # duplicate address detection
```

| State | Meaning | Look at next |
|---|---|---|
| `REACHABLE` | confirmed recently | layer 2 is fine — suspect the target's firewall dropping ICMP |
| `STALE` | known, not recently reconfirmed, still used | normal, not a fault |
| `INCOMPLETE` / `FAILED` | asked, nobody answered | netmask on **both** sides, link state, host powered off |

Ping tests willingness to answer ICMP, not reachability. A host with a resolved MAC and no
ping reply is usually up and filtering.

Two field favourites: a mask that differs **on one side only** (A thinks B is local, B
thinks A is remote — traffic goes one way), and a duplicate IP (cache flaps between two
MACs, connections work every other time).

Only the next hop is ever cached for a remote destination. `ping 8.8.8.8` puts
`192.168.0.1` in the cache, never `8.8.8.8`.

## Changing a route by hand

```bash
ip route                                                    # write down what you're deleting
sudo ip route del default dev eth0
sudo ip route add default via 192.168.0.1 dev eth0 metric 100
```

**Two default routes hide the breakage.** Deleting one changes nothing visible — the kernel
falls through to the next by metric, silently. Every default must go to produce a symptom.
Same property means a dead redundant path goes unnoticed for weeks.

Do it from a second session in the same segment: the `scope link` route survives, so a local
SSH session lives through having no default route at all.

## Which layer is broken

| Symptom | Meaning |
|---|---|
| `connect: Network is unreachable` | route lookup failed **in the kernel** — no packet was sent, hence instant |
| timeout, no reply | packet left, nothing came back — dropped en route or by a firewall |
| `Destination Host Unreachable` | ARP failed locally — nobody claims that address |
| `Temporary failure in name resolution` | never reached the network — DNS |

Response time is diagnostic: **instant = the failure was local, waiting = something out
there isn't answering.**

**A name resolving proves nothing about connectivity.** With every default route deleted,
`ping google.com` still resolved — the resolver is a neighbour, reachable over the surviving
`scope link` route — and only then failed at `connect()`. "DNS works" is a routine reason to
wrongly cross the network off the suspect list.

## What is listening on this machine

```bash
sudo ss -tulpn      # t=tcp u=udp l=listening p=process n=numeric  <- always with sudo
sudo ss -tulpn | grep -v 127.0.0                 # only what is reachable from outside
sudo ss -s                                       # totals per protocol, incl. timewait
```

**Without `sudo` the Process column is silently empty**, not an error — `-p` has to read
other processes' `/proc/<pid>/fd/`.

**Read the bind address before the port.** `0.0.0.0:5432` is a database on the internet;
`127.0.0.1:5432` cannot be reached from the network at all, whatever the firewall says.
`%eth0` on an address means bound to that interface as well.

`LISTEN` rows: `Send-Q` is the accept-queue ceiling (`net.core.somaxconn`), `Recv-Q` is how
many completed connections are waiting for `accept()`. Same columns on an `ESTAB` row mean
bytes — unread by the app, and sent-but-unacked. Different question per state.

Two processes on one socket is normal: `sshd` + `systemd` on a listener means socket
activation; two `sshd` on a connection means privilege separation.

## Who is connected, and in what state

```bash
sudo ss -tnp state established
sudo ss -tanp state close-wait                   # <- names the leaking process directly
ss -tan state time-wait | wc -l
ss -tan '( sport = :9000 or dport = :9000 )'     # both sides, when both are local
```

| State | Means | Verdict |
|---|---|---|
| `TIME_WAIT` | this side closed **first**; 60 s kernel timer | normal, self-clearing |
| `CLOSE_WAIT` | peer sent FIN, **our app never called `close()`** | application bug, fd leak |
| `FIN_WAIT_2` | we closed, waiting for peer's FIN | clears via `tcp_fin_timeout` only once orphaned |
| `SYN_SENT` (hanging) | SYN sent, nothing came back | problem on the path |

**`CLOSE_WAIT` has no timer and never will** — the kernel cannot close a socket the
application may still write to. That is why it accumulates and `TIME_WAIT` does not.
Restarting the service "fixes" it, which is why the bug survives for years.

Confirm the culprit the day-2 way: `ls -l /proc/<pid>/fd` shows `N -> socket:[inode]`.

## Is it the network or the application

```bash
sudo ss -tinp state established
```

| Field | Read it as |
|---|---|
| `app_limited` | **the application is the limit, not the network** — stop looking at the wire |
| `cwnd:10` | still the Linux initial window; small alone proves nothing |
| `retrans:` present | real loss on the path |
| `rtt:a/b` | smoothed / mdev — includes delayed ACKs (`ato:`) |
| `minrtt:` | the honest wire number, use this one |
| `rto:` | never below 200 ms (`TCP_RTO_MIN`), whatever the RTT |
| `pmtu:` | kernel's current belief about path MTU — first field when a hang smells like MTU |
| `mss:` vs `advmss:` | in use vs announced; 1448 vs 1460 = 12 bytes of timestamps per packet |
| `snd_wnd:` | peer's window, already multiplied by `wscale` |

`bytes_sent == bytes_acked` exactly means nothing is in flight.

## Watching a connection start and finish

```bash
sudo tcpdump -nn -i eth0 'tcp port 22 and tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0'
sudo tcpdump -nn -i eth0 'host 192.168.0.193 and (tcp port 9000 or icmp)'
```

**The flag filter hides pure ACKs** — the third packet of the handshake and the last of
the teardown vanish, so seven packets show as four. Easy to misread as an incomplete
connection. A filter is always part of the answer.

| Flags | Packet |
|---|---|
| `[S]` | SYN |
| `[S.]` | SYN-ACK (`.` is ACK) |
| `[.]` | pure ACK |
| `[F.]` | FIN |
| `[R.]` | RST |
| `E`, `W` | ECN negotiation, not an error |

`ack` = peer's `seq` + 1 on a `length 0` SYN because **SYN consumes a sequence number**.
FIN does too. Sequence numbers go relative once tcpdump has seen the handshake.

`mss`, `wscale`, `sackOK`, `TS` appear **only in the SYN** and can never be renegotiated.
A middlebox stripping SYN options leaves a working connection permanently capped at 64 KB.

## Is the port reachable — and is there a firewall

```bash
time nc -v -w 20 <host> <port>      # measure it, the duration is the diagnosis
```

| On the wire | Client sees | What it is |
|---|---|---|
| SYN-ACK | success | open, listener present |
| RST | `Connection refused` | port closed **or** a firewall rejecting — indistinguishable |
| nothing, repeated SYNs | timeout | DROP, wrong route, or host down |

**The split is answer vs silence, not three symptoms.** An answer proves the host is alive
and something refused actively; *what* refused cannot be told from the client. Silence
means something swallows the packet.

`ufw reject <port>/tcp` sends a **RST, not ICMP** — ufw overrides the iptables default
(`common.py`: `# follow TCP's default and send RST`). `ufw reject <port>/udp` still gives
ICMP port unreachable. `ufw deny` is DROP.

An ICMP `port unreachable` whose **source address differs from the destination** proves a
middlebox firewall you did not know about. `nc` shows `Connection refused` either way;
only the capture distinguishes them.

Repeated identical SYNs with no reply is the signature of DROP. Retry pattern is the
client OS's, not the network's: Linux backs off 1,2,4,8,16,32 and gives up near 127 s
(`tcp_syn_retries=6`); macOS starts flat at 1 s.

**Timing measures the client, not the path.** A RST arriving in 0.2 ms was reported by
macOS `nc` after 1.02 s, because it re-sent the SYN once first. And `nc -w` on macOS does
not apply to `connect()` — a DROPped port hangs past the stated timeout.

## What does this name resolve to, and who says so

```bash
dig <name> +short                       # just the answer
dig <name>                              # status, flags, TTLs — read these, not just the address
dig <name> @1.1.1.1                     # ask a specific resolver, bypassing your own cache
dig <name> @<authoritative-ns>          # ask the source; the only current answer
dig <name> +trace                       # walk the delegation from the root yourself
dig <name> +nsid @8.8.8.8               # which instance of that resolver answered
```

Use `dig`, not `nslookup` — `nslookup` shows less and misreports authoritativeness.

| In the header | Means |
|---|---|
| `status: NOERROR` + ANSWER section | resolved |
| `status: NXDOMAIN` + `SOA` in AUTHORITY | the name does not exist; the `SOA` **is** the proof, and carries the negative TTL |
| `flags: ... aa` | authoritative — the source, not a relay |
| no `aa` | a cached or relayed answer |
| `WARNING: recursion requested but not available` | normal when asking an authoritative server |
| `couldn't get address for '<ns>'` | the **server's own name** would not resolve — your query was never sent |

**A TTL says where the answer came from.** Round full numbers = fresh from authoritative;
odd decreasing numbers = the remainder of a cache entry. Visible in every output, costs
nothing.

`SOA` fields, left to right: primary NS, admin email (`@` written as a dot), serial,
refresh, retry, expire, **negative-cache TTL** — the last one is how long `NXDOMAIN` may be
remembered (1800 on Cloudflare).

## Why does it resolve differently over there

```bash
for i in $(seq 1 20); do dig +short <name> @8.8.8.8; done | sort | uniq -c
dig <name> +nsid @8.8.8.8 | grep NSID
dig <zone> NS @<parent-tld-server>      # parent's copy of the delegation
dig <zone> NS @<child-ns>               # child's own copy
```

**One query proves nothing.** A public resolver is anycast across sites and each site runs
many instances with independent caches — a rising TTL between two queries to the same
address proves it. Sample and count instead.

Parent and child `NS` copies must match in **names**; differing TTLs are normal and
harmless (each zone sets its own).

Two users of one public resolver can see different answers simultaneously and both be
right. "Flush your DNS" against a public resolver is close to meaningless.

## Changing a DNS record without hurting anyone

```bash
# Cloudflare, token scoped Zone:DNS:Edit on ONE zone
read -rsp 'CF token: ' CF_TOKEN; echo; export CF_TOKEN     # keeps it out of ~/.bash_history

ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
  'https://api.cloudflare.com/client/v4/zones?name=<zone>' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')

curl -s -X POST -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  --data '{"type":"A","name":"lab","content":"<ip>","ttl":300,"proxied":false}'
```

`"name":"lab"` — the short label; Cloudflare appends the zone. Writing the full name
produces `lab.<zone>.<zone>`.

**`"proxied": false` matters.** Left true, DNS returns Cloudflare's addresses instead of
yours and every TLS and reachability test afterwards measures the wrong thing.

**Lower the TTL a day BEFORE a migration, never during.** For a new low TTL to apply, the
old high one must expire first. The TTL that governs a cached bad record is the one in
force when it was **fetched** — changing it afterwards helps nobody already affected, only
the next incident.

Break-it on a **throwaway name**, never on the one needed tomorrow: the exercise burns that
name for the length of its TTL, and deleting the record does not touch caches that hold it.

An `A` record must point at an address reachable from the internet. An RFC1918 address
(`10/8`, `172.16/12`, `192.168/16`) is dropped by every backbone router. Check for an ISP
NAT before planning a port forward: compare the router's WAN address with
`dig +short myip.opendns.com @resolver1.opendns.com` — if the WAN address is private, there
is a NAT in front that you do not control and forwarding a port cannot work.

## DNS on Ubuntu is systemd-resolved

```bash
ls -l /etc/resolv.conf          # a symlink you do not own — editing it achieves nothing
resolvectl status               # per-link servers, search domains, DNSSEC state
resolvectl query <name>         # resolved's own API: says which link answered
resolvectl flush-caches
```

`dig` sends an ordinary packet to `127.0.0.53`; `resolvectl query` goes through resolved's
API and applies per-link DNS and split-DNS that a plain packet cannot express. When they
disagree, they are answering different questions.

`127.0.0.53` is the stub with all of resolved's routing logic; `127.0.0.54` is a bypass
that forwards upstream without it.

Watch for `DNS Domain:` in `resolvectl status` — a search domain from DHCP, silently
appended to unqualified names, and a good source of baffling lookups.
