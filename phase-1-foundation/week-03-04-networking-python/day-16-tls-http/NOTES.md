# Day 16 — TLS, HTTP, publishing the lab

Date: 2026-09-06 → 2026-09-07 (spilled into a second calendar day)
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64), nginx 1.24.0, certbot 2.9.0;
verification also from the macOS workstation, which turned out to matter

## Re-quiz (spaced retrieval)

Day 15's five checkpoint questions, outstanding for two days, were paid first. Plus one
interleaved from a distant domain.

- **`dig +trace`** — correct. Sharpened: the first step still goes to the configured
  resolver (to fetch the root `NS` list); everything after is iterative. So `+trace` shows
  how resolution *ought* to go, not what this client actually gets — a forwarder or a
  split-horizon zone is invisible to it.
- **CNAME at the apex** — correct by effect. Sharpened: RFC 1034 forbids a CNAME
  coexisting with *any* other type at the same name, and an apex necessarily carries `SOA`
  and `NS`. It is illegal, not merely harmful. Cloudflare "allows" it by flattening —
  resolving the target itself and serving an `A`, so the client never sees a CNAME.
- **Changed A record, colleague sees the old one** — **partial, and the miss was
  yesterday's own experiment.** The textbook answer ("until the TTL expires") was given;
  the lesson day 15 proved by hand was not: the governing TTL is the one **in force when
  that cache fetched the record**, and "the colleague's resolver" is not one cache. Doing
  a thing and being able to state it are separate skills, and only the second one gets
  tested.
- **CAA** — correct. Sharpened: it is checked by the **CA at issuance**, never by a client
  at connection time, and the CA walks **up** the tree from the requested name.
- **`/etc/resolv.conf` on Ubuntu** — correct. It is a symlink into `/run`, which is tmpfs
  and does not survive a reboot anyway.
- **Day 8 interleave — `make install` and removal** — correct. Sharpened: no package
  manager knows those files exist, `dpkg -S` finds nothing, and the binary can silently
  shadow a packaged one through `PATH` order.

Five of six. The one gap was the topic practised most recently, which is the opposite of
what intuition predicts.

## What I did

The day's designed goal — publish the Pi to the internet — is blocked by an ISP NAT
(recorded on day 15). Chosen path: **DNS-01 + own nginx, reachable on the LAN only.** That
keeps every part of the day's model verifiable on real infrastructure — own certificate,
own chain, own reverse proxy, own renewal timer — and drops exactly one thing, internet
reachability, which the ISP makes impossible regardless of configuration.

1. **CAA preflight before installing anything.** `dig CAA` at `lab.airscroll.net`,
   `airscroll.net` and `net`: no records anywhere. Empty `ANSWER`, `SOA` in `AUTHORITY` —
   NODATA, not NXDOMAIN. Absence of CAA is permission for every CA; CAA is opt-in
   restriction, not a whitelist.
2. Confirmed the bootstrap hardening actually holds on the Pi with `sshd -T`, not by
   reading files: `passwordauthentication no` despite `50-cloud-init.conf` setting `yes`
   after `00-hardening.conf` — because `sshd_config` takes the **first** value, not the
   last.
3. `apt install nginx certbot python3-certbot-dns-cloudflare`. Chose apt over the
   upstream-recommended snap: 1 GB of RAM, and day 8's point that a repository package is
   managed. Stated cost: the plugin version lags, so a Cloudflare API change would hit here
   first.
4. Watched the firewall and the listener behave as independent layers — nginx listening on
   :80 while `ufw` still dropped, then `ufw allow 'Nginx Full'`.
5. Cloudflare API token (scope `Zone:DNS:Edit`, one zone) into
   `/etc/letsencrypt/cloudflare.ini`, created with `install -m 600 /dev/null` so it never
   exists with loose permissions while holding a secret.
6. `certbot certonly --dns-cloudflare`, staging first (`--dry-run`), then production.
   Watched the `_acme-challenge` TXT record appear and disappear from a second terminal.
   Certificate issued 2026-09-06, expires 2026-12-05.
7. Wrote the nginx config by hand — `certonly`, not `--nginx`, because a generated config
   teaches nothing. Port 80 redirects; port 443 terminates TLS and proxies to
   `127.0.0.1:3000` with `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`.
8. Upstream bound to `127.0.0.1` only — the single entrance is nginx.
9. Added a `deploy` renewal hook to reload nginx, and verified it with
   `certbot renew --dry-run --run-deploy-hooks`.
10. Verified with `curl -v --resolve` and `openssl s_client -servername`, never a browser.

Findings worth keeping:

- **`grep -c "BEGIN CERTIFICATE"` is the whole chain model in one number.** `cert.pem` 1,
  `chain.pem` 1, `fullchain.pem` 2. nginx wants `fullchain.pem`; the trap is that the file
  named `cert.pem` matches the directive named `ssl_certificate`.
- **`live/` holds symlinks into `archive/`**, so the path in nginx never changes across
  renewals — and that is exactly why a reload hook is mandatory: nginx holds the old file
  open and never learns the symlink moved.
- **`nginx -t` reads the config on disk; `nginx -T` prints what the worker actually
  loaded.** When "I changed the config and nothing changed", `-T` is the answer, and the
  wire is the final authority above both.
- **curl exit codes are a layer diagnosis**: `28` timeout (firewall DROP), `7` refused
  (RST, nothing listening), `60` certificate. Instant refusal is an answer; a slow failure
  is silence.
- **`--resolve` overrides only the route.** The URL still supplies SNI, the `Host` header
  and the verification target. Identity and route are independent.
- `(304)` in curl's TLS trace is `0x0304`, the TLS 1.3 version number — not HTTP 304.
- HTTP/2 pseudo-headers visible in the live output: `:method`, `:scheme`, `:authority`,
  `:path`, all header names lowercase. `Host` became `:authority`.
- nginx rewrote the upstream's `Server` header — the client cannot see what is behind.

## What broke

### The break-it did not break — and that was the day's best finding

Serving `cert.pem` instead of `fullchain.pem` should make `curl` fail while a browser
succeeds. On the wire the breakage was real:

```
openssl s_client ... | grep -c "BEGIN CERTIFICATE"   →  1
```

One certificate, no intermediate. And `curl` from **macOS** still reported
`SSL certificate verify ok.` The same request from the **Pi** failed properly:

```
* TLSv1.3 (OUT), TLS alert, unknown CA (560):
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

The model as stated that morning — "browsers fetch the missing intermediate over AIA,
`curl` does not" — is wrong in its subject. **The behaviour belongs to the TLS stack, not
to the program.** Apple's `/usr/bin/curl` verifies through Security.framework, the same
system evaluator Safari uses, which fetches AIA and caches intermediates in the keychain.
Ubuntu's curl links OpenSSL, reads `/etc/ssl/certs/ca-certificates.crt`, and does neither.

Consequences that outlive the exercise:

- **A green result from the wrong stack is worse than no result** — it closes the question
  falsely. The workstation certified a configuration that would break every Linux client:
  every CI job, container, webhook and server-to-server call.
- The rule is not "check with curl instead of a browser". It is **check from a client that
  matches production**.
- Two failure surfaces at once: chain building differs by stack, and the *report* of
  success differs by stack.

Also visible: the handshake aborted immediately after `Certificate (11)`, before
`CertificateVerify` — no HTTP was ever sent. So a chain failure leaves **nothing in
`access.log`**, only `error.log`. "The service is down but the access log is silent" is the
signature of a TLS problem rather than an application one.

### The deploy hook failed, and certbot called it a success

```
Hook 'deploy-hook' reported error code 127
...
Congratulations, all simulated renewals succeeded
```

Both statements are true and they describe different things: the **certificate** renewed,
the **deployment** did not. Exit 127 is "command not found", which `/bin/sh` reports
identically whether the file is absent or its shebang interpreter is (a stray `\r` on line
one makes the kernel look for `/bin/sh\r`). 126 with "Permission denied" would have meant a
missing exec bit; 127 rules that out.

The operational lesson is bigger than the bug: **certbot's exit status means "certificate
obtained", not "the server is serving it".** Monitoring must check what the server actually
presents, not what is on disk — otherwise this failure surfaces on day 90.

Hook design that followed from it: `deploy/`, not `post/`. The timer fires twice a day, so
over 90 days `post` would reload nginx ~180 times for one real event. `deploy` runs only
when a certificate actually changed, and a `case` on `$RENEWED_LINEAGE` keeps one
certificate's renewal from reloading services that belong to another.

### Two invisible characters, in one day

- **Trailing whitespace after `\`.** The multi-line certbot command broke apart: a
  backslash escapes the *next character*, so `\` + space escapes the space and leaves the
  newline live. Result: `certbot: error: unrecognized arguments:` (the escaped space
  arriving as an argument) followed by the remaining lines running as separate commands
  (`--agree-tos: command not found`).
- The hook's 127, whose cause is the same family.

Both are invisible in an editor. `cat -A` shows them (`$` for LF, `^M$` for CRLF); the
prevention is `trim_trailing_whitespace` in `.editorconfig`.

### `http2 on;` is not a directive on nginx 1.24

```
[emerg] unknown directive "http2" in .../lab.airscroll.net:14
```

`http2 on;` arrived in nginx **1.25.1**; before that `http2` is a parameter of `listen`.
Ubuntu 24.04 ships 1.24.0, so the old form is required. Examples on the internet do not
state which branch they were written for, which is why half of copied nginx config fails
this way.

`nginx -t` caught it before the reload — the running workers never saw the broken config.
That is the entire reason the reflex exists.

### `cd /etc/letsencrypt/live` is denied, and `sudo cd` is not a thing

`live/` and `archive/` are `0700 root:root` because `privkey.pem` lives there. The `cd`
failed, the shell stayed in `~`, and `openssl` then reported a confusing
`Could not open file or uri for loading certificate` — a path error wearing a crypto error's
clothes. `sudo cd` cannot help: `cd` is a shell builtin, so there is no binary for `sudo`
to run. Absolute paths are the answer.

## What surprised me

- That the deliberate breakage produced a **false pass** on the machine used for
  verification. The exercise was designed to demonstrate one thing and demonstrated a
  sharper one.
- That certbot prints "Congratulations" over a failed hook, and that this is defensible —
  it renewed the certificate, which is what it promised.
- That connecting by IP sends **no SNI at all** (RFC 6066 forbids a literal address there),
  so nginx falls back to its default server and presents a certificate for a name the
  client never asked about. This is why real multi-vhost servers define an explicit
  `default_server` stub.
- That a TLS chain failure produces no `access.log` line whatsoever.
- That `(304)` in curl's trace is a TLS version number and not an HTTP status.
- That the certificate certifies the **name**, not the route, so `--resolve` is an honest
  test rather than a workaround — and that this is the same fact the IP break-it fails on,
  seen from the other side.

## Checkpoint answers

**1. Valid in a browser, `curl` reports a verification error — most likely cause?**
The server sends only the leaf and omits the intermediate. The browser completes the chain
(cached intermediate, or fetched via the `AIA` extension in the leaf); an OpenSSL-based
client does neither and stops at "unable to get local issuer certificate". Correct
statement of the rule: this is a property of the **TLS stack**, not of the program —
macOS's curl behaves like the browser here, as proved today.

**2. What travels in cleartext during the handshake, and why does it matter?**
SNI (the hostname), ALPN (the negotiated protocol), the offered TLS versions and cipher
list — and in TLS 1.2, the server's certificate as well (encrypted from 1.3 onward).
It matters because encrypting the content does not hide **whom you are talking to**: anyone
on the path sees IP + SNI, which is a complete list of the sites visited. That is the basis
of corporate DPI and state-level blocking, and the hole ECH exists to close.

**3. HTTP-01 vs DNS-01 — when is the first impossible in principle?**
For a **wildcard**: no HTTP request can prove control over every subdomain. Practically
also whenever inbound port 80 cannot reach the machine — behind an ISP NAT (today's case),
behind a firewall you do not control, or on hosting where port 80 is not yours. DNS-01
works because the proof travels into the zone rather than to the machine.

**4. What does a reverse proxy do that the application will not?**
It is a **trust boundary and a multiplexer**: TLS termination in one place (one
certificate, one renewal); many applications behind one port 443, split by `Host` and path;
injecting and sanitising `X-Forwarded-*` so the app sees real clients rather than
`127.0.0.1`, and so a client cannot forge them; buffering slow clients so one bad
connection cannot hold an application worker (Slowloris). Plus static files, compression,
timeouts and rate limits. In Kubernetes this same role is the Ingress Controller.

**5 (earned today). Why did verifying from macOS give a false pass?**
Because macOS's curl verifies through the system evaluator (Security.framework), which
fetches AIA and caches intermediates, so it repairs a broken chain that a production Linux
client would reject. The general rule: **verify from a stack that matches the one that will
be the client in production** — from the server itself, or from a container. A green result
from the wrong validator is worse than no result, because it closes the question.

## Open questions

- **Internet exposure is still blocked** and this remains the day's honest limitation. The
  configuration built today is complete and would work unchanged the moment packets can
  arrive; only the network path is missing. Two ways out, unchanged from day 15: a public
  address from the ISP, or a tunnel. Day 17's break-it (real SSH brute-force from the
  internet) depends on this and cannot run until it is resolved.
- The exact cause of the hook's exit 127 was not recorded before the file was rewritten —
  absent file or a CRLF shebang. Worth reproducing deliberately once, since the two are
  indistinguishable from the error message.
- **Not done today**, deliberately, to keep the day inside one day:
  - `502` vs `503` vs `504` observed by hand (stop the upstream, then make it slow)
  - the browser half of break-it #1, which needs an `/etc/hosts` entry on the workstation
  - checking whether the issued certificate still carries an OCSP URL at all, given Let's
    Encrypt's move away from OCSP toward CRLs
- **OCSP stapling is not configured** (`ssl_stapling` + `ssl_trusted_certificate` pointing
  at `chain.pem` — the one use for that file). Deferred, and worth pairing with the OCSP
  check above.
- **No `default_server` stub.** A request by IP currently receives the lab certificate.
  Harmless with one site, wrong with several.
- The upstream is `python3 -m http.server` in a foreground shell — it dies with the SSH
  session. A real deployment means a systemd unit (day 5), which is also the natural
  moment to swap in a Next.js app: `proxy_pass` does not change.
- **The public address is dynamic** (day 15). When it changes, the `A` record points
  nowhere and even the DNS-01 renewal stays fine — but the name stops matching reality. The
  DDNS client remains a good artifact candidate.
