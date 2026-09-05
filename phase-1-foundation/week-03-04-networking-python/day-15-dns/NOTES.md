# Day 15 — DNS

Date: 2026-09-05
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64); zone hosted at Cloudflare

## Re-quiz (spaced retrieval)

The day opened by paying day 14's debt — its four checkpoint questions, which are recorded
in `day-14-tcp-sockets/NOTES.md` rather than duplicated here. Two correct, one partial, one
forgotten, and the forgotten one was the topic day 14 never practised.

One interleaved question from a distant domain:

- Day 9: why does `set -e` **not** stop a script when the failing command sits inside `if`
  or to the left of `&&`? **Partial** — the shape was right ("it is part of a test"), the
  mechanism was not. Sharpened: `-e` fires only when a failure is **unhandled**; in `if`,
  `while`, `until`, after `!`, and in every position of an `&&`/`||` chain but the last,
  the status is *consumed* by the shell as an answer, so it is not a failure. The trap that
  follows: suppression covers the **whole subtree**, so `if my_function; then` runs every
  command inside that function with `-e` effectively off. Second classic of the same day:
  `local x=$(cmd)` always returns 0, because the status belongs to `local`.

## What I did

**Corrected a false premise in the plan before anything else.** The week's curriculum was
built on `lab.airscroll.app`, described as an empty domain waiting to be filled. It is not
empty — it does not exist. The authoritative server for the `.app` zone answers `NXDOMAIN`
with the `aa` flag set, which is proof from the registry itself. The real domain is
`airscroll.net`, live and delegated to Cloudflare. `CLAUDE.md`, `README.md` and
`CURRICULUM.md` were moved to `airscroll.net` with the correction recorded in place.

Incidentally that first check *was* the day's model: asking a TLD server directly, rather
than a resolver, is exactly step two of a delegation walk.

1. `dig +trace lab.airscroll.net`, twice, several hours apart — the full walk from root to
   `net` to Cloudflare.
2. `ls -l /etc/resolv.conf`, `resolvectl status`, `resolvectl query` against `dig +short`.
3. Compared the parent's copy of the `NS` records (from the `.net` registry) with the
   child's own (`dig airscroll.net NS @elma.ns.cloudflare.com`).
4. Created a Cloudflare API token scoped `Zone:DNS:Edit` on this one zone, read into the
   shell with `read -rsp` so it never reaches `~/.bash_history`.
5. Created `lab.airscroll.net` — `A 178.151.120.5`, TTL 300, `proxied: false` — via the
   API at 19:37:32 EEST.
6. Attempted the negative-caching experiment: primed `8.8.8.8` with an `NXDOMAIN` at 19:21
   and deliberately left `1.1.1.1` untouched as a control.
7. When that failed, probed `8.8.8.8` with `dig +nsid` to find out why.
8. Break-it on a **separate** name, `ttltest.airscroll.net`, at TTL 86400.

Findings worth keeping:

- **A TTL says where the answer came from.** In one `+trace`, the root `NS` list arrived
  with TTL `654` and the `net` delegation with `172800`. Round numbers are a full TTL
  served fresh by an authoritative server; an odd, decreasing number is the remainder of
  somebody's cache entry. The same list read `24447` hours earlier and `654` later — a
  cache visibly counting down. This costs nothing to use and is present in every output.
- **Parent and child `NS` records match in names and differ in TTL** — 172800 from the
  `.net` registry, 86400 from Cloudflare. Both are correct: each zone sets TTLs for its own
  records, and parent and child are two different zones that happen to carry the same
  content. Only a mismatch in *names* breaks resolution.
- **The `aa` flag separates a source from a relay.** Cloudflare's answer carried `aa`;
  Google's did not. `dig` shows it always, which is one of the reasons to prefer it to
  `nslookup`.
- **`WARNING: recursion requested but not available` is not an error.** `dig` sets `rd` by
  default and an authoritative server never offers recursion — the role difference,
  printed.
- **EDNS buffer: 1232 from Cloudflare, 512 from Google.** 1232 is the DNS flag day 2020
  value, chosen so a response fits the smallest realistic MTU without fragmenting. Day 14's
  PMTUD black hole was painful enough that the DNS standard was tuned around it.
- **Anycast in the output**: `randy.ns.cloudflare.com` answered from `172.64.35.109` on one
  run and `108.162.195.109` on another.
- **The resolver here is the home router**, `192.168.0.1` — the belated explanation for day
  13, where DNS kept working after every default route was deleted.
- `DNS Domain: Dlink`, a search domain handed out by DHCP: unqualified names get the suffix
  appended, which is a good source of baffling lookups.
- The router's IPv6 DNS address `fe80::f2b4:d2ff:fe31:d3c8` is the EUI-64 form of its MAC
  `f0:b4:d2:31:d3:c8` from day 13 — halved, `ff:fe` inserted, seventh bit flipped
  (`f0` → `f2`). Day 13's parked note, confirmed on a second device.

## What broke

### The negative-caching experiment failed, and the failure was the day's best material

At 19:21 `8.8.8.8` returned `NXDOMAIN` for `lab.airscroll.net` with a negative TTL of 1800,
so it should have kept saying "no such name" until roughly 19:51. The record was created at
19:37:32. At 19:38:38 — sixty-six seconds later — `8.8.8.8` returned the correct address.

The hypothesis was wrong in its premise, not its arithmetic: **"8.8.8.8" is not a
resolver.** `dig +nsid` proved it in two layers:

```
NSID: gpdns-bud   TTL 300
NSID: gpdns-prg   TTL 300
NSID: gpdns-bud   TTL 300
NSID: gpdns-bud   TTL 181
NSID: gpdns-bud   TTL 289
```

Anycast spread the queries across sites — Budapest and Prague. And the last two lines are
the stronger proof: **the same NSID, with the TTL rising from 181 to 289.** Time does not
run backwards, so those two answers cannot have come from one cache. `gpdns-bud` labels a
site, not a machine, and behind it are many resolvers with independent caches.

So the negative entry never expired early. A different instance simply had never heard of
the name. Three consecutive `300`s in that sample are three cold instances fetching from
Cloudflare, by the TTL heuristic above.

Consequences that outlive the experiment:

- **A DNS change cannot be verified with one query.** One "it works now" is one instance
  out of an unknown number.
- **Two users of the same public resolver can legitimately see different answers at the
  same moment**, and neither is wrong.
- "Flush your DNS" aimed at a public resolver is close to meaningless — there is no way to
  address a particular instance.
- A TTL is a **ceiling**, not a floor: a resolver must not exceed it but is free to discard
  an entry sooner. Today's luck ran in the harmless direction; nothing can be built on it.

### The break-it: a rollback that helped nobody

`ttltest.airscroll.net` at TTL 86400, warmed with 15 queries, then changed to `192.0.2.1`
(RFC 5737 documentation range, deliberately unroutable):

```
authoritative:  192.0.2.1
8.8.8.8 x15:    13 x 178.151.120.5    2 x 192.0.2.1
```

Thirteen instances in the old world and two in the new, simultaneously, from one command.
Not "not propagated yet" — the term *propagation* is itself misleading, since nothing
propagates anywhere. Each cache independently runs out its own timer, and until they
converge the network holds two truths.

Then the rollback: content restored, TTL lowered to 300 — the standard reflex in an
incident.

```
authoritative:  178.151.120.5
8.8.8.8 x20:    18 x 178.151.120.5    2 x 192.0.2.1
```

**The rollback helped none of the affected.** The eighteen were never broken — thirteen
held the old value that the rollback made correct again by coincidence, the rest asked
fresh. The two that had taken `192.0.2.1` keep it for up to 24 hours, because that was the
promise in force **at the moment they fetched it**.

The rule this produces: **the TTL that matters is the one in effect when the bad record was
cached, not the one set afterwards.** Lowering the TTL during an incident does nothing for
anyone already hurt; it helps at the *next* incident. Which is the whole reason the
procedure is to lower it a day ahead — during the incident the lever is not connected.

And the shape of the resulting outage is the nastiest kind: a minority of users cannot
reach the service, everyone else is fine, monitoring is green, and it is not reproducible
from the operator's side.

### Two smaller ones

- A typo, `@elms.ns.cloudflare.com`, produced `dig: couldn't get address for ...: not
  found` — a different **class** of failure from a failed query. The query was never asked;
  `dig` could not resolve the name of the server it was told to ask.
- Every `+trace` wasted time on unreachable IPv6 roots (`network unreachable`, instantly —
  day 13's error, no route). The position of the failure moved between runs, because `dig`
  picks servers in a different order each time. Deterministic cause, nondeterministic
  position — precisely the shape that gets reported as "it fails sometimes, somewhere".

## What surprised me

- That a single `dig +trace` states its own provenance: round TTLs are authoritative,
  counting-down TTLs are cached. No extra command needed.
- That a TTL can go **up** between two consecutive queries to the same IP address, and that
  this is proof of multiple caches rather than a bug.
- That the DNS standard's recommended EDNS buffer size exists because of MTU and
  fragmentation — yesterday's topic reaching into today's protocol constants.
- That the plan document could carry a confidently stated fact that thirty seconds of `dig`
  disproved.

## Checkpoint answers

**Not done — second day running.** The questions below stay outstanding and open day 16
before its own re-quiz:

- What exactly does `dig +trace` do, and how does it differ from a plain `dig`?
- Why can a CNAME not be placed at a domain's apex?
- You changed an A record; you see the new value, a colleague sees the old. How long will
  that last and why?
- What is a CAA record for?
- Why does editing `/etc/resolv.conf` by hand achieve nothing on Ubuntu?

Day 14's evidence argues for answering them: the checkpoint that was practised came back
intact a day later, the one that stayed theory did not.

## Open questions

- **Day 16 is blocked.** The router's WAN address is `172.22.76.133` — RFC1918, inside
  `172.16.0.0/12` — while the public address is `178.151.120.5`. So the ISP runs a NAT in
  front of the router, and forwarding a port on the D-Link exposes it to the ISP's access
  network, not the internet. Not textbook CGNAT (`100.64.0.0/10`) but identical in effect.
  Two ways out: buy a public address from the ISP (keeps day 16 as designed — own nginx,
  own certificate, own port forward), or use a tunnel (Cloudflare Tunnel, Tailscale,
  WireGuard to a cheap VPS), which changes what the day teaches, since TLS may terminate
  somewhere other than the Pi.
- **The public address is dynamic.** It will change without warning and the `A` record will
  then point nowhere. This is what DDNS clients exist for — a small daemon noticing the
  change and updating the record through the same API used today. A good candidate for a
  later artifact.
- **DNSSEC** — `DS`, `RRSIG` and `NSEC3` appear in every `+trace`, and the `NSEC3` records
  in the `.net` referral are the proof that `airscroll.net` has **no** `DS`, so the chain of
  trust stops there. `resolvectl status` confirms from the other side: `DNSSEC=no`. Outside
  the weeks 3-4 curriculum.
- **Cleanup was not confirmed.** The `DELETE` of `ttltest` and the final listing of the
  zone (steps 15-16) were never run, so the zone's end state is unverified. First thing to
  check on day 16.
- Two Google instances hold `192.0.2.1` for `ttltest.airscroll.net` until roughly
  2026-09-06 19:47 EEST. Deleting the record does not touch them — which is the exercise's
  point, stated once more.
- The Pi still has no global IPv6 route, so every `+trace` pays for a doomed attempt first.
  Partial IPv6 is worse than none.
