# learning-devops

Working repository for a 6-month transition from senior front-end engineering into
platform / infrastructure engineering. Everything here is built, broken and fixed on
real hardware — a Raspberry Pi lab server — not on tutorial screenshots.

Every chapter of the plan ends with something that runs and is committed. No exceptions.

## Reference — start here when revising

Four documents, three different jobs. Open the one that matches what you need.

| Open this | For | When |
|---|---|---|
| [Glossary](GLOSSARY.md) | The canonical name and definition of a term, repository-wide. One or two sentences each, plus the loose synonyms to avoid — English here is a deliberate second track, so the glossary fixes the right word, not the first one to mind. | You know the concept but not what it is called, or want the definition tight |
| [Command lookup card — Linux & bash](phase-1-foundation/week-01-02-linux-bash/reference/commands.md) | Finding a command **now**, mid-task. Indexed by the question you're asking ("disk is full", "permissions denied and I don't see why"), never chronologically — so you never have to remember which day taught it. Includes the trap that makes each command silently wrong. | Stuck on something, need the answer in seconds |
| [Command lookup card — networking & Python](phase-1-foundation/week-03-04-networking-python/reference/commands.md) | The same job for days 13 onward: interfaces and addresses, where a packet will actually go, why two machines in a segment can't talk, telling a routing failure from a firewall from DNS by its symptom. | Stuck on something, need the answer in seconds |
| [Week 1 cheat sheet](phase-1-foundation/week-01-02-linux-bash/reference/week-1-cheatsheet.md) | Processes, `/proc`, signals, file descriptors, permissions, SSH, systemd units. Mechanisms and why they bite, not command lists. | Coming back to a topic after time away |
| [Week 2 cheat sheet](phase-1-foundation/week-01-02-linux-bash/reference/week-2-cheatsheet.md) | journald, timers, sandboxing, filesystems and LVM, packages and firewall, bash strict mode and traps, streams and log parsing. | Coming back to a topic after time away |

The cheat sheets are prose to **read**; the lookup cards are material to **search** (one
per week block, each pointing at the other); the
glossary is the vocabulary the other two are written in.
Day `NOTES.md` files are neither — they record what happened on a given day, including
the failures, and are not meant to be revisited for reference.

## Lab

| Component | What it is |
|---|---|
| Lab server | Raspberry Pi, Ubuntu Server LTS (arm64) |
| Domain | `lab.airscroll.app` (subdomain of a production product) |
| Workstation | macOS, Apple Silicon |

## Structure

```
GLOSSARY.md                    ← repository-wide vocabulary
phase-1-foundation/
  week-01-02-linux-bash/
    CURRICULUM.md            12-day plan, exercises and checkpoint questions
    day-NN-topic/NOTES.md    what was done, what broke, what was learned
    reference/               ← cheat sheets + lookup card
    artifact-server-bootstrap/   ← deliverable: idempotent server bootstrap
  week-03-04-networking-python/
    CURRICULUM.md            networking (days 13–17), Python (days 18–22)
    day-NN-topic/NOTES.md    what was done, what broke, what was learned
    reference/               ← lookup card for this block
    artifact-lab-probe/          ← deliverable: external prober for the lab
```

## Phases

- [ ] **Phase 1 — Foundation** (weeks 1–4): Linux internals, Bash, networking, Python
- [ ] **Phase 2 — Containers + Cloud** (weeks 5–12): Docker, AWS core, Terraform
- [ ] **Phase 3 — Kubernetes + GitOps** (weeks 13–20): k8s, ArgoCD, mature CI/CD
- [ ] **Phase 4 — Observability & Reliability** (weeks 21–24): Prometheus, SLO, postmortems

## Conventions

- Commits, READMEs and write-ups are in English — it doubles as the language track.
- Every artifact must survive a rebuild from scratch. "It works on my box" is not done.
- Notes record failures explicitly. The `What broke` section is the point, not filler.
