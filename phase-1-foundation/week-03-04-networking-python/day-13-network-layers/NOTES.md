# Day 13 — Network layers, addressing, routing

Date: 2026-09-01
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

First quiz under the new interleaving rule — three questions from three different
domains rather than three from the same recent block. All three correct.

1. Day 9: `set -euo pipefail`, and `foo | bar` where `foo` fails but `bar` succeeds —
   why would the script continue without `pipefail`? **Correct.** A pipeline's exit
   status is its *last* command's, so `-e` sees success and moves on. Sharpened:
   `pipefail` makes the status that of the **rightmost command that exited non-zero**,
   not the first failure — indistinguishable in a two-stage pipe, visible in `a | b | c`.
2. Day 5: a daemon that forks into the background declared as `Type=simple` — what does
   systemd consider the service's process, and what breaks? **Correct.** systemd treats
   the process it spawned itself as the main one; that process forks and exits 0, which
   reads as successful completion, so `Restart=on-failure` never fires.
   **The question's premise was wrong and worth recording:** the unit does not sit at
   `active (running)` — it goes to `inactive (dead)`, and the surviving forked child is
   killed by the default `KillMode=control-group`. `active (running)` alongside
   misbehaving restarts is a *different* defect: `Type=forking` with a missing or wrong
   `PIDFile=`, where systemd tracks a PID that is not the daemon — believing a dead
   service healthy, or restarting a healthy one whose tracked PID vanished. The symptom
   separates the two diagnoses.
3. Day 2: a deleted 20 GB log, `df` unchanged — what happened, how to find it, how to
   reclaim without killing the process? **Correct.** `sudo lsof +L1` (link count < 1 =
   deleted but still open) gives the PID and fd; `: > /proc/<pid>/fd/<N>` or
   `truncate -s 0` on that path truncates the real inode, because the kernel resolves an
   open of `/proc/<pid>/fd/N` to the inode rather than to the vanished path.
   Not said, and it matters: the process keeps writing at its **old offset**, so without
   `O_APPEND` the file goes sparse and `df` loses the space again as it fills. This stops
   the bleeding; the fix is rotation (`copytruncate`, or SIGHUP so the daemon reopens).

## What I did

Interface and routing survey on the Pi: `ip -br addr`, `ip addr show`, `ip -s link`,
`ip route`, `ip neigh`, and `ip route get` against a remote address, a segment neighbour
and loopback.

Findings worth keeping:

- **Both interfaces sit on the same subnet.** `eth0` is `192.168.0.197/24` and `wlan0` is
  `192.168.0.168/24` — one broadcast domain, not two networks. Confirmed by the ARP cache:
  `192.168.0.1` resolves to the same MAC (`f0:b4:d2:31:d3:c8`) through both interfaces.
  So the metric decides at *every* prefix length here, not just at the default route —
  each of `/0` and `/24` is duplicated across the two interfaces, and `eth0` (metric 100)
  wins all of them.
- **A `/32` host route to the gateway**, installed by the DHCP client:
  `192.168.0.1 dev eth0 proto dhcp scope link`. Three entries match `192.168.0.1` — this
  one, the `/24`, and the default — and the longest prefix takes it. Longest-prefix-match
  visible in the wild rather than in an example.
- **The link counters prove the metric decision.** `wlan0` has received 14.9 MB but sent
  only 1.1 MB, against 39.4 MB / 7.9 MB on `eth0`. Being in the same segment it hears every
  broadcast and multicast, so it receives; being never selected by the routing table, it
  barely transmits.
- `ip route get` shows the decision, not the table. For `8.8.8.8` it prints
  `via 192.168.0.1`; for the gateway itself the `via` is simply absent — a segment
  neighbour is ARPed directly, with no next hop. Loopback resolves out of the `local`
  table, which `ip route` never displays.
- The Pi's own OUI is visible on both NICs: `b8:27:eb` (Raspberry Pi Foundation), with
  differing device bytes.

## What broke

Deliberate: removed the default routes and observed the failure mode.

**The first attempt did not break anything, which was itself the lesson.** Deleting
`default ... dev eth0` alone changed nothing visible — the kernel simply fell through to
the second default route on `wlan0` at metric 600. A machine with two default routes
degrades silently; losing one path is invisible until the second is gone too. Both had to
be removed to produce a symptom.

With both gone, `ping google.com`:

```
ping: connect: Network is unreachable
```

Two things this proves, neither of which is obvious from the message alone:

1. **The error names the syscall that failed: `connect:`.** The route lookup failed inside
   the kernel and returned `ENETUNREACH` immediately; no packet was ever put on the wire.
   That is why the failure is instant rather than a timeout — there is nothing in flight to
   wait for. A timeout means the opposite: the packet left and nobody answered. Same
   "it doesn't work", opposite mechanisms, and the response time tells them apart.
2. **DNS still resolved, with the internet entirely unreachable.** The name was turned into
   an address before `connect()` was ever reached — had resolution failed, the error would
   have been `Temporary failure in name resolution` instead. The resolver is
   `192.168.0.1`, a neighbour in the segment, and the `192.168.0.0/24 scope link` route was
   never deleted, so the query went out by ARP directly and never needed a gateway.

The second point is the transferable one: **"DNS works" says nothing about reachability
past the local segment.** Resolving a name and getting an address is a routine reason to
wrongly cross the network off the list of suspects.

## What surprised me

- That a second default route silently absorbs the loss of the first. Redundancy hid the
  breakage — which is what redundancy is for, and exactly why the failure of the first path
  can go unnoticed until the second one fails too.
- That name resolution survived the loss of all internet connectivity, purely because the
  resolver happens to live in the same broadcast domain.

## Checkpoint answers

Answered aloud before writing. Three correct, one partial, one forgotten.

1. `192.168.1.10/24` vs `/16` — the practical difference? **Correct.** The mask sets where
   the machine draws the boundary of "local", and therefore whether it ARPs a destination
   directly or hands it to the gateway; 256 addresses against 65536. Sharpened: the damage
   from an over-wide mask is not the size but that the host treats `192.168.50.7` as a
   neighbour and ARPs into the void *instead of using the gateway it has*. The broadcast
   address moves too, from `192.168.1.255` to `192.168.255.255`.
2. Two machines in one segment, addresses correct, ping fails — what first? **Partial.**
   `ip neigh` was right, and right for the right reason: it splits the problem in half.
   `INCOMPLETE`/`FAILED` means the question went unanswered — look below IP: the masks on
   *both* sides, same switch/VLAN, link state. A resolved MAC means layer 2 is healthy and
   the problem is at or above IP — most often the target's firewall dropping ICMP, since
   ping tests willingness to answer ICMP, not reachability. Two field favourites: a mask
   that differs on one side only (A thinks B is local, B thinks A is remote, traffic flows
   one way), and a duplicate IP.
3. Why does the default route have prefix `/0`, and how does that relate to being applied
   last? **Correct.** Longest-prefix-match, `/0` as the last resort. Sharpened: it is last
   by arithmetic, not by policy — zero fixed bits is the shortest possible prefix, so it can
   only win when nothing else matched. There is no "default" flag doing the ordering.
4. What does ARP do and how can its cache be poisoned? **Forgotten.** Answered "through a
   change of network or router", which is *staleness*, a different phenomenon. Stale: the
   information was true and expired — swap a router, the old MAC lingers until the timer
   clears it. **Poisoned:** the information is deliberately false. ARP has no authentication
   at all, so any host in the segment can answer for any address, and can announce itself
   unsolicited (gratuitous ARP). The victim caches the lie and sends traffic to the
   attacker's MAC. Identical symptom — the wrong MAC in the cache — opposite causes:
   expired truth against injected falsehood.
5. Why is the post-break failure instant rather than a timeout? **Correct.** No matching
   route, so nothing can be sent. See `What broke` for the syscall-level detail.

## Open questions

- VLANs: a switch can be partitioned into several broadcast domains on one physical box.
  Came up while defining "segment"; not covered by the weeks 3-4 curriculum, so parked.
- IPv6 link-local addresses are derived from the MAC by EUI-64: `b8:27:eb:aa:32:27`
  becomes `fe80::ba27:ebff:feaa:3227` — MAC split in half, `ff:fe` inserted, the seventh
  bit flipped (`b8` -> `ba`). Noticed in the day's output; IPv6 is not on the weeks 3-4
  curriculum.
- Two IPv6 routers are advertising on this segment: the neighbour cache holds three
  `router` entries resolving to two MACs (`f0:b4:d2:31:d3:c8` and `a8:51:ab:9e:ec:28`),
  which is where the two ULA prefixes on each interface come from (`fddd:9beb:...` and
  `fd01::`). Worth understanding before the lab is exposed to the internet.
- Policy routing: Linux keeps several routing tables (`local`, `main`, `default`) and
  `ip rule` decides which is consulted. Surfaced because `ip route get 127.0.0.1` resolves
  out of `local`, which `ip route` never shows. Also outside the weeks 3-4 scope.
