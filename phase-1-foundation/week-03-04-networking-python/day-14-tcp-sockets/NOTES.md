# Day 14 — TCP, UDP, sockets, connection states

Date: 2026-09-03
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64), client side macOS

## Re-quiz (spaced retrieval)

Interleaved across three domains — layer 2, filesystems, shell file descriptors. All
three correct.

1. Day 13: what ARP does, and stale vs poisoned cache. **Correct.** Sharpened twice:
   ARP resolves only *within one broadcast domain*, so for a remote destination what
   gets resolved is the next hop's MAC, never the destination's. And the reason
   poisoning is possible at all is that ARP has no authentication — any host may answer
   for any address, including unsolicited (gratuitous ARP). Stale is expired truth,
   poisoned is injected falsehood; identical symptom, opposite causes.
2. Day 7: `umount` returning `target is busy`. **Correct**, `lsof` was the right
   instinct. Sharpened: an open fd is the commonest but not the only reference the
   kernel counts — a process's cwd inside the tree (usually one's own shell), an
   mmap'd file, or another mount stacked on top all hold it. `fuser -vm <path>` and
   `lsof +f -- <path>` ask "who holds this filesystem" rather than "who holds this
   path". `umount -l` defers rather than forces.
3. Day 10: `>out.txt 2>&1` vs `2>&1 >out.txt`. **Correct.** Sharpened: redirections
   apply left to right and `2>&1` is `dup2()` — it copies fd 1's *value at that moment*
   rather than creating an alias, so the second form aims fd 2 at the terminal before
   fd 1 moves to the file.

## What I did

1. Socket survey, `ss -tulpn` with and without `sudo`. Without root the Process column
   is silently empty — `-p` has to read other processes' `/proc/<pid>/fd/`, and `ss`
   shows nothing rather than erroring.
2. Read the four-tuple off a live SSH session (`ss -tnp state established`), then the
   full kernel view of it with `ss -tinp`.
3. Captured a real handshake and teardown with
   `tcpdump -nn -i eth0 'tcp port 22 and tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0'`
   while running `ssh lab true` from the Mac.
4. `TIME_WAIT` experiment on loopback with `nc`: closed the client first, then the
   server first, and compared `ss -tan '( sport = :9000 or dport = :9000 )'`.
5. The second run produced a live half-closed pair — `FIN_WAIT_2` on one side and
   `CLOSE_WAIT` on the other — which was the day's most useful accident.
6. Break-it: the same port under four configurations (open with listener, open without
   listener, `ufw reject`, `ufw deny`), timed from the Mac with `time nc -v -w 20`,
   captured on the Pi with `tcpdump ... 'host <mac> and (tcp port 9000 or icmp)'`.

Findings worth keeping:

- **`Recv-Q`/`Send-Q` mean different things per state.** On `LISTEN` they are the accept
  queue: `Send-Q` is the backlog ceiling (4096 here, `net.core.somaxconn`) and `Recv-Q`
  is how many completed connections are waiting for `accept()`. On `ESTAB` they are
  bytes: unread by the app, and sent-but-unacked. Growing `Recv-Q` on `LISTEN` means the
  app is too slow to accept; on `ESTAB` it means too slow to read.
- **The bind address matters more than the port.** `0.0.0.0:22` is reachable from
  anywhere a packet can arrive; `127.0.0.53%lo:53` cannot be reached from the network at
  all — a stronger guarantee than a firewall rule, since it does not depend on rules
  staying correct. `192.168.0.197%eth0:68` is bound to one address *and* one interface.
- **The sshd listening socket has two owners:** `sshd` and `systemd` (PID 1) hold fds on
  the same socket. systemd created it and passed it in — socket activation. Side effect:
  the port stays open across a service restart, so connections arriving mid-restart queue
  instead of being refused.
- **The established SSH connection also has two owners**, both `sshd`: privilege
  separation from day 3. The parent runs as root, forks an unprivileged child that
  inherits the fd and is the one parsing hostile input.
- **Ephemeral port ranges are an OS choice, not a protocol constant.** Linux clients
  came from 32768–60999 (41966, 42588); the Mac used 62488 and 54xxx, from macOS's
  49152–65535. The protocol only requires the four-tuple to be unique.

Handshake, read off the wire:

- `ack` is always ISN+1 on a `length 0` SYN, because **SYN consumes a sequence number**.
  Without that, "I received zero bytes starting at N" would be indistinguishable from
  silence. FIN does the same.
- LAN RTT measured by hand from the timestamps: **298 µs** (SYN at .093301, SYN-ACK at
  .093599).
- `mss 1460` = 1500 − 20 (IP) − 20 (TCP), computed by each side from its *own* first
  link. Nothing in the handshake knows anything about the path in between — which is
  exactly why PMTUD exists and why it fails silently.
- `wscale` is negotiated **only** in the SYN and can never be renegotiated. A middlebox
  stripping SYN options leaves a working connection permanently capped at 64 KB.

`ss -tinp` on the SSH session:

- `mss:1448` against the handshake's `1460` — the 12-byte difference is the TCP
  timestamp option, carried in *every* packet. `advmss` is what was announced, `mss` is
  what is usable.
- `pmtu:1500` — the kernel's current belief about the path MTU, and the first field to
  check when a PMTUD black hole is suspected.
- `snd_wnd:131072` is the same number as tcpdump's `win 2048` with `wscale 6`
  (2048 × 64). The raw window in later packets is always scaled.
- `rtt:0.943/0.113` (smoothed/mdev) against `minrtt:0.474`. The smoothed figure includes
  delayed ACKs (`ato:42`), so `minrtt` is the honest wire number and the one closer to
  the 298 µs measured by hand.
- `rto:201` — Linux clamps the retransmission timeout at 200 ms (`TCP_RTO_MIN`) no matter
  how small the RTT. One loss on a sub-millisecond LAN still costs a fifth of a second.
- No `retrans` field and `bytes_sent == bytes_acked` exactly: nothing lost, nothing in
  flight.
- `cwnd:10` never grew from Linux's initial value — but `app_limited` is present, which
  says the limit is the application, not the network. That one word is the whole
  flow-control vs congestion-control distinction, printed.

## What broke

Four configurations on port 9000, from the Mac:

| Configuration | On the wire | Client sees | `time` |
|---|---|---|---|
| open + listener | SYN-ACK in 1.3 ms | success | — |
| open, no listener | `R.` in 0.2 ms | `Connection refused` | 1.02 s |
| `ufw reject` | `R.` in 0.2 ms | `Connection refused` | 1.02 s |
| `ufw deny` (DROP) | nothing, 7 SYN retries | hung until Ctrl-C | 34.5 s |

**The prediction was wrong, and the reason is worth more than the prediction.** I expected
`ufw reject` to answer with ICMP `port unreachable` — the iptables default for `-j REJECT`.
It answered with a TCP RST, byte-for-byte the same shape as the closed-port case.
Verified in ufw's own source rather than guessed:

```python
elif self.action == "reject":
    rule_str += " -j REJECT%s" % (lstr)
    if self.protocol == "tcp":
        # follow TCP's default and send RST
        rule_str += " --reject-with tcp-reset"
```

So the override is **TCP-only**: `ufw reject <port>/udp` would still produce ICMP. The
original model was right for iptables and for UDP, and wrong for exactly this one case.

Consequence for diagnosis: the curriculum promised three distinct symptoms and the real
split is **two — an answer or silence**. Silence means something is swallowing the packet
(DROP, a wrong route, a dead host). An answer means the host is alive and something
actively refused — but *what* refused cannot be told from the client, because a RST from
the kernel and a RST from the firewall are identical. That only resolves on the host
itself.

Three smaller things that broke:

- **The first tcpdump filter hid two real packets.** Filtering on SYN/FIN/RST excludes
  pure ACKs, so the third packet of the handshake and the last of the teardown never
  appeared — four lines where seven packets happened. Easy to misread as "the connection
  never completed". A filter is always part of the answer.
- **`nc -w 20` on macOS did not apply to `connect()`.** The DROP case ran 34.5 s until
  Ctrl-C rather than giving up at 20 s.
- **"Instant" is a property of the client OS, not the network.** The RST arrived in
  0.2 ms, but macOS re-sent the SYN once anyway and only reported `Connection refused`
  after 1.02 s. Timing a failure measures the client's retry policy as much as the path.

SYN retry pattern under DROP, from the capture: 1, 1, 1, 1, 1, 2 s — macOS starts flat
and then backs off. Linux backs off from the first retry (1, 2, 4, 8, 16, 32) and gives up
near 127 s at the default `tcp_syn_retries=6`. Also visible: the first SYN carries `[SEW]`
and every retry only `[S]` — macOS drops ECN on retransmission, assuming ECN might be what
got the packet lost.

## What surprised me

- **`CLOSE_WAIT` has no timer at all.** `TIME_WAIT` clears itself in 60 s and orphaned
  `FIN_WAIT_2` clears via `net.ipv4.tcp_fin_timeout`, but nothing in the kernel ever
  closes a `CLOSE_WAIT` socket, because doing so would cut off a connection the
  application still has the right to write to. That asymmetry is the whole reason one
  state is a harmless snapshot of load and the other accumulates until the process dies.
  Confirmed by prediction: after a minute the `TIME_WAIT` and `FIN_WAIT_2` entries were
  gone and the `CLOSE_WAIT` remained, `sudo ss -tanp` naming `nc` and fd 3; `ls -l
  /proc/<pid>/fd` showed `3 -> socket:[96610]`; `kill` removed the entry instantly.
- That `ss -tanp state close-wait` collapses "the network is flaky" into a PID and a file
  descriptor number.
- That `nc` sitting in `CLOSE_WAIT` is not misbehaving — half-close is legal TCP, and it
  is still reading stdin for the direction it never closed. The bug in production is the
  same shape, just unintentional.
- That the effective MSS is 1448 rather than the negotiated 1460, because timestamps are
  paid for on every single packet.
- That `systemd` appears as a co-owner of a listening socket it never serves.

## Checkpoint answers

**Not done — the day was cut short before the checkpoint.** The break-it exercise ran in
full; the checkpoint questions were not answered aloud, so by this repository's own bar
day 14 is not formally closed. They are the first item of day 15, before its re-quiz:

- `Connection refused` vs a timeout — what does each mean and what do you check first?
- A server holds 40 000 connections on port 443. How does one port carry that?
- Thousands of `CLOSE_WAIT` on a server — network problem or application problem, and why?
- Why does an HTTP request for a small page succeed while a large one hangs?

Three of the four were demonstrated during the day, so the answers should be retrievable;
the fourth (MTU) was covered in the model only.

## Open questions

- **MTU was not practised.** `ping -M do -s 1472` / `-s 1473` against the gateway was
  planned and not run, so the DF flag and the 1472/1473 boundary were never seen
  first-hand. Everything about MTU today came from the model plus the `pmtu:1500` field.
- **Socket activation not verified.** `systemctl status ssh.socket ssh.service` was never
  run, so how ssh is actually wired on this machine is inferred from the shared fd alone.
- `ssthresh:21` was present on one of the two SSH sessions, meaning a congestion event
  happened at some point in its life, while the other session had no `ssthresh` at all.
  Unexplained.
- ECN (`[SEW]` / `[S.E]`, the `E` and `W` flags): macOS negotiates it by default and
  Linux accepts. Adjacent to the day, not part of it.
- `avahi-daemon` listens on `0.0.0.0:5353` plus two random high ports — mDNS, which is
  what makes the Pi answer as `alex.local`. Fine on a LAN; a candidate for removal before
  day 16 exposes the machine.
- `wlan0` is administratively down (`ip link set wlan0 down`, deliberate), so the
  metric-600 default route from day 13 is gone and there is currently no redundant path.
- Whether `ufw status` and `iptables -S` are actually clean of the port 9000 rules was
  not re-checked at the end.
