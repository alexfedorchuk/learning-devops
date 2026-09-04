# Week 3 cheat sheet — networking

Compressed from days 13 onward. Full write-ups and command history live in each day's
`NOTES.md`; commands for mid-task lookup live in `commands.md`; term definitions live in
the repository's `GLOSSARY.md`. This is the version to reread weeks later: mechanisms and
why they bite.

Built up as the week lands; days 15-17 are still to come.

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
