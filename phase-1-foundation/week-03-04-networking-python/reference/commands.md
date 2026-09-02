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
