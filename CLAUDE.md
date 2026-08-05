# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A personal learning workspace for a 6-month transition from senior front-end engineering
into platform / infrastructure engineering. It is not an application: there is no root
build, no package manager, no test suite. The unit of work is a **day** (notes) or an
**artifact** (a real, runnable deliverable).

Work is done against a physical lab, not a sandbox:

- Lab server: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64), domain `lab.airscroll.app`
- Workstation: macOS, Apple Silicon

Scripts written here target **Ubuntu arm64**, not the workstation. macOS ships bash 3.2
and BSD coreutils, so a script that runs locally proves nothing — verification happens on
the Pi.

## Layout and how work flows

```
phase-N-<name>/week-NN-MM-<topic>/
  CURRICULUM.md              the plan: daily model → practice → break-it → checkpoint questions
  day-NN-<topic>/NOTES.md    the record of that day
  artifact-<name>/           the deliverable for that block
```

`CURRICULUM.md` is the source of truth for what a day contains. Before working on
`day-NN-*`, read that day's section — it specifies the mental model to build, the tools to
use, the deliberate breakage exercise, and the checkpoint questions.

Day directories are created up front and are empty until worked. Creating a `NOTES.md`
means starting that day.

## Pacing: stay inside the current day

Hard-learned on day 01: expanding into adjacent topics stretched one day into more than
two. When guiding a `day-NN-*`, the day's section in `CURRICULUM.md` is not just the
source of truth for content — it is the **scope ceiling**:

- Teach only what that day's section covers. A digression is justified only when the
  current day's material cannot be understood without it, and even then keep it to a few
  sentences.
- When a question or tangent belongs to a later day/week, name where it lives ("that's
  day 07") and record it in the current `NOTES.md` under `Open questions` instead of
  explaining it now. `Open questions` is the parking lot; the curriculum will reach it.
- A day must be completable in one working day. If it starts spilling over, cut breadth
  and extra examples — never the break-it exercise or the checkpoint questions, which are
  the actual bar for "done".
- Do not preview upcoming days, add "bonus" material, or deepen a topic beyond what its
  checkpoint questions require.

## Retention: spaced retrieval and cheat sheets

Two practices borrowed deliberately from the `teach` skill (adopted 2026-08-05) without
its workspace:

- **Opening re-quiz.** Every day starts with ~3 checkpoint questions from *previous*
  days, answered aloud from memory before any new material. Five minutes, no more —
  the goal is spaced retrieval, not a second lesson. Pick questions 2–4 days old.
- **Weekly cheat sheet.** Closing a week produces one compact English reference in
  `<week-block>/reference/` — the compressed essence of that week (commands, states,
  patterns), designed to be reread before an interview. `NOTES.md` records what
  happened; the cheat sheet is what gets revisited. Day notes are not a substitute.

## Conventions that matter

**Language split.** `CURRICULUM.md` and planning prose are in Ukrainian. Everything that
is a deliverable — `NOTES.md`, artifact READMEs, code comments, commit messages — is in
**English**, deliberately, as a language track. Do not translate `CURRICULUM.md`; do not
write deliverables in Ukrainian.

**`NOTES.md` structure** (see `day-01-processes/NOTES.md` for the shape): date + machine,
then `What I did` / `What broke` / `What surprised me` / `Checkpoint answers` /
`Open questions`. `What broke` is the point of the document, not filler — an empty one
means the day was not really done. Checkpoint answers are transcribed from the
curriculum's questions for that day and are meant to be answered from memory first.

**Artifacts must survive a rebuild.** The definition of done for
`artifact-server-bootstrap/` is spelled out at the end of `CURRICULUM.md` (days 11–12) and
sets the bar for every later artifact:

- `set -euo pipefail`, `trap` cleanup, every step logged
- a `--dry-run` mode
- passes `shellcheck` with no warnings (`shellcheck` and `bats` are not installed on the
  workstation yet; install before claiming either passes)
- **idempotent**: two consecutive runs succeed and the second changes nothing
- verified on a genuinely clean machine, not one already configured by hand
- English README stating what it does, how to run it, its assumptions, and what it
  deliberately does *not* do

When claiming an artifact works, say where it was run. "Should work" is not a result here.

**Secrets.** `.gitignore` blocks `.env*`, `secrets/`, `*.pem`, `*.key`, `id_*` (public keys
excepted). Real host details go in notes only where they are already public.

## The `teach` skill

`.agents/skills/teach/` is vendored from `mattpocock/skills` and pinned by content hash in
`skills-lock.json`; `.claude/skills/teach` is a symlink to it. Treat those files as
read-only — editing them invalidates the lock hash.

Invoking `/teach` turns the working directory into a stateful teaching workspace with its
own files (`MISSION.md`, `RESOURCES.md`, `learning-records/`, `lessons/`, `reference/`,
`assets/`). None exist yet. **Decision (2026-08-05): the full workspace is deliberately
not used** — `MISSION.md`/`learning-records/`/`lessons/` would duplicate the
curriculum/day-notes flow above. Only two of its ideas are adopted (see "Retention"):
the opening re-quiz and weekly cheat sheets. Do not create the other teach files.
