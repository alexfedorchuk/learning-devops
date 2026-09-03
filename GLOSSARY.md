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
