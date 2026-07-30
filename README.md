# learning-devops

Working repository for a 6-month transition from senior front-end engineering into
platform / infrastructure engineering. Everything here is built, broken and fixed on
real hardware — a Raspberry Pi lab server — not on tutorial screenshots.

Every chapter of the plan ends with something that runs and is committed. No exceptions.

## Lab

| Component | What it is |
|---|---|
| Lab server | Raspberry Pi, Ubuntu Server LTS (arm64) |
| Domain | `lab.airscroll.app` (subdomain of a production product) |
| Workstation | macOS, Apple Silicon |

## Structure

```
phase-1-foundation/
  week-01-02-linux-bash/
    CURRICULUM.md            10-day plan, exercises and checkpoint questions
    day-NN-topic/NOTES.md    what was done, what broke, what was learned
    artifact-server-bootstrap/   ← deliverable: idempotent server bootstrap
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
