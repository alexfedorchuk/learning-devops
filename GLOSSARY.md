# Glossary

The canonical vocabulary for this repository. One term, one definition, one preferred
name — used consistently in every `NOTES.md`, cheat sheet and artifact README.

This is the third reference document, and it answers a different question from the
other two:

| Document | Question it answers |
|---|---|
| `reference/commands.md` | How do I do X **right now**? |
| `reference/week-N-cheatsheet.md` | How does X **work**? |
| `GLOSSARY.md` | What does X **mean**? |

It is deliberately repository-wide rather than per-week: terms recur across blocks,
and only a single file catches collisions — LVM's `PV`/`VG`/`LV` against Kubernetes'
`PersistentVolume` being the one already visible on the horizon.

## How entries are written

- **A term is added only once it can be used correctly**, not when it is first met.
  Compressing a concept into two sentences is itself the evidence of understanding,
  which makes this file a record of progress as much as a reference.
- **Definitions are written from memory first**, then corrected. A definition that was
  looked up and transcribed teaches nothing.
- **Tight**: one or two sentences. What the term *is*, not how to use it — usage lives
  in `commands.md`.
- **Opinionated**: where several names exist for one concept, one is chosen and the
  rest are listed under `_Avoid_`. This matters twice over here, since English is a
  deliberate second track: the glossary fixes the correct term, not the first one that
  comes to mind.
- **Self-referential**: once a term is defined here, it is used inside other
  definitions rather than re-explained.
- **Revised in place** when understanding deepens. No stale entries, no append-only
  history.
- **Scoped to what has been covered.** An entry stays at the depth the curriculum
  reached; questions parked in a day's `Open questions` stay parked.

## Terms

### Processes and signals

**Process**:
The kernel's unit of resource ownership: one address space, one file descriptor table,
one set of credentials, identified by a PID. The program running inside it is only the
current contents — `exec()` replaces that program without creating a new process.
_Avoid_: Running program, task, app

**Signal**:
An asynchronous notification delivered by the kernel to a process, carrying a number
and nothing else. Unlike a pipe or a socket it requires no cooperation from the
receiver: it interrupts the process at its next safe point and runs either a handler
the process installed or the kernel's default disposition for that number.
_Avoid_: Message, event, interrupt

**Job**:
A shell's handle on the process group started from one command line — what `jobs`,
`%1`, `fg` and `bg` address. Job control gives each job its own process group so a
terminal can signal one pipeline without touching the others; it is enabled by default
only in interactive shells, which is why a script's `&` behaves differently from the
same `&` typed by hand.
_Avoid_: Background task, background process

### Memory

**Page**:
The fixed-size unit, ~4 KB here, in which the kernel manages memory. Everything above
it — copy-on-write, VSZ, RSS, a shared library counted inside several processes at
once — is per-page bookkeeping in each process's page table.
_Avoid_: Memory block, chunk, segment

**VSZ (Virtual Set Size)**:
The total address space a process has mapped, counting pages never touched, mapped
files, and the full extent of every shared library. A promise rather than a cost: a
large VSZ occupies no RAM by itself.
_Avoid_: Virtual memory used, allocated memory

**RSS (Resident Set Size)**:
The share of a process's pages currently resident in physical RAM. Nearer the truth
than VSZ, but still an overstatement of what the process alone costs, because pages
shared with other processes are counted in full against each of them.
_Avoid_: Real memory usage, actual memory

### Storage

**Block device**:
A device the kernel presents as an addressable array of fixed-size blocks, readable and
writable at arbitrary offsets — disks, partitions, logical volumes. Its counterpart is
a character device, a byte stream with no seekable structure.
_Avoid_: Disk, drive, storage device

**Loop device**:
A block device backed by a regular file, so the kernel lets that file be partitioned,
formatted and mounted exactly like a disk. How an ISO image mounts, and how container
and VM images are backed.
_Avoid_: Virtual disk, fake disk, mounted file

**LVM (Logical Volume Manager)**:
A layer between block devices and filesystems that turns fixed disks into a resizable
pool. Its purpose is change without downtime — grow a volume, add a disk to a group —
which a partition, pinned to one boundary on one disk, cannot offer.
_Avoid_: Partition manager, disk manager

**PV / VG / LV**:
The three links of the LVM chain: a **physical volume** is a block device handed over
to LVM, a **volume group** is a pool of physical volumes, and a **logical volume** is a
slice of a group — the thing a filesystem is actually created on.
Ambiguity: in this repository `PV` always means LVM's physical volume. Kubernetes'
`PersistentVolume` shares the abbreviation and means something unrelated, so it is
always written out in full.

**Inode**:
The on-disk record holding everything about a file except its name and its contents:
type, permissions, owner, timestamps, link count, and the pointers to its data blocks.
Their number is fixed when the filesystem is created, which makes inodes a budget
separate from free space.
_Avoid_: File header, file record, metadata block

**Directory entry**:
The name-to-inode mapping stored inside a directory, and the only place a filename
exists. Hence `rm` being a directory operation: it removes the entry and decrements the
inode's link count, while the data itself survives until that count and the number of
open file descriptors both reach zero.
_Avoid_: File entry, filename

### Networking

**Hop**:
One step of layer-3 forwarding: a packet's passage from one router to the next. Each
forwarding router decrements the IP header's TTL by one, so "the sixth hop" means the
sixth router on the path; switches are not hops, because they act at layer 2 and never
touch the IP header.
_Avoid_: Node, step, jump

**Network segment**:
A broadcast domain: the set of devices reachable from one another by a layer-2 frame,
with no router in between, so that a broadcast from any of them reaches all of them.
This is the boundary ARP works inside.
Ambiguity: a segment is layer-2 reality (who actually hears a broadcast), while a
**subnet** is layer-3 configuration (what the netmask claims). They are deliberately
made to coincide, but nothing enforces it, and a mask that disagrees with the real
broadcast domain is what makes a host ARP into the void for a destination that is in
fact behind a router. TCP reuses the word "segment" for its own unit of data at layer 4;
throughout this repository "segment" means the broadcast domain unless TCP is named.
_Avoid_: LAN, subnet, network

**ARP (Address Resolution Protocol)**:
The lookup from an IP address to the MAC address that owns it, performed by broadcasting
the question into the local [[network-segment]] and caching the unicast answer. It has no
authentication of any kind — any host can answer for any address, and a host may announce
itself unsolicited (gratuitous ARP), which is both how IP failover works and how spoofing
works.
_Avoid_: MAC lookup, address discovery

**CIDR (Classless Inter-Domain Routing)**:
Writing an address together with a prefix length — `192.168.1.10/24` — where the prefix
length is the count of leading bits fixed as the network, leaving the rest for hosts. A
host ANDs an address with a mask to get its network, and compares its own network against
the destination's to decide local delivery versus the gateway. More fixed bits means a
smaller, more specific range, which is why the longest matching prefix wins a routing
lookup and why the default route, `/0`, loses to everything.
_Avoid_: Subnet mask notation, slash notation

**MAC address**:
The 48-bit hardware address identifying an interface within its
[[network-segment]] — first three bytes the manufacturer's OUI, last three the device.
The space is flat, with no hierarchy to aggregate on, which is precisely why layer 3
exists; and because a router rebuilds the frame rather than forwarding it, a MAC address
never leaves its own segment.
_Avoid_: Hardware address, physical address, adapter ID

**Next hop**:
The router a packet is handed to when its destination is not on the local segment,
shown as `via <address>` in a route. It is the next hop's MAC that gets resolved by
[[arp-address-resolution-protocol]] and written into the frame — never the final
destination's, which lives in another segment entirely.
_Avoid_: Gateway (except for the default route specifically), router address

**Default route**:
The route matching every destination, written `0.0.0.0/0` or `default`, used when nothing
more specific matches. It is chosen last not because of a flag but because zero fixed bits
is the shortest possible prefix, and routing lookup takes the longest match.
_Avoid_: Gateway, catch-all route

**Socket**:
A kernel object representing one endpoint of a communication, addressed by a file
descriptor and therefore subject to every rule that governs descriptors — inherited
across `fork()`, counted against `ulimit -n`, closed only by the owning process. A
listening socket holds one half of an address pair; each accepted connection becomes a
separate socket of its own.
_Avoid_: Port, connection, channel

**Four-tuple**:
The four values that identify a TCP or UDP connection to the kernel — source address,
source port, destination address, destination port — which is why one server port can
carry tens of thousands of simultaneous connections: uniqueness comes from the client's
half. A port is an address to reach, never an identifier of a connection.
_Avoid_: Connection ID, socket pair, port

**Ephemeral port**:
The source port a kernel allocates from a free pool when a client connects without
naming one. The pool is an operating-system choice, not part of the protocol — Linux
uses 32768–60999 (`net.ipv4.ip_local_port_range`), macOS 49152–65535 — and exhausting it
limits how many connections *one client* can hold to *one* server address and port.
_Avoid_: Random port, high port, client port

**Backlog**:
The ceiling on how many fully established connections the kernel will hold for a
listening socket while waiting for the application to call `accept()`, shown as `Send-Q`
in `ss` on a `LISTEN` row and capped by `net.core.somaxconn`. A backlog that fills means
the application is too slow to accept, and new clients are refused.
_Avoid_: Queue, connection limit, somaxconn

**MTU (Maximum Transmission Unit)**:
The largest packet a given link will carry, 1500 bytes on ordinary Ethernet. It is a
property of one link, not of a path, so neither end of a connection knows the smallest
MTU between them; discovering it depends on routers returning ICMP `fragmentation
needed`, and a firewall that blocks that ICMP turns the mismatch into silent loss of
full-sized packets only.
_Avoid_: Packet size, frame size

**MSS (Maximum Segment Size)**:
The largest payload a TCP sender will put in one segment, announced by each side in its
SYN and derived from its **own** first link's [[mtu-maximum-transmission-unit]] — 1460
from a 1500-byte MTU, less 20 bytes of IP and 20 of TCP header. The usable figure drops
further by the size of the options carried on every packet, which is why timestamps
reduce it to 1448.
_Avoid_: Payload size, window

**TIME_WAIT**:
The state held for 60 seconds by the side that closed a connection **first**, so that a
lost final ACK can still be answered and so stale packets of the old connection cannot
be delivered into a new one reusing the same [[four-tuple]]. It expires on a kernel
timer and is a picture of load, not a fault.
_Avoid_: Leak, stuck connection, lingering socket

**CLOSE_WAIT**:
The state of a socket whose peer has sent FIN and whose own application has not yet
called `close()`. The kernel has no timer for it and never can — the application still
holds the right to write — so an accumulation is always an application defect and always
a file-descriptor leak, cleared only when the process closes the socket or dies.
_Avoid_: Hung connection, network problem, stale socket

**Zone**:
The administrative unit of DNS: the set of records one server is authoritative for, marked
at its top by an `SOA` record and **ending wherever a delegation begins**. A domain is a
name in the tree; a zone is who answers for part of it, so one domain may be several zones.
_Avoid_: Domain, DNS entry, namespace

**Delegation**:
Handing responsibility for a subtree of the name space to another set of nameservers, done
with `NS` records that exist in two places at once — in the parent as a pointer and at the
child's apex as an authoritative claim. Resolution is a chain of these referrals rather
than a search, which is why no server needs to know a name exists except the one pointing
directly at it.
_Avoid_: Pointing, forwarding, redirect

**Authoritative server**:
A server holding a [[zone]] and answering only about it, never querying anyone else. Its
replies carry the `aa` flag, which is what separates a source from a relay, and it offers
no recursion — so `dig`'s "recursion requested but not available" against one is normal.
_Avoid_: DNS server, nameserver (when a recursive resolver is meant), master

**Recursive resolver**:
The server that performs the whole walk from the root on a client's behalf and **caches**
what it learns — `1.1.1.1`, `8.8.8.8`, an ISP's or a router's. It is not one machine: a
public one is anycast across sites, each running many instances with independent caches, so
a single query can never confirm what "the resolver" is serving.
_Avoid_: DNS server, nameserver, DNS provider

**Stub resolver**:
The client-side library or local service that asks one question of its configured
[[recursive-resolver]] and takes the answer — on Ubuntu, `systemd-resolved` listening on
`127.0.0.53`. It performs no delegation walk of its own.
_Avoid_: Client, local DNS, resolver

**TTL (Time To Live)**:
The number of seconds a record may be cached, published by the zone that owns it. It is a
**ceiling, not a floor**: a cache must not exceed it and may discard sooner, and there is no
mechanism anywhere to make a cache forget early. The value that governs a cached record is
the one in force when it was fetched, not whatever is published afterwards.
_Avoid_: Expiry, cache time, refresh interval

**Negative caching**:
Caching the *absence* of a name. An `NXDOMAIN` is proved by returning the zone's `SOA`
rather than an answer, and the `SOA`'s last field sets how long that non-existence may be
remembered (1800 s on Cloudflare) — which is why a freshly created record can fail for
reasons that have nothing to do with the record.
_Avoid_: NXDOMAIN cache, failed lookup cache

**Anycast**:
Announcing one address from many locations so routing delivers each client to the nearest.
The root servers, TLD servers and public resolvers all use it, which is why the same address
answers with different latencies, different instance identifiers (`dig +nsid`) and different
cache contents depending on where the query entered the network.
_Avoid_: Load balancing, CDN, round-robin

**NAT (Network Address Translation)**:
Rewriting addresses and ports in a packet in flight, plus the table that records each
rewrite so the reply can be rewritten back. The row is created by the **outbound** packet,
which is why an unsolicited inbound packet has nowhere to go — not because policy forbids
it, but because nothing identifies which internal host was meant. Port forwarding is that
same row installed by hand; the security people attribute to NAT is a side effect of the
table, never a design goal.
_Avoid_: Firewall, masking, IP hiding, port mapping

**CGNAT (Carrier-Grade NAT)**:
NAT performed a second time inside the ISP's network, so a subscriber's router holds a
private WAN address (`100.64.0.0/10` per RFC 6598, or ordinary RFC 1918 space) rather than a
public one. Inbound connections then cannot be arranged at all: a forwarding rule on your
own router is well-formed and never reached, because the packet is discarded one NAT
earlier, in a table you do not own.
_Avoid_: Double NAT, shared IP, ISP firewall

**Connection tracking (conntrack)**:
The kernel table recording every connection passing through a machine, against which each
packet is classified `NEW`, `ESTABLISHED`, `RELATED` or `INVALID`. A row is a **pair of
tuples** — how the packet leaves and how the reply must return — so a reply tuple that is
not an exact mirror of the original is [[nat-network-address-translation]] made visible. In Linux the translation is
stored as an attribute of the row, which makes NAT and stateful filtering one mechanism read
two ways. UDP and ICMP are given invented state with timeouts.
_Avoid_: Session table, NAT table, state table

**Stateful firewall**:
A packet filter that decides from [[connection-tracking-conntrack]] rather than from the
packet alone, so a single `ESTABLISHED,RELATED → ACCEPT` rule admits the replies to every
outbound connection. Without it, permitting replies means permitting all high ports, since
source ports are random — which is why stateless filters were unusable in practice. The
corollary is that an existing session survives any rule change, so **only a new connection
tests a rule**.
_Avoid_: Firewall, packet filter, iptables

**ECMP (Equal-Cost Multi-Path)**:
Spreading traffic across several routes of equal cost by hashing each flow's headers, so
that a flow stays on one path while different flows do not. It is why one `traceroute` hop
answers from several addresses — each probe varies the destination port and therefore
hashes differently — and why a real connection, whose 5-tuple is fixed, uses exactly one of
those paths, possibly one the trace never showed.
_Avoid_: Load balancing, round-robin, multipath

### TLS and HTTP

**X.509 certificate**:
A signed statement binding a public key to one or more names, with a validity window. It is
**public**, not a secret — it is handed to every client that connects and published in
Certificate Transparency logs. The secret is the private key that never leaves the server.
The format is not TLS-specific; the same structure signs code and email.
_Avoid_: SSL certificate, security certificate, key

**SAN (Subject Alternative Name)**:
The extension listing the names a certificate is valid for. It is the **only** field
checked — `CN` has been ignored by clients since 2017. A wildcard entry covers exactly one
label (`*.example.com` matches `a.example.com`, not `a.b.example.com` and not
`example.com`), and an IP address must appear as type `iPAddress`, not as a name.
_Avoid_: CN, common name, domain field

**Certificate chain**:
Leaf → intermediate(s) → root. A server must send the leaf **and every intermediate**; the
root must already be in the client's trust store, so sending it is useless. Assembling the
chain (*chain building*) is client-dependent — some stacks fetch a missing intermediate via
the leaf's `AIA` extension, OpenSSL-based ones do not — while *validating* it is uniform.
That asymmetry is why one client accepts what another rejects.
_Avoid_: certificate bundle, CA chain, full certificate

**Trust store**:
The set of root certificates a client considers authoritative, shipped by the OS or the
browser. Roots are self-signed: their trust is not derived, it is a decision by whoever
built the store. Which store is in use decides verification — on macOS, `curl` uses the
system evaluator and behaves like Safari; on Linux it reads a static bundle.
_Avoid_: CA bundle, root certs, certificate authority

**CAA (Certification Authority Authorization)**:
A DNS record naming which CAs may issue for a domain, checked **by the CA at issuance** and
never by a client at connection time. The CA walks up the tree from the requested name and
stops at the first record found. Absence means every CA is permitted — it is an opt-in
restriction, not a whitelist.
_Avoid_: certificate whitelist, CA policy record

**ACME**:
The protocol (RFC 8555) by which a client proves control of a name and receives a
certificate without human involvement. The proof is bound to the client's **account key**,
so a challenge token alone is useless to anyone else. The account key and the certificate's
key are different keys.
_Avoid_: Let's Encrypt API, certbot protocol

**HTTP-01 / DNS-01**:
The two ways of proving control of a name. HTTP-01 serves a token at
`http://<name>/.well-known/acme-challenge/` and therefore requires inbound **port 80** —
impossible behind a NAT you do not control. DNS-01 publishes a `TXT` at
`_acme-challenge.<name>`, works from anywhere because the proof travels into the zone
rather than to the machine, and is the **only** way to obtain a wildcard.
_Avoid_: HTTP validation, DNS validation, domain verification

**SNI (Server Name Indication)**:
The hostname the client puts in `ClientHello`, in **cleartext**, so the server can choose a
certificate before any encrypted channel exists. It is the reason many sites share one IP,
and the reason encryption does not hide *which* site you visit. A literal IP address may
not be sent as SNI, so connecting by address sends none at all and the server falls back to
its default virtual host.
_Avoid_: hostname header, Host, domain in the request

**TLS termination**:
Decrypting TLS at a boundary — typically a reverse proxy — and passing plain HTTP to the
application behind it. The application never handles certificates and does not know TLS
exists. This is what makes one certificate serve many applications.
_Avoid_: SSL offloading, decryption, HTTPS proxying

**Reverse proxy**:
A server that accepts connections on behalf of applications behind it, chosen by name and
path. It is a **trust boundary and a multiplexer**: it terminates TLS, puts many
applications on one port 443, sets and sanitises `X-Forwarded-*` so the application sees
real clients rather than `127.0.0.1`, and buffers slow clients so one bad connection cannot
occupy an application worker. A forward proxy is the mirror image — it acts for the client,
who knows it is there.
_Avoid_: load balancer, gateway, proxy

**Forward secrecy**:
The property that recording traffic today and stealing the server's private key later still
does not decrypt the recording, because session keys come from an **ephemeral** key exchange
and the certificate's key only signs. TLS 1.3 removed the key-exchange modes that lacked it.
_Avoid_: encryption strength, perfect security
