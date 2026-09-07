# Week 3 cheat sheet — networking

Compressed from days 13 onward. Full write-ups and command history live in each day's
`NOTES.md`; commands for mid-task lookup live in `commands.md`; term definitions live in
the repository's `GLOSSARY.md`. This is the version to reread weeks later: mechanisms and
why they bite.

Built up as the week lands; day 17 is still to come.

## Layers, addressing, routing (day 13)

### Why there are layers at all

**MAC addresses are a flat space.** Six bytes, three of vendor OUI and three of device,
with no hierarchy to aggregate on. A flat space cannot be routed: there is no prefix to
summarise, so every router on earth would need an entry per device. That is the whole
argument for layer 3 — IP addresses are hierarchical *on purpose*, so a router can hold
one entry for a whole range.

The consequence to remember: **a MAC address never leaves its own segment.** A router does
not forward a frame, it rebuilds it, with its own MAC as source and the next hop's as
destination. Only the IP header survives end to end.

### CIDR is a count of fixed bits

`/24` means the leftmost 24 bits are the network and the rest identify hosts. Nothing more
magical than that. A host ANDs an address with the mask, compares the result with its own
network, and gets one answer: **is this destination local, or does it go to the gateway?**

So the practical damage from a wrong mask is not the range size. With `/16` instead of
`/24`, the machine believes `192.168.50.7` is a neighbour and ARPs into the void **instead
of using the perfectly good gateway it has**. The broadcast address moves too:
`192.168.1.255` becomes `192.168.255.255`.

RFC1918 ranges (`10/8`, `172.16/12`, `192.168/16`) are private by agreement: routers on
the public internet drop them, which is why they can be reused in every home and office
without collision.

### The routing table is an ordered decision, not a list

**Longest matching prefix wins. Metric only breaks ties between equal prefixes.**

The default route is `0.0.0.0/0` — zero fixed bits, the shortest possible prefix — so it
can only win when nothing else matched. It is last by arithmetic, not by a flag marking it
as a fallback. There is no "default" property doing the ordering.

Seen live on the Pi: three entries matched `192.168.0.1` — a `/32` host route installed by
the DHCP client, the `/24` for the segment, and the default — and the `/32` took it.

**`ip route get <ip>` is the command of the day** because it prints the *decision* rather
than the rules. Reading `ip route` and applying longest-prefix-match by hand is how
mistakes happen.

| In `ip route get` | Meaning |
|---|---|
| `via <ip>` | destination is **not** local — the frame goes to that router's MAC |
| no `via` | destination is a neighbour — ARP it directly |
| `src <ip>` | the source address that will be written into the packet |

That `src` is why connections die when an interface goes away: a connection is a four-tuple
containing that source address, so when the address goes, the tuple belongs to nobody.

### ARP, and the two ways its cache goes wrong

ARP turns an IP address into a MAC **within one broadcast domain**, and only there. For a
remote destination what gets resolved is the **next hop's** MAC, never the destination's —
`ping 8.8.8.8` puts `192.168.0.1` in the cache and never `8.8.8.8`.

The cache is the first place to look when two machines in one segment cannot talk, because
it halves the problem:

| State | Means | Look at next |
|---|---|---|
| `REACHABLE` | confirmed recently | layer 2 is fine — suspect the target's firewall dropping ICMP |
| `STALE` | known, not recently reconfirmed, still usable | normal, not a fault |
| `INCOMPLETE` / `FAILED` | asked, nobody answered | masks on **both** sides, link state, powered off |

**Stale and poisoned produce the identical symptom from opposite causes.** Stale is expired
truth — swap a router and the old MAC lingers until the timer clears it. Poisoned is
injected falsehood, and it is possible because **ARP has no authentication whatsoever**:
any host in the segment may answer for any address, and may announce itself unsolicited
(gratuitous ARP). The victim caches the lie and sends traffic to the attacker's MAC.

Two field favourites for "same segment, no ping": a mask that differs **on one side only**
(A thinks B is local, B thinks A is remote, traffic flows one way), and a duplicate IP
(the cache flaps between two MACs and connections work every other time). And ping tests
willingness to answer ICMP, not reachability — a resolved MAC with no reply usually means
a host that is up and filtering.

### Redundancy hides the breakage it exists for

Deleting one of two default routes on the Pi changed **nothing visible**: the kernel fell
through to the second at metric 600. Both had to go before a symptom appeared.

That is redundancy working as designed, and it is exactly why a dead path goes unnoticed
for weeks — until the surviving one fails and two faults surface as one.

Where both interfaces sit in the *same* subnet, as they did here, the metric decides at
every prefix length rather than only at the default route: each of `/0` and `/24` exists
twice, and the lower metric wins them all. The link counters prove it — the unused
interface shows large RX and tiny TX, because it hears every broadcast in the segment and
is never chosen for sending.

### The error message names the layer

With every default route gone, `ping google.com` failed instantly:

```
ping: connect: Network is unreachable
```

| Symptom | Meaning |
|---|---|
| `connect: Network is unreachable` | route lookup failed **in the kernel** — no packet was ever sent |
| timeout, no reply | the packet left and nothing came back |
| `Destination Host Unreachable` | ARP failed locally — nobody claims that address |
| `Temporary failure in name resolution` | never reached the network at all — DNS |

**Response time is the diagnosis: instant means the failure was local, waiting means
something out there is not answering.** The word `connect:` names the syscall that failed,
which is the tell that nothing was ever put on the wire.

**And DNS kept working with the internet entirely unreachable.** The resolver was a
neighbour in the same segment and the `scope link` route was never deleted, so the query
went out by ARP with no gateway involved. A name resolving proves nothing about
reachability past the local segment — and it is a routine reason to wrongly cross the
network off the list of suspects.

## TCP, UDP, sockets, connection states (day 14)

### A port is an address, not an identifier

A **socket** is a kernel object, addressed by a file descriptor, and therefore governed by
every rule that governs descriptors: inherited across `fork()`, counted against
`ulimit -n`, closed only by the process that owns it. That single fact explains most of
what follows.

A connection is identified not by a port but by the **four-tuple**:

```
src IP : src port  →  dst IP : dst port
```

This is why one server port carries 40 000 connections: the server's half repeats in every
one of them, and uniqueness comes from the client's half. The famous ~28 000 limit is the
size of the **client's** ephemeral pool, and it caps how many connections *one client* can
hold to *one* server address and port — not what a server can accept. A server runs out of
file descriptors instead.

The ephemeral pool is an operating-system choice, not part of TCP: Linux 32768–60999
(`net.ipv4.ip_local_port_range`), macOS 49152–65535. Reading a capture, a high source port
in an unexpected range is a hint about the client's OS.

**Listening and established sockets are different objects.** A listener holds one half of
an address pair and stays put; every accepted connection becomes its own socket with a
complete four-tuple. `ss` showing one `LISTEN` line and thousands of `ESTAB` lines on the
same port is not duplication — it is one acceptor and thousands of connections.

**TCP:53 and UDP:53 are unrelated sockets.** The protocol is part of a socket's identity,
so the same port number in two protocols never collides.

### The handshake exists to start the numbering

The usual explanation — "to check both ends are alive" — is true and explains nothing
further. The real content of `SYN` → `SYN-ACK` → `ACK` is the exchange of **initial
sequence numbers** in each direction.

Everything TCP is valued for stands on those numbers. Every byte is numbered, so the
receiver reassembles by number rather than by arrival time; the receiver acknowledges
numbers, so the sender knows what landed; unacknowledged ranges are resent. Ordering,
loss detection and retransmission are not three mechanisms but three consequences of one
decision: number the bytes.

Which also states the case for UDP precisely. UDP does not number, therefore it *cannot*
order, detect loss or retransmit. Not a policy choice — an absence.

**SYN consumes a sequence number**, even on a zero-length packet: an `ack` of ISN+1 is
what makes the connection itself acknowledgeable and retransmittable. FIN does the same.

**Options appear only in the SYN and can never be renegotiated** — `mss`, `wscale`,
`sackOK`, timestamps. A middlebox that strips SYN options leaves a connection that works
perfectly and is permanently capped at a 64 KB window. This is a whole class of "the
network is just slow" that is invisible anywhere except the first two packets.

### Two windows that are constantly confused

| | Protects | Set by | Field |
|---|---|---|---|
| Flow control | the **receiver** | receiver announces it | `rwnd` / `snd_wnd` |
| Congestion control | the **network** | sender guesses it | `cwnd` |

`rwnd` small means the application on the far side is not reading fast enough — the
network may be entirely idle. `cwnd` small with rising retransmits means real loss on the
path. Diagnosing one as the other is the standard mistake, and `ss -tin` prints both.

### Closing is two independent closes

TCP is duplex — effectively two streams — so each direction is closed on its own:
`FIN`/`ACK` one way, then `FIN`/`ACK` the other. Half-closed is a legal state, not a
fault, and the two states worth knowing both grow out of that asymmetry.

| State | Meaning | Verdict |
|---|---|---|
| `TIME_WAIT` | this side closed **first**; 60 s | normal, self-clearing |
| `CLOSE_WAIT` | peer sent FIN, our app has not called `close()` | application bug |
| `FIN_WAIT_2` | we closed, waiting for the peer's FIN | clears via `tcp_fin_timeout` **once orphaned** |
| `SYN_SENT`, hanging | SYN sent, nothing came back | problem on the path |

**`TIME_WAIT` is not a leak.** The 60 seconds exist so a lost final ACK can still be
answered — otherwise the peer's retransmitted FIN would draw a `RST` and a clean close
would end as an error — and so that stale packets of the old connection cannot be
delivered into a new one that reuses the same four-tuple. Thousands of them mean only that
this side is the one closing, which is normal for HTTP without keep-alive.

**`CLOSE_WAIT` has no timer and cannot have one.** The kernel is waiting on the
application, which still holds the right to write into its own un-closed direction; a
timeout would mean cutting off a legal connection. So `TIME_WAIT` clears itself and
`CLOSE_WAIT` never does. Each one is a file descriptor held until the process closes it or
dies — the day-2 fd leak wearing a network costume.

That is also why the bug survives for years: restarting the service frees every descriptor
at once, the symptom vanishes, and the cause is filed under "network".

Diagnosis is one command: `sudo ss -tanp state close-wait` prints the process and the fd
number. Cross-check the day-2 way — `ls -l /proc/<pid>/fd` shows `N -> socket:[inode]`.

Worse variant worth recognising: `CLOSE_WAIT` with a non-zero `Recv-Q` means the
application did not even read what arrived before abandoning the socket.

### UDP: what is given up, what is bought

Three things are bought with the loss of ordering and delivery guarantees.

**Message boundaries survive.** One `sendto()` is one datagram is one `recvfrom()`. TCP
has no boundaries at all — it is a byte stream, so two sends of 10 bytes may be read as
one 20-byte chunk, and every protocol over TCP must frame its own messages with a length
prefix or a delimiter. UDP has done that work already.

**No state on the server.** Nothing to hold in memory, nothing to close, `CLOSE_WAIT`
impossible by construction.

**No head-of-line blocking.** In TCP a lost packet stalls everything behind it — the later
data has arrived and sits in the buffer, undeliverable without breaking order. In UDP the
loss is just a hole and the rest flows. For voice and video that is the correct trade:
better a missing millisecond than a delayed stream.

**Why DNS is UDP** falls straight out of this: query and answer fit in one datagram each,
so paying a three-packet handshake for a two-packet exchange costs more than the payload.
Retrying is cheaper on the client. **Why a zone transfer is TCP**: it is bulk data that
must arrive complete and in order, and the handshake is negligible against a megabyte.

### MTU: the failure that looks intermittent and is not

**MTU is a property of one link, not of a path.** Each side computes its announced `MSS`
from its *own* first link — 1500 − 20 (IP) − 20 (TCP) = 1460 — and neither knows anything
about what lies between them. The usable figure then drops further by the options carried
on every packet: timestamps cost 12 bytes, which is why an `ss -tin` shows `mss:1448`
against a handshake's `mss 1460`.

TCP always sets the `DF` flag, so a router facing a smaller link may not fragment. It must
drop the packet and return ICMP `fragmentation needed` (type 3, code 4) naming the real
MTU. That is **Path MTU Discovery**, and it is the only way the sender ever learns.

Block that ICMP — a very common "hardening" — and the failure mode is this. The handshake
succeeds; it is tiny. Small responses succeed; they fit. Then the first full-sized data
segment is dropped and *nothing comes back*: no ACK, no error. To the sender it looks like
ordinary loss, so it retransmits the same oversized packet, forever.

This is a **PMTUD black hole**, and its signature is that the connection works
deterministically by size, not randomly by time: `curl` connects, gets headers, hangs on
the body; SSH logs in but `ls` of a large directory freezes the session. Tunnels and VPNs
are the usual culprits since they add headers and shrink the effective MTU. First field to
check: `pmtu:` in `ss -tin`.

### Reading `ss -tin`

| Field | Read it as |
|---|---|
| `app_limited` | **the application is the limit, not the network** — stop looking at the wire |
| `cwnd:10` | Linux's initial window; small on its own proves nothing |
| `retrans:` present | real loss on the path |
| `rtt:a/b` | smoothed / mdev — inflated by delayed ACKs (`ato:`) |
| `minrtt:` | the honest wire number |
| `rto:` | never below 200 ms (`TCP_RTO_MIN`), whatever the RTT |
| `pmtu:` | the kernel's current belief about path MTU |
| `mss:` vs `advmss:` | in use vs announced — the gap is per-packet options |
| `snd_wnd:` | the peer's window, already multiplied by `wscale` |

`bytes_sent == bytes_acked` exactly means nothing is in flight. A minimum RTO of 200 ms
means one loss costs a fifth of a second even on a sub-millisecond LAN, which is why a
single drop is so visible in interactive traffic.

### Reading a handshake in tcpdump

`.` is ACK, so `[S.]` is SYN-ACK, `[F.]` is FIN, `[R.]` is RST, `[.]` alone is a pure ACK.
`E` and `W` are ECN negotiation, not errors — and a client that offered ECN on its first
SYN and dropped it on the retries is guessing that ECN was what got the packet lost.

**A filter is part of the answer.** Filtering on `tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst)`
excludes pure ACKs, so the third packet of the handshake and the last of the teardown
disappear: seven packets show up as four, which reads exactly like a connection that never
completed. Sequence numbers also switch to relative once tcpdump has seen the handshake.

### Reachability: the split is answer vs silence

| On the wire | Client sees | What it is |
|---|---|---|
| SYN-ACK | success | open, listener present |
| RST | `Connection refused` | closed port **or** a rejecting firewall — indistinguishable |
| nothing, repeated SYNs | timeout | DROP, wrong route, or host down |

The curriculum's three symptoms collapse into two questions in practice, because a RST from
the kernel and a RST from a firewall are byte-identical.

**An answer is the good news**: the host is alive, the path works, something refused
deliberately. What refused cannot be determined from the client — that resolves only on the
host, with `ss -tulpn` and the firewall's own rules. **Silence is the bad news**: the packet
is being swallowed and the cause could be a firewall, a route, or a dead machine.

`ufw reject <port>/tcp` answers with a **RST, not ICMP** — ufw overrides the iptables
default deliberately, and only for TCP (`common.py`: `# follow TCP's default and send RST`),
so `ufw reject <port>/udp` still returns ICMP port unreachable. `ufw deny` is DROP.

When ICMP *is* the answer, its **source address** is the evidence: an unreachable coming
from an address other than the destination proves a middlebox nobody mentioned.

**Timing measures the client, not the path.** A RST that arrived in 0.2 ms was reported by
macOS `nc` only after 1.02 s, because macOS re-sends the SYN once before believing it.
Retry policy is per-OS too: Linux backs off 1, 2, 4, 8, 16, 32 s and gives up near 127 s
(`tcp_syn_retries=6`); macOS starts flat at 1 s. And `nc -w` on macOS does not apply to
`connect()`, so a DROPped port hangs past the timeout that was asked for.

### Two things `ss -tulpn` says that are easy to miss

**Read the bind address before the port.** `0.0.0.0:5432` is a database on the internet;
`127.0.0.1:5432` cannot be reached from the network at all, whatever the firewall does —
a stronger guarantee than a rule, because it does not depend on rules staying correct.

**`Recv-Q` and `Send-Q` change meaning with state.** On a `LISTEN` row they are the accept
queue: `Send-Q` is the backlog ceiling (`net.core.somaxconn`, 4096 by default) and `Recv-Q`
is how many completed connections are waiting for `accept()` — a rising `Recv-Q` there
means the application is too slow to accept and clients are being refused. On an `ESTAB`
row the same columns are bytes: unread by the application, and sent but unacknowledged.

Two owners on one socket is normal and means two different things: `sshd` + `systemd` on a
listener is socket activation (systemd opened the port and passed the fd in, so the port
survives a service restart); two `sshd` on a connection is privilege separation, the
unprivileged child having inherited the descriptor across `fork()`.

## DNS (day 15)


### Resolution is delegation, not lookup

There is no database being searched. There is a chain of referrals, and at every step the
answer is "ask those people instead".

A resolver seeing `lab.airscroll.net` for the first time asks a root server. The root does
not know the address and does not know what `airscroll.net` is. It knows one thing: who is
authoritative for `net`. It returns that — a referral, not an answer. The `net` servers
likewise return who holds `airscroll.net`. Only the third server asked is **authoritative**
and gives a real answer.

This is why DNS scales: no server holds more than its own branch of the tree, and nobody
needs to know a domain exists except whoever points at it directly.

### Three roles, worth not confusing

| Role | Does | Asks anyone? |
|---|---|---|
| **Authoritative server** | holds a zone, answers only about it | never |
| **Recursive resolver** | walks from the root, **caches** the result | yes, everyone |
| **Stub resolver** | the library on your machine: one question, one answer | its resolver only |

`dig +trace` imitates the recursive resolver — it walks from the root itself and prints
every referral. A plain `dig` is the stub's view: one question, one answer, the walk done
by somebody else and most likely done long ago and served from cache. That difference is
the whole reason `+trace` is the tool for "why does this resolve differently over there".

### A zone is not a domain

A **domain** is a name in the tree, with everything under it. A **zone** is an
administrative unit — the records one server is authoritative for — and it **ends where a
delegation begins**.

Delegate `lab.airscroll.net` to another nameserver and it becomes its own zone, leaving the
parent's. The domain `airscroll.net` still contains the whole subtree; one branch is simply
served elsewhere. So one domain can be many zones, and the boundary between them is an `NS`
record.

### Records

**`SOA`** — the presence of this record *is* the definition of "a zone starts here". Holds
the primary nameserver, the admin's email (with `@` written as a dot, a historical
oddity), a serial, and timers. Its **last field is the TTL for negative answers**, which
matters more than it looks.

**`NS`** — delegation, and it always exists in **two places**: in the parent zone as a
pointer ("not me from here down") and at the child zone's apex as an authoritative
statement ("this is me"). A mismatch between the two copies is a classic cause of "it
resolves for some people and not others".

**`A`** / **`AAAA`** — name to address, v4 and v6.

**`CNAME`** — name to **another name**, never to an address. Hard rule: if a name has a
CNAME it may have **no other record at all**. This is a protocol requirement, not a
convention.

**Why a CNAME cannot sit at the apex** follows from that rule and nothing else. A zone apex
is *required* to carry `SOA` and `NS` — otherwise it is not a zone. A CNAME demands that
nothing else exists. Two requirements that cannot both hold. Not a ban somebody invented;
arithmetic on the rules. (Providers offering "CNAME flattening" or `ALIAS` at the apex are
resolving the CNAME themselves and publishing the resulting `A` — the protocol is unchanged.)

**`MX`** — where mail goes, with a priority. Points at a **name**, never an address and
never a CNAME.

**`TXT`** — arbitrary text; SPF, DKIM and every domain-ownership proof live here.

**`CAA`** — which certificate authorities are **permitted** to issue certificates for this
name; CAs are obliged to check it before issuing. Note what kind of record that is: it does
nothing to help you get a certificate, it stops **somebody else** getting one for your name
through a different CA. A prohibition, not a capability.

### TTL is a promise to caches, and there is no undo

A TTL tells every resolver how many seconds it may keep an answer. Once one has taken it,
**there is no way to reach into that cache** — no API, no command, nothing. The record
lives exactly as long as was promised, in every resolver in the world, each running its own
timer from the moment it happened to ask.

Hence the only correct migration procedure: **lower the TTL a day before the switch**, not
at the switch. The reasoning is not obvious until said aloud — for a new low TTL to take
effect, the **old high one must expire first**. Lower it at the same moment the address
changes and every resolver that cached yesterday keeps serving the old address, with the
old TTL, for the full old duration. Nothing was accelerated.

**Negative answers are cached too.** `NXDOMAIN` is held for the time in the `SOA`'s last
field (1800 s on Cloudflare). So a freshly created record can fail to work not because it
is wrong but because a resolver remembers, correctly, that the name did not exist when it
asked. This is exactly the moment people start blindly re-creating a record that was right
the first time.

### Ubuntu: why `dig` and `resolvectl` honestly disagree

`/etc/resolv.conf` is a **symlink you do not own**, generated by `systemd-resolved` and
containing one server: `127.0.0.53`. Editing it by hand achieves nothing; it is rewritten.

The two listeners on port 53 seen on day 14 differ like this: `127.0.0.53` is the **stub
resolver** and applies all of resolved's logic — per-link DNS, domain routing, split-DNS —
while `127.0.0.54` is a bypass that forwards upstream without it.

So `dig` sends an ordinary DNS packet to `127.0.0.53`, while `resolvectl query` goes
through resolved's own API and applies things a DNS packet cannot express. When the two
disagree it is not a bug: they are two different questions.

### A TTL says where the answer came from

Round, full TTLs come **fresh from an authoritative server**. Odd, decreasing numbers are
the remainder of somebody's cache entry. One `dig +trace` shows both at once — the root
`NS` list arriving from the local resolver with a worn-down TTL, the `net` delegation
arriving from the root with a full 172800.

Free, always present, no extra command. Use it before believing any answer is current.

### "A resolver" is not one cache

`8.8.8.8` is anycast to many sites, and each site runs many resolver instances with
**independent caches**. `dig +nsid` shows which one answered:

```
NSID: gpdns-bud   TTL 300      <- cold instance, fetched fresh
NSID: gpdns-prg   TTL 300      <- different site entirely
NSID: gpdns-bud   TTL 181
NSID: gpdns-bud   TTL 289      <- TTL went UP: same label, different machine
```

A TTL rising between two consecutive queries to one address is proof of multiple caches,
not a bug — time does not run backwards.

Three consequences that matter more than the mechanism:

- **One query cannot verify a DNS change.** "It works now" is one instance out of an
  unknown number. Sample: `for i in $(seq 1 20); do dig +short <name> @8.8.8.8; done | sort | uniq -c`.
- **Two users of the same public resolver can see different answers at the same moment**,
  and neither is wrong.
- "Flush your DNS" aimed at a public resolver is close to meaningless; there is no way to
  address one instance.

A TTL is a **ceiling, not a floor**: a resolver must not exceed it, and may discard an
entry sooner under memory pressure. Never build on a cache forgetting early.

### The rollback that helps nobody

Measured, not theorised. A record at TTL 86400, warmed, then changed to a bad address:

```
authoritative:  192.0.2.1
8.8.8.8 x15:    13 x old      2 x new       <- two worlds, simultaneously
```

Then the standard incident reflex — restore the content, drop the TTL to 300:

```
authoritative:  178.151.120.5
8.8.8.8 x20:    18 x good     2 x 192.0.2.1  <- still broken, for up to 24 hours
```

The eighteen were never broken. The two that took the bad value keep it for the full
original TTL, because **the TTL that matters is the one in force when the record was
cached, not the one set afterwards**. Lowering it during an incident helps only the *next*
incident — which is exactly why the procedure is to lower it a day ahead. During the
outage the lever is not connected to anything.

Note the shape of the resulting failure: a minority of users cannot reach the service,
everyone else is fine, monitoring is green, and it cannot be reproduced from the operator's
side. Worse to diagnose than a total outage.

"DNS propagation" is a misleading term. Nothing propagates. Each cache independently runs
out its own timer.

### Reading the delegation in practice

- Parent and child both carry the zone's `NS` records, and **their TTLs may legitimately
  differ** (172800 from the `.net` registry, 86400 from Cloudflare). Each zone sets TTLs
  for its own records. Only a mismatch in **names** breaks resolution.
- **No glue for out-of-zone nameservers.** `elma.ns.cloudflare.com` gets no address in the
  `.net` referral because it lives in another zone and can be resolved normally. Glue is
  needed only when a zone's nameserver lives inside that same zone, which would otherwise
  be circular.
- **`aa` separates a source from a relay.** Cloudflare's answers carry it, a public
  resolver's do not. `dig` always prints it, which is one reason to prefer it to
  `nslookup`.
- **`WARNING: recursion requested but not available` is normal.** `dig` sets `rd` by
  default; an authoritative server never offers recursion. The role difference, printed.
- The EDNS buffer differs by server — 1232 from Cloudflare against 512 from Google. 1232 is
  the DNS flag day 2020 value, picked so a response fits the smallest realistic MTU without
  fragmenting. Day 14's PMTUD black hole was painful enough to move a protocol constant.
- Nameservers are anycast, and even their addresses vary between runs.
- A typo in `@server` gives `couldn't get address for ...` — a different **class** of
  failure: the query was never asked, because the server's own name would not resolve.

## TLS, HTTP, publishing (day 16)

### A certificate answers one question, and it is not the one people think

Verification is three mechanical checks and nothing else:

1. **Signature chains to a trusted root.** Leaf signed by an intermediate, intermediate by
   a root that is already in the client's trust store. A root is self-signed — its
   authority is not derived from anything, it is a decision by whoever built the store.
2. **The name matches, in `SAN`.** `CN` has been ignored since 2017. A wildcard covers
   exactly one label, and an IP address must be present as type `iPAddress`, not as text.
3. **The dates are current.** Which makes a wrong system clock look like a network outage.

What passes all three still does not mean the server is honest. A valid certificate says
**"somebody proved control of this name"**, nothing more. A phishing domain gets one in
thirty seconds. Identity and trustworthiness are different claims, and TLS only makes the
first.

The certificate itself is **public** — handed to every client, and published in
Certificate Transparency logs permanently. The private key is the only secret, and the CA
never sees it: what travels in the CSR is the public half. That asymmetry is the reason the
whole scheme is worth anything.

The operational side of CT worth remembering: every name you take a certificate for becomes
public forever. `crt.sh` is a ready map of a company's infrastructure — `staging.`,
`jenkins.`, `vpn-old.` — and reconnaissance starts there, not with scanning.

### Chain building and chain validation are different, and only one is uniform

Validating a chain is deterministic and identical everywhere. **Assembling** it is not — it
depends on what the client already has and how hard it will work:

| Stack | Missing intermediate |
|---|---|
| OpenSSL / GnuTLS (Linux curl, Go, Java, most clients) | fails: `unable to get local issuer certificate` |
| Browsers | usually succeed — cached intermediate, or fetched via the leaf's `AIA` |
| macOS Security.framework (**including Apple's `curl`**) | succeeds — fetches `AIA`, caches in the keychain |

This is the day's real lesson, and it is sharper than the rule it replaces. "Check with
`curl`, not a browser" is not enough, because **the behaviour belongs to the TLS stack, not
to the program**. A configuration serving only the leaf was verified as healthy from a
macOS laptop and rejected by every Linux client — every CI job, container, webhook and
server-to-server call.

The rule that survives: **verify from a stack that matches production.** A green result
from the wrong validator is worse than no result, because it closes the question falsely.

The historical proof that chain building is where things break: when `DST Root CA X3`
expired in 2021, no server changed by a byte, and the internet broke for old Android and
OpenSSL 1.0.2 — clients that could not construct an alternative path. **A certificate can
fail without anything on your side changing**, because half the conditions live in the
client.

### The four files, and why the wrong one is the obvious one

`cert.pem` leaf only · `chain.pem` intermediate only · `fullchain.pem` both · `privkey.pem`
the secret. `ssl_certificate` wants **`fullchain.pem`**.

`grep -c "BEGIN CERTIFICATE"` on the three prints 1, 1, 2 — the entire chain model as three
numbers.

The trap survives because everything points the wrong way: the file is called `cert.pem`,
the directive is called `ssl_certificate`, `nginx -t` passes, the service starts, and the
browser works. **The server side is entirely green.** Only a non-browser client on a
different machine disagrees.

A chain failure also leaves **nothing in `access.log`** — the handshake dies right after
the `Certificate` message, before any request exists. "Unreachable, but the access log is
silent" is the signature of TLS rather than of the application.

### What the handshake gives away

Before encryption can start, the client has to say who it wants. In cleartext:

- **SNI** — the hostname. Necessary because the server must pick a certificate *before* it
  can read the HTTP `Host` header, which is inside the channel that does not exist yet.
- **ALPN** — the protocol being negotiated (`h2`, `http/1.1`).
- Versions and cipher list — from which clients are fingerprinted.
- In TLS 1.2, **the server's certificate** as well; encrypted from 1.3 onward.

So encrypting the payload does not hide **whom you are talking to**. Anyone on the path
sees IP + SNI, which is a complete list of sites visited — the basis of corporate DPI and
state blocking, and the hole ECH exists to close (and ECH needs encrypted DNS too, or the
name simply leaks one layer down).

Connecting by IP address sends **no SNI at all** — RFC 6066 forbids a literal address
there. The server then falls back to its **default virtual host** and presents whatever
certificate that block holds, for a name the client never asked about. Hence an explicit
`default_server` stub on any machine hosting more than one site.

Two more properties worth being able to state:

- **Forward secrecy**: session keys come from an ephemeral key exchange, and the
  certificate's key only *signs*. Traffic recorded today stays unreadable even if the
  server key is stolen next year. TLS 1.3 removed the modes that lacked this.
- **0-RTT** sends data with the first packet and is **replayable** — safe only for
  idempotent requests, which is why it is off by default.

### ACME: the proof is bound to your account key

The challenge value is `token + "." + thumbprint(account key)`, so a token intercepted or
planted by someone else is useless — they cannot compute the response. The account key and
the certificate key are separate keys: one authenticates API calls, the other is the
server's identity.

| | HTTP-01 | DNS-01 |
|---|---|---|
| Proof | a file under `/.well-known/acme-challenge/` | a `TXT` at `_acme-challenge.<name>` |
| Requires | inbound **port 80** | API access to the DNS provider |
| Behind NAT | **impossible in principle** | works |
| Wildcard | impossible in principle | the only way |

HTTP-01 cannot be moved off port 80 by design — otherwise anyone holding an unprivileged
port could claim the name. And no HTTP request can prove control over *every* subdomain,
which is why wildcards are DNS-01 only.

The cost of DNS-01 is a token that can rewrite your zone. Scope it to one zone with edit
rights on records only, store it `0600` root-owned, and create the file already empty at
those permissions (`install -m 600 /dev/null`) rather than writing it and fixing the mode
afterwards.

Rate limits are real — **5 failed validations per hour** is the one that hurts — so staging
(`--dry-run`) first, always.

### Renewal is two events, and only the first one reports itself

`live/` holds symlinks into `archive/`, so the path in the web server config never changes
across renewals. The corollary is that the web server **holds the old file open and never
learns the symlink moved**: without a reload it serves the expired certificate until
someone notices, on day 90.

Hence a `deploy` hook — not `post`. The timer fires twice a day; over a certificate's life
that is ~180 attempts and one real renewal. `deploy` runs only when something actually
changed, and `$RENEWED_LINEAGE` tells it which certificate, so one site's renewal does not
reload another's service.

And the wider lesson, which generalises far past certbot: **its exit status means
"certificate obtained", not "the server is serving it".** It prints `Congratulations` over a
failed deploy hook, correctly, because those are different claims. Monitor **what the server
presents on the wire**, never what is on disk.

### Reverse proxy: a trust boundary and a multiplexer

TLS termination is the obvious job and the least interesting one. The rest:

- **Many applications behind one port 443**, split by `Host` and path. There is one port
  443 and ten applications.
- **Headers as a trust boundary.** Behind a proxy every client looks like `127.0.0.1`, so
  `X-Forwarded-For` / `-Proto` / `Host` carry the truth — and because clients send those
  headers too, they may be trusted **only** when set by your own proxy. Missing
  `X-Forwarded-Proto` is the classic infinite redirect loop: the app sees plain HTTP and
  redirects to HTTPS forever.
- **Buffering slow clients**, so one bad connection cannot occupy an application worker.
  That is a defence against Slowloris, not an optimisation.

In Kubernetes this exact role is the Ingress Controller, and an `Ingress` is a declarative
description of the same name-and-path rules. Doing it by hand once makes the manifest a
translation rather than a new language.

The proxy's own vocabulary, which is diagnosis rather than decoration:

- **`502`** — reached the upstream, got garbage or a reset. The application crashed or
  speaks the wrong protocol.
- **`503`** — the proxy knows there is no upstream to reach.
- **`504`** — connected, and the upstream did not answer in time. The application is alive
  but slow.

### HTTP generations each removed head-of-line blocking one layer down

**1.1**: one request at a time per connection; `keep-alive` saves the TCP+TLS handshake, but
a slow response blocks the queue. Reuse requires knowing where a response ends —
`Content-Length` or `Transfer-Encoding: chunked`. Pipelining was standardised and is dead,
because responses must return in request order.

**2**: many streams multiplexed over one TCP connection, binary framing, header compression.
`Host` becomes the `:authority` pseudo-header and all header names are lowercase by rule.
Solves blocking at the HTTP layer — but not at TCP's: one lost segment stalls **every**
stream, because TCP guarantees order.

**3**: therefore moves to QUIC over UDP, where ordering is per-stream and a loss in one
stream does not block the others. It also merges the transport and cryptographic handshakes
into one round trip.

Methods are described by two independent properties: **safe** (changes nothing:
`GET`, `HEAD`, `OPTIONS`) and **idempotent** (N times equals once: those plus `PUT`,
`DELETE`). This is not theory — proxies and clients silently retry idempotent requests after
a broken connection and refuse to retry `POST`.

### The errors, by layer

| Symptom | What arrived | Speed | Layer |
|---|---|---|---|
| `curl: (28)` timeout | nothing | slow | packet dropped — firewall `DROP` |
| `curl: (7)` refused | TCP **RST** | instant | host reached, **nothing listening** |
| `curl: (60)` issuer | TLS alert `unknown CA` | after handshake starts | chain incomplete |

**An instant failure is an answer; a slow one is silence.** An answer means you reached the
stack on the other side.

A listening socket and a firewall rule are independent conditions, and each tool sees only
its own: `ss` proves a process is listening and says nothing about reachability. "But I
opened 443" is usually true and usually not the problem.

### The route and the identity are independent

`curl --resolve` overrides **only** where the packet goes. The URL still supplies the SNI,
the `Host` header and the name that gets verified — so it is an honest test, not a
workaround. Connecting to the same address by IP instead fails, because now the URL names
the IP and that is what verification demands.

Which is the same fact from both sides: **the certificate certifies the name, not the
path.** That is deliberate — if DNS is hijacked and you land on the wrong server, name
verification is exactly what catches it.
