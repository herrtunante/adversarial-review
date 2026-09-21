# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Bash orchestrator that runs two AI CLIs (`claude` and `codex`) through a 4-phase adversarial
debate over a *target* project's source code, then has Claude implement the agreed fixes **in that
target project**. This repo holds only the orchestration — it never reviews itself by default.

Status: experimental prototype. No test suite exists yet.

## Commands

There is no build, package manager, or test runner. The only entry point is the script:

```bash
./adversarial_review.sh <target_dir>                 # Full review of another project
./adversarial_review.sh --dry-run <target_dir>       # Stubs out every agent call; safe to run
./adversarial_review.sh -m 5 -v -t 15 <target_dir>   # 5 iterations, verbose, 15m agent timeout
./adversarial_review.sh --status                     # Read tracking.json
./adversarial_review.sh --circuit-status             # Read .circuit_breaker.json
./adversarial_review.sh --reset                      # Wipe artifacts + all state files
./adversarial_review.sh --reset-circuit              # Wipe circuit breaker state only

bash -n adversarial_review.sh lib/*.sh               # Syntax check (fastest smoke test)
shellcheck adversarial_review.sh lib/*.sh            # Lint, if installed
```

Env vars override the flags: `MAX_ITERATIONS`, `TIMEOUT_MINUTES`, `VERBOSE=1`, `DRY_RUN=1`, plus
the circuit-breaker thresholds `CB_NO_PROGRESS_THRESHOLD`, `CB_DISAGREEMENT_THRESHOLD`,
`CB_SAME_ISSUES_THRESHOLD`.

### Environment on this machine (Windows)

The script is bash-only and must run under Git Bash or WSL — not PowerShell/cmd. It does parse and
run there (`bash -n` clean, `--help` works) despite `core.autocrlf=true` giving the `.sh` files
CRLF endings. `shasum` resolves via `/usr/bin/core_perl/shasum`; on Linux it is often absent, where
`sha256sum` is the portable substitute. `claude` and `timeout` both work from bash.

`jq` is installed (jq 1.8.2 via winget) and `check_dependencies` hard-exits without it; on a fresh
machine use `winget install jqlang.jq` or `choco install jq`.

**Bash PIDs are not Windows PIDs.** Git Bash has its own process namespace, so the pid in
`.review.lock` is only meaningful to `ps`/`kill -0` inside bash. PowerShell's `Get-Process` will
report it as gone while the process is alive. Win32 `CommandLine` is also empty for Git Bash
children, so searching Windows process lists for `adversarial_review` finds nothing. Git Bash's own
`ps -ef` is no better for this: it prints every script as a bare `/usr/bin/bash`, so
`ps -ef | grep run_chunked` never matches. Read the command lines from `/proc` instead:

```bash
for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in *run_chunked_review*|*adversarial_review.sh*) echo "${p#/proc/}: $c";; esac; done
```

A running review shows several `adversarial_review.sh` lines; the extras are the subshells that
run each phase's two agents in parallel, not separate reviews.

Two Windows-specific problems have been fixed in the script; don't reintroduce them:

- **The `codex` bash shim is broken here.** A stray `node_modules/node` package under
  `AppData/Roaming/npm/` has a placeholder `bin/node` ("This file intentionally left blank") that
  the shim resolves to. `codex.cmd` works fine, as does codex from PowerShell. Because
  `command -v codex` still succeeds, this used to pass the dependency check and fail mid-review.
  `resolve_codex_bin()` now probes candidates with `--version` and stores the winner in
  `$CODEX_BIN`; `check_dependencies` does the same `--version` probe for `claude`.
- A stale `~/.codex/models_cache.json` makes codex log
  `failed to load models cache: missing field supports_parallel_tool_calls` on startup. Harmless —
  it refetches — but `codex doctor` or deleting that file silences it.

### Agent CLI invocation (verified against codex-cli 0.147.0 / claude 2.1.252)

`claude --print [--dangerously-skip-permissions]` is unchanged and current.

`run_codex()` was written for a pre-0.30 codex (`codex -q --full-auto --prompt "$prompt"`) and has
been rewritten. Three constraints, all load-bearing:

1. **`exec` subcommand.** `-q` and `--prompt` no longer exist, and `--full-auto` is replaced by
   `-s/--sandbox <MODE>`. Codex only ever reviews here — phase 4 (Claude) does all writing — so
   `--sandbox read-only` is the correct level. `--skip-git-repo-check` is needed because targets
   are not necessarily git repos.
2. **Prompt goes on stdin (`-`), never as an argument.** The phase-1 source dump far exceeds the
   ~32KB Windows `CreateProcess` command-line limit.
3. **`-o/--output-last-message` is mandatory, not a nicety.** `codex exec` echoes the entire prompt
   plus a banner to stdout, and the prompt templates contain *example* status blocks. Capturing
   stdout would feed those examples to `parse_status_block`'s `sed` range match and corrupt the
   parse. `-o` writes only the final agent message; the full transcript goes to
   `logs/<artifact>.codex.log`.

## Architecture

### Control flow

`main()` → `run_review_loop()` → up to `MAX_ITERATIONS` passes of phases 1→4. Each phase writes
Markdown artifacts, and the *next* phase's prompt is built by concatenating a template from
`prompts/` with the previous phase's artifact text. Agents never share memory — the artifact files
**are** the entire inter-agent channel.

| Phase | Function | Agents | Reads | Writes |
|---|---|---|---|---|
| 1 Independent review | `run_phase_1` | claude ∥ codex | `collect_source_code` dump | `iter{N}_1_{agent}_review.md` |
| 2 Cross-review | `run_phase_2` | claude ∥ codex | the *other* agent's phase-1 file **+ the source dump** | `iter{N}_2_claude_on_codex.md`, `iter{N}_2_codex_on_claude.md` |
| 3 Meta-review | `run_phase_3` | claude ∥ codex | **its own phase-1 review** + the critique *of it* from phase 2 | `iter{N}_3_{agent}_meta.md` |
| 4 Synthesis | `run_phase_4` | claude only | all six prior artifacts | `iter{N}_4_synthesis.md` |

Because every invocation is a fresh, stateless CLI call, an agent knows nothing it is not handed in
the prompt — including **its own previous output**. That is why phase 3 must re-supply the agent's
phase-1 review: `meta_review.md` asks it to defend or concede specific positions, and without the
original text it can only work from its critic's paraphrase of those positions. For the same reason
phase 2 carries the source dump: `cross_review.md` asks the agent to *verify* findings and to add
issues the other agent missed, neither of which is possible from review prose alone.

Phases 1–3 run their two agents as background jobs and `wait` on both. Phase 4 is the only phase
that **writes code**: it invokes `claude --print --dangerously-skip-permissions` with the target
directory as cwd, so the target project is modified in place with no permission prompts. Treat
running this against a dirty working tree as destructive — the target should be committed first.

### The status-block protocol

Every prompt template ends with a mandated fenced block (`---REVIEW_STATUS---`,
`---CROSS_REVIEW_STATUS---`, `---META_REVIEW_STATUS---`, `---SYNTHESIS_STATUS---`). The script's
`parse_status_block()` `sed`-extracts it, strips `---` lines, and hand-rolls `KEY: value` pairs
into JSON that drives every control decision (loop exit, circuit-breaker input, tracking history).

Consequences worth knowing before editing prompts or the parser:

- **Prompt and parser are one contract.** Renaming a block delimiter or a key in `prompts/*.md`
  silently breaks the loop — a missing block just yields `{"error": "no status block"}`, the
  `// false` jq defaults kick in, and the run continues as if nothing was found.
- The parser coerces `YES`/`FULL` → `true` and `NO`/`LOW` → `false`, so `CONFIDENCE: LOW` lands in
  the JSON as a boolean, not a string.
- `IFS=:` splits on the first colon only, so a `SUMMARY:` containing a colon is truncated.
- A bare `NO_ISSUES` line is a recognized fallback when no block is present.

### Exit conditions

The loop ends when both phase-1 agents report `exit_signal: true`; when phase-4 synthesis reports
`EXIT_SIGNAL: true`; on `MAX_ITERATIONS`; or when the circuit breaker is `OPEN`. Final state lands
in `tracking.json` as `clean` / `circuit_open` / `max_iterations`.

### Circuit breaker (`lib/circuit_breaker.sh`)

A CLOSED → HALF_OPEN → OPEN state machine, fed exactly once per iteration by
`record_iteration_result` at the end of phase 4, from three signals. All three are deliberately
grounded in observable state rather than agent self-report, because each was previously either
unfalsifiable or dead:

- **Progress** — whether `target_state_hash` (a hash of `git status --porcelain` plus staged and
  unstaged diffs in the target) changed across phase 4. `FILES_MODIFIED` from the synthesis block
  is logged for comparison but no longer drives the breaker; it is self-reported, and a missing
  status block parses to `0`, which read as a stall on what was really a parse failure. Non-git
  targets fall back to the self-report with a warning.
- **Consensus** — `CONSENSUS_REACHED` must be `YES` in **both** agents' meta-reviews
  (`consensus_is_yes`). Reading only Claude's let the breaker record agreement while Codex
  dissented.
- **Same issues** — `issues_fingerprint`, the sorted unique set of source-file paths referenced
  across both phase-1 reviews, lowercased with line numbers stripped. Hashing the raw review prose
  (the previous approach) never matched across iterations because LLM wording varies, so this
  trigger could not fire at all. Stripping line numbers matters because they shift as fixes land.

OPEN is terminal and requires `--reset-circuit`; `can_execute` is checked at the top of each
iteration. Note that a `--dry-run` drives the breaker to OPEN, so reset before a real run.

### Agent failure handling

`wait_for_agents` replaces the old `wait $pid || true`. Exit codes are no longer discarded: a
single agent failure logs and degrades, both failing returns `2`, which each phase propagates so
`run_review_loop` halts with `status: agent_failure`. Without this, a crashed or timed-out agent
produced an artifact with no status block, which parses to zero issues and is indistinguishable
from a clean review — the loop would burn every remaining iteration on empty input.

### Source collection is the main scope limit

`collect_source_code()` builds one flat text dump and is the only thing the agents see in phase 1
— they do get the target as cwd, but the prompt itself is this dump. It walks **Java, Python and
TS/JS at `MAX_SOURCE_FILES` each (default 30) and shell at `MAX_SOURCE_SHELL_FILES` (default 10)**,
truncating to `MAX_SOURCE_LINES` / `MAX_SOURCE_SHELL_LINES` (500 / 300). Any other language (Go,
Rust, C…) is still invisible. Widening coverage or the caps happens here and directly drives prompt
size and cost.

`MAX_SOURCE_EXCLUDE` is an extended regex matched against each **absolute** path; matches are
dropped *before* the cap applies, so vendored or generated trees don't consume the file budget.
This is the only scoping lever the collector has — it can subtract but never restrict to a subtree,
which is why `run_chunked_review.sh` has to enumerate the complement of what it wants to keep.

Two caps-related gotchas:

- The find for TS/JS excludes `node_modules` but **not** `target/`, `dist/` or `build/`. On a Maven
  webapp the alphabetically-first matches are all vendored copies under `*/target/`, so without an
  exclude the entire JS budget is spent on build output. The Java find does exclude `target/`.
- The list is `sort`ed by path, so an over-budget tree is not sampled, it is truncated from the
  front. On a 1,600-file project the default caps show the agents the same alphabetically-first 30
  files every run.

### Reviewing a project too large for one dump

`run_chunked_review.sh` drives `adversarial_review.sh` over a big multi-module target one chunk at
a time, and `aggregate_review.sh` merges the per-chunk synthesis reports into one document.

```bash
./run_chunked_review.sh --target ../collect --list chunks/collect.manifest      # plan + sizes only
./run_chunked_review.sh --target ../collect -t 15 -o reviews/run1 chunks/collect.manifest
./run_chunked_review.sh --target ../collect --resume -o reviews/run1 chunks/collect.manifest
./aggregate_review.sh reviews/run1                                             # -> REPORT.md
```

A manifest line is `chunk_id | module_root | include_path[,include_path...]`. The module root
becomes the agents' cwd, so they keep that module's build file in view; the include paths are
everything the dump is allowed to contain.

Things the driver has to do because state in this repo is global, not per-run:

- `artifacts/` is named `iter{N}_...` with no chunk in the name, so chunk N+1 overwrites chunk N.
  The driver copies `artifacts/`, `logs/` and `tracking.json` into `<out>/<chunk_id>/` after each
  chunk, then empties `artifacts/` and the `iter*` logs itself before the next.
- **It must never call `--reset` between chunks.** `reset_all()` deletes `.review.lock`, which is
  the only thing stopping a second review from interleaving in `artifacts/`. Calling it per chunk
  once let two drivers run at the same time: one chunk's report was built from another package's
  prompt and still carried a valid status block. `reset_all()` now refuses while a live pid holds
  the lock, and the driver aborts if it finds one.
- The circuit breaker persists across invocations and OPEN is terminal, so the driver calls
  `--reset-circuit` per chunk. Without it one stalled chunk blocks every later one.
- Chunks default to `--no-fix`. Twenty unattended synthesis passes writing into a shared target is
  not something to start by accident; `--fix` opts in.

A chunk is only archived as done if it survives three checks, and `--resume` redoes any chunk
whose phase-4 report lacks a real `SYNTHESIS_STATUS` block (a `tracking.json` alone proves
nothing):

- **Transient failure.** A quota refusal or a dropped network does not stop a phase. The agent
  writes a one-line error in place of the review, which parses to zero issues and looks exactly
  like clean code. `artifact_is_transient_failure` recognises two shapes: a short file (under 2 KB)
  holding a quota or connection error, or a Codex transcript (copied in by `run_codex`'s fallback)
  with timestamped transport `ERROR` lines. The broad phrases are only trusted in short files; in
  a full review they match findings about rate limiting. On a hit the driver waits for
  `claude --print` to answer a probe (every 5 minutes, up to 2 hours) and redoes the chunk.
- **Scope contamination.** The Codex transcript echoes the prompt, so its `=== FILE:` markers are a
  record of what the agent was really shown. Any path the chunk's exclude regex would have dropped
  means the artifacts came from another run.
- **Salvage.** If only synthesis failed, the six debate artifacts are kept and the retry runs
  `adversarial_review.sh --from-phase 4`, costing one agent call instead of seven.
  `verify_resume_artifacts` refuses to start mid-run if any earlier artifact is missing or under
  200 bytes.

Long runs outlive the harness: a background task can be killed for "low memory" while the review
underneath keeps going. Start the driver with `nohup ... &` writing to a log, and check `/proc` for
a live driver (see the Windows notes above) before starting another. `.review.lock` alone does not
prove the coast is clear: it is held by `adversarial_review.sh`, so it is absent in the gap between
two chunks while the driver is still alive.

For an unattended run, start `supervise_review.sh` instead of the driver. The driver gives up after
two hours without a working agent CLI, which an overnight quota reset or a sleeping laptop easily
exceeds. The supervisor restarts it with `--resume` until every chunk has a real synthesis report,
and waits for any driver already running rather than starting a second. A saved debate sits beside
the chunk directory as `<out>/.salvage-<chunk>/`, so it survives those restarts. To change the
driver while a run is live, stage the new version as `run_chunked_review.next.sh`; the supervisor
installs it only in the gap between driver runs, because bash reads a script as it executes and an
in-place edit can corrupt the running copy.

```bash
nohup ./supervise_review.sh --target ../collect -o reviews/run1 chunks/collect.manifest >/dev/null 2>&1 &
```

To review two targets at once, run the second from a separate `git worktree`. All state lives in
the script's own directory, so a second checkout gets its own `artifacts/`, lock and breaker. Both
runs still draw on the same Claude session quota.

Sizing: aim for 150–350 KB of source per chunk. Phase 2 sends the dump *plus* the other agent's
review, so the real prompt is larger than the chunk. Cost is ~7 agent calls per chunk per
iteration.

An include path also pulls in the loose source files sitting in each of its ancestor directories.
Splitting a package whose root holds most of the code therefore duplicates that code across both
halves rather than dividing it.

## Known Traps

- **`-p/--prompt` is destructive**: it `cp`s your file *over* `prompts/initial_review.md`,
  permanently replacing the repo's template. Check `git status` after using it.
- **Every phase must pass `target_dir` to `run_claude`/`run_codex`.** The third argument defaults
  to `${3:-$PWD}`, which is the *invocation* directory, not the target. Phases 2 and 3 used to omit
  it, so cross-review and meta-review ran against this repo instead of the code under review.
- **`lib/circuit_breaker.sh` and `lib/response_analyzer.sh` each assign `SCRIPT_DIR`**, clobbering
  the main script's. Currently harmless because the main script derives `LIB_DIR`/`PROMPTS_DIR`
  before sourcing — but don't add a post-source use of `SCRIPT_DIR`.
- **`lib/response_analyzer.sh` is dead code.** It is sourced, but none of `analyze_response`,
  `compare_responses`, `analyze_cross_review`, or `store_analysis` are ever called; the main script
  uses its own `parse_status_block` and `issues_fingerprint` instead. Same for
  `format_duration`/`get_epoch_seconds` in `date_utils.sh`. Wire them in or delete them rather than
  assuming they run.
- **Hash via the `sha256_hash` helper**, not `shasum` directly — it falls back across
  `sha256sum`/`shasum`/`cksum` so the circuit breaker works on Linux, macOS, and Git Bash alike.
- **`set -e` + `((i++))`**: incrementing from 0 returns exit 1 and would kill the script. Existing
  code uses `((iteration++)) || true`; keep that pattern.
- Timeouts go through `get_timeout_cmd`, preferring `gtimeout` (macOS coreutils) then `timeout`.
  With neither, agent calls run unbounded — only a warning is printed.
- Cost: ~7 agent invocations per iteration (2+2+2+1), so a default 3-iteration run is ~21 calls.
  No cost tracking exists. Use `--dry-run` for anything structural.

## Adding a Third Agent

Add `run_gemini()` mirroring `run_claude()`; launch it alongside the others in phases 1–3; extend
cross-review to N-way pairings (phases 2 and 3 currently hardcode the two-file swap); and extend
the phase-4 context concatenation. `prompts/cross_review.md` and `meta_review.md` assume exactly
one "other agent" and would need rewording.

## State Files

`tracking.json` (iteration, status, target, append-only `history[]`), `.circuit_breaker.json`,
`.circuit_breaker_history.json`, `.response_analysis.json`, `artifacts/`, `logs/` — all gitignored
and regenerated. `artifacts/iter{N}_{phase}_{agent}_{type}.md` is the naming convention.

## Reference

Based on [asimov-ralph](https://github.com/frankbria/ralph-claude-code); debate approach follows
[D3](https://arxiv.org/abs/2410.04663) and [ChatEval](https://github.com/thunlp/ChatEval).
