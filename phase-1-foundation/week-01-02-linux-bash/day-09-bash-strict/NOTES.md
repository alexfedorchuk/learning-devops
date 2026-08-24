# Day 9 — Bash: the correct script

Date: 2026-08-24
Machine: Raspberry Pi 3B, Ubuntu Server 24.04 LTS (arm64)

## Re-quiz (spaced retrieval)

Three questions from previous days, answered aloud before any new material — all
three correct, no corrections needed:

1. Day 3: why does a service need its own user rather than a shared `nobody`?
   `nobody` is one shared UID across every service using it, so any of them can
   reach the others' processes and files — the isolation the separate account was
   supposed to provide is gone.
2. Day 5: why does systemd reliably kill all of a service's child processes where
   SysV init often lost them? Every process of a unit lives in the same cgroup, and
   the kernel can enumerate a cgroup's members regardless of how they forked or got
   reparented. SysV had no such kernel-side mechanism — it tracked a single PID and
   lost anything that daemonized away from it.
3. Day 6: why is a systemd timer with `Persistent=true` better than cron for a job
   that could miss its window while the machine was off? It records the last run and
   fires the missed occurrence at the next boot; cron simply skips a tick that
   happened while the machine was down.

## What I did

1. `set -e` pipeline experiment, both halves:
   - `set -e; false | true; echo "still running?"` — printed `still running?`. Without
     `pipefail` the pipeline's status is the status of its **last** command (`true`),
     so `false`'s failure is invisible to `-e`.
   - `set -e -o pipefail; false | true; echo "still running?"` — printed nothing and
     exited 1. Silent because `false` itself emits no message: the shell just dies at
     the pipeline, before `echo` ever runs.
2. Wrote `backup.sh` — timestamped config backup with `set -euo pipefail`, `trap`
   cleanup, `local` in functions, manual `case` argument parsing (short, long, and
   `--opt=value` forms), and `cmp`-based idempotency.
3. Verified on the Pi (`bash 5.2.21`, aarch64), not on the workstation — macOS ships
   bash 3.2, so local behavior would prove nothing about the target.
4. `shellcheck` on the Pi (`/usr/bin/shellcheck`, already installed there): **exit 0,
   zero warnings** — on a script that had two real defects. See What surprised me.
5. Exercised every path: `--help`, first run, second run (idempotent — skipped, no
   duplicate), changed source (new copy created), missing `-s` argument, unknown
   option, nonexistent source file. All logic behaved as intended.
6. Fixed all three defects and re-verified on the Pi (`~/lab/backup.sh`):
   `shellcheck` exit 0, `--help` clean, run 1 and run 2 both **exit 0** and idempotent,
   error paths still exit 1 — so success and failure are distinguishable again.
7. Signal testing done properly this time, mid-copy rather than at an idle moment: a
   150 MB source file makes `cp` slow enough on the SD card to interrupt while
   `$tmpfile` genuinely exists. SIGTERM → exit 143, temp file removed, no partial
   `.bak` left behind. SIGINT → exit 130, same clean result.

## What broke

1. **The script reported failure on success — exit code 1 from every run, including
   the ones that worked.** Isolated the cause to the EXIT trap:

   ```bash
   cleanup() {
     [[ -n "$tmpfile" && -f "$tmpfile" ]] && rm -f "$tmpfile"
   }
   trap cleanup EXIT
   ```

   On a successful run `tmpfile` is `""`, so the `[[ ]]` test returns 1, the `&&`
   compound returns 1, and that becomes the function's return status — the last
   command of the EXIT trap. Bash lets that status **override** the script's exit
   code. Verified by A/B: identical scripts differing only by a trailing `return 0`
   in `cleanup` exited 1 and 0 respectively. Practical severity is high — the error
   paths also exit 1, so a caller (`&&` chain, cron, systemd, a parent script under
   `set -e`) cannot distinguish success from failure at all.

   Fix: end `cleanup` with `return 0`, or use `if [[ ... ]]; then rm -f ...; fi`
   instead of the `&&` chain.

2. **`trap cleanup EXIT INT TERM` swallowed Ctrl-C — the script kept running.** A
   signal trap that doesn't exit returns control to the point of interruption. Tested
   with a `sleep 30` and `kill -INT`: the line after the sleep printed
   (`!!! STILL RUNNING AFTER SIGINT !!!`), cleanup ran at the *normal* end, and the
   script exited 0 — as if the interrupt never arrived. This is strictly worse than
   not trapping at all: default SIGINT would have killed the process.

   Proven on the original script with SIGTERM mid-copy, and the failure is sharper
   than "it keeps running": `cleanup` deleted `$tmpfile`, the trap returned, execution
   resumed at the *next* line — `mv "$tmpfile" ...` — which then failed on the file
   cleanup had just removed:

   ```
   mv: cannot stat '/tmp/bkold/.bigcfg.conf.c4UsVg': No such file or directory
   OLD exit after SIGTERM: 1
   ```

   The handler sabotaged the code it returned into. A cleanup handler is only safe if
   nothing resumes after it.

   Fix — the signal traps must re-exit, which then fires the EXIT trap so cleanup
   still runs exactly once:

   ```bash
   trap cleanup EXIT
   trap 'exit 130' INT     # 128 + 2
   trap 'exit 143' TERM    # 128 + 15
   ```

3. **`--help` printed a stray `}`.** The heredoc terminator sat one line too late, so
   the function's closing brace was part of the heredoc body rather than code:

   ```bash
   -h, --help   Help
   }            <- inside the heredoc, printed as text
   EOF
   }            <- actually closes the function
   ```

   Parses fine, which is why nothing complained. Also a typo in a `die` message:
   "file not fount" — still unfixed, cosmetic.

4. **My own test method broke before the script did — SIGINT never reached the
   process at all.** The fixed script, backgrounded with `&` and sent `kill -INT`,
   ran to completion and exited 0, as if the `trap 'exit 130' INT` line didn't exist.
   It effectively didn't: a shell running a command asynchronously without job
   control sets SIGINT and SIGQUIT to **`SIG_IGN`** in the child (POSIX), and bash
   cannot trap or reset a signal that was already ignored on entry — the `trap`
   statement silently does nothing. Confirmed straight from the kernel:

   ```
   backgrounded with &     SigIgn: ...0006   SigCgt: ...010000
   same script, set -m     SigIgn: ...0004   SigCgt: ...010002
   ```

   `SigIgn 0x6` = signals 2 (INT) + 3 (QUIT) ignored; `SigCgt 0x10000` = only SIGCHLD
   caught, no INT handler installed. With job control on (`set -m`) the job gets its
   own process group, only SIGQUIT stays ignored, `SigCgt` gains bit 0x2 — and the
   trap fires: exit 130, temp file cleaned. SIGTERM was never affected, which is why
   it worked from the first attempt.

   Consequence for the earlier round: my original evidence for defect 2 was invalid —
   that test also backgrounded the script, so the INT trap never ran and nothing was
   proven. The defect was real, but only the SIGTERM test above actually demonstrates
   it.

## What surprised me

- **`shellcheck` passed clean on a script that reported failure on every successful
  run and ignored Ctrl-C.** It is a lexical/quoting reviewer — unquoted expansions,
  wrong test syntax, backticks — not a semantic one. It has no model of what a trap's
  return status does to the exit code, or of whether a signal handler terminates.
  "Passes shellcheck" is a floor, not evidence the script is correct; the artifact
  bar (days 11–12) needs run-it-twice and kill-it-mid-run tests on top.
- That an EXIT trap can silently rewrite the exit code of an otherwise correct
  script. The bug is invisible interactively — the output says `Created: ...` and
  looks perfect — and only shows up when something downstream checks `$?`.
- **That `trap ... INT` can be a no-op with no warning whatsoever.** A signal ignored
  when the shell starts cannot be trapped, and bash reports nothing — the line looks
  like working code and isn't. Which context starts the script decides whether its
  own signal handling exists: `&` without job control kills the INT trap, an
  interactive shell or `set -m` doesn't. Directly relevant to how the artifact will
  actually be launched (systemd, cron, a parent script) — the handler has to be
  verified in the launch context that will really be used, not just any context.
- How much a break-it test depends on *when* it interrupts. Interrupting at an idle
  moment proved nothing; interrupting mid-`cp`, with a source file big enough that
  the temp file genuinely exists, is what exposed both the leftover-file question and
  the resume-after-handler bug.

## Checkpoint answers

Answer these out loud, without looking anything up. Write the answer only after
saying it.

1. Why doesn't `set -e` stop the script in `foo | bar` if `foo` fails? What fixes
   this?

   Because a pipeline's exit status is by default the status of its **last** command
   only. `bar` succeeded, so the pipeline reports success and `-e` has nothing to
   react to — `foo`'s failure is swallowed. `set -o pipefail` fixes it: the pipeline
   then reports the rightmost non-zero status, so a failure anywhere in the chain is
   visible to `-e`.

2. `rm -rf "$DIR/"` where `DIR` was never set — what happens, and what saves you?

   Unset `$DIR` expands to nothing, so the command becomes `rm -rf "/"`. `set -u`
   (nounset) saves you: referencing an unset variable becomes an error and the script
   dies before running the command. Two caveats worth knowing:
   - `-u` only catches *unset*, not *set-but-empty* (`DIR=""` passes `-u` fine) —
     an explicit non-empty check is a separate guard: `[[ -n "${DIR:-}" ]]`.
   - GNU `rm` refuses literal `/` by default (`--preserve-root`), so that exact case
     is survivable — but the realistic version isn't: `rm -rf "$DIR/cache"` with
     `DIR` unset becomes `rm -rf "/cache"`, an ordinary path `rm` deletes without
     complaint. `--preserve-root` is not the safety net; `-u` is.

3. Difference between `$(...)` and backticks, beyond readability.

   Backticks apply an extra layer of backslash processing to their contents, so
   escaping inside them behaves differently and unpredictably. `$(...)` nests
   directly (`$(cmd $(cmd))`) while nested backticks require escaping each inner
   level. `$(...)` is the standard form and `shellcheck` warns on every backtick.

## Open questions

- Which signals does a script actually receive when systemd or cron starts it, and is
  anything set to `SIG_IGN` on entry the way `&` does it? Decides whether the artifact's
  signal traps are real code or decoration in the context that matters. Belongs with
  days 11–12, when `artifact-server-bootstrap` needs verified cleanup on interrupt.
- `--` ends option parsing and the remaining arguments are then silently discarded
  rather than rejected. Harmless here (the script takes no positional arguments) but
  the wrong default — should it `die` instead?
- `bats` still not installed anywhere; `shellcheck` turned out to be already present
  on the Pi but not on the workstation. Needed before days 11–12 can claim tests pass.
