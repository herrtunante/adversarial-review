# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Bash orchestrator that runs two AI CLIs (`claude` and `codex`) through a 4-phase adversarial
debate over a *target* project's source code and writes a report of the agreed fixes. With `--fix`
Claude also implements them **in that target project**. This repo holds only the orchestration — it never reviews itself by default.

Status: experimental prototype. No test suite exists yet.

## Commands

There is no build, package manager, or test runner. The only entry point is the script:

```bash
./adversarial_review.sh <target_dir>                 # Review another project, report only (default)
./adversarial_review.sh --fix <target_dir>           # Review, then let Claude edit the target
./adversarial_review.sh --dry-run <target_dir>       # Stubs out every agent call; safe to run
./adversarial_review.sh -m 5 -v -t 15 <target_dir>   # 5 iterations, verbose, 15m agent timeout
./adversarial_review.sh --status                     # Read tracking.json
./adversarial_review.sh --circuit-status             # Read .circuit_breaker.json
./adversarial_review.sh --reset                      # Wipe artifacts + all state files
./adversarial_review.sh --reset-circuit              # Wipe circuit breaker state only

bash -n adversarial_review.sh lib/*.sh               # Syntax check (fastest smoke test)
shellcheck adversarial_review.sh lib/*.sh            # Lint, if installed
```

Report-only is the default since the self-review of October 2026; fixing needs `--fix` (or
`NO_FIX=0`), and `--no-fix` is still accepted. A report-only run is one iteration, 7 agent calls.
`-m` and `-t` must be positive integers, and a flag missing its value is an error.

Env vars override the flags: `MAX_ITERATIONS`, `TIMEOUT_MINUTES`, `VERBOSE=1`, `DRY_RUN=1`,
`NO_FIX` (0 or 1), `FROM_PHASE`, `CODEX_BIN` (used as given; the run stops if it does not answer
`--version`), `FIX_MODE_TOOLS` (the tool list for fix mode), plus
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

### Agent CLI invocation (verified against codex-cli 0.147.0 / claude 2.1.296)

Phases 1 to 3 and a report-only phase 4 run plain `claude --print`. Fix mode runs
`claude --print --tools Read,Grep,Glob,Edit,Write --allowedTools Read,Grep,Glob,Edit,Write`:
`--tools` removes the shell, `--allowedTools` pre-approves the rest. It replaced
`--dangerously-skip-permissions`, because the phase-4 prompt quotes the target's source and a
comment planted there could reach an agent with unrestricted shell access. The cost is that the
fixing agent cannot run tests or git, and an allowlist is not filesystem containment: use `--fix`
only on code you trust.

Claude's stderr goes to `logs/<artifact>.claude.log`, never into the artifact. A Claude call that
exits non-zero or prints nothing leaves `CLAUDE PRODUCED NO OUTPUT (exit code N)` as the artifact's
first line, with the matching error lines under it, the same way `run_codex` leaves its note.

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
   stdout would hand those examples to `parse_status_block`, which would take one as the agent's
   status whenever the real block is missing. `-o` writes only the final agent message; the full transcript goes to
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
that can **write code**, and only with `--fix`: it then runs Claude with the edit-only tool list and
the target directory as cwd, so the target project is modified in place with no permission prompts.
Treat running `--fix` against a dirty working tree as destructive — the target should be committed first.

### The status-block protocol

Every prompt template ends with a mandated fenced block (`---REVIEW_STATUS---`,
`---CROSS_REVIEW_STATUS---`, `---META_REVIEW_STATUS---`, `---SYNTHESIS_STATUS---`). The script's
`parse_status_block()` takes the last complete block in the file (an earlier one can be an example
quoted in prose) and builds JSON from its `KEY: value` pairs with `jq`, so any summary text gives
valid JSON. That JSON drives every control decision (loop exit, circuit-breaker input, tracking
history). An unterminated block counts as no block.

Consequences worth knowing before editing prompts or the parser:

- **Prompt and parser are one contract.** Renaming a block delimiter or a key in `prompts/*.md`
  silently breaks the loop — a missing block just yields `{"error": "no status block"}`, the
  `// false` jq defaults kick in, and the run continues as if nothing was found.
- The parser coerces `YES`/`FULL` → `true` and `NO`/`LOW` → `false`, so `CONFIDENCE: LOW` lands in
  the JSON as a boolean, not a string.
- A bare `NO_ISSUES` line is a recognized fallback when no block is present.

### Exit conditions

The loop ends when both phase-1 agents report `exit_signal: true`; when phase-4 synthesis reports
`EXIT_SIGNAL: true`; on `MAX_ITERATIONS`; or when the circuit breaker is `OPEN`. Final state lands
in `tracking.json` as `clean` / `circuit_open` / `max_iterations`, or `report_only` for a `--no-fix`
run. Two more statuses mean the run did not do its job, and both exit non-zero: `agent_failure` (see
below) and `empty_scope` (the source dump was empty, so no agent was called; a review of nothing
used to be recorded as `clean`).

### Circuit breaker (`lib/circuit_breaker.sh`)

A CLOSED → HALF_OPEN → OPEN state machine, fed exactly once per iteration by
`record_iteration_result` at the end of phase 4, from three signals. All three are deliberately
grounded in observable state rather than agent self-report, because each was previously either
unfalsifiable or dead:

- **Progress** — whether `target_state_hash` (a hash of `HEAD`, `git status --porcelain`, the staged
  and unstaged diffs and the content of untracked files in the target) changed across phase 4, so a
  commit by the agent or an edit to an untracked file counts. `FILES_MODIFIED` from the synthesis block
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

Any of the three can open the breaker, from CLOSED or from HALF_OPEN. Before, HALF_OPEN only
tested progress, so persistent disagreement could never open it with the default thresholds.

OPEN is terminal and requires `--reset-circuit`; `can_execute` is checked at the top of each
iteration. Note that a `--fix --dry-run` drives the breaker to OPEN, so reset before a real run; a
report-only run returns before the breaker is fed. The counters and the issues hash are reset at the
start of a run whose target differs from the previous one, unless the breaker is OPEN.

### Agent failure handling

`wait_for_agents` replaces the old `wait $pid || true`. Exit codes are no longer discarded: a
single agent failure logs and degrades, both failing returns `2`, which each phase propagates so
`run_review_loop` halts with `status: agent_failure`. A synthesis that fails, or writes no complete
status block, ends the same way in report-only mode instead of as `report_only`. Without this, a crashed or timed-out agent
produced an artifact with no status block, which parses to zero issues and is indistinguishable
from a clean review — the loop would burn every remaining iteration on empty input.

On INT or TERM the script kills its agents, releases the lock and exits 130 or 143. Only the
process that took the lock removes it. The trap used to delete the lock and let the loop carry on
unlocked. Started with `nohup ... &` from a non-interactive shell, INT is inherited as ignored, so
stop such a run with TERM. Native children that Git Bash cannot see (node under `codex.cmd`) may
outlive the stop.

### Source collection is the main scope limit

`collect_source_code()` builds one flat text dump and is the only thing the agents see in phase 1
— they do get the target as cwd, but the prompt itself is this dump. It walks **Java, Python and
TS/JS at `MAX_SOURCE_FILES` each (default 30) and shell at `MAX_SOURCE_SHELL_FILES` (default 10)**,
truncating to `MAX_SOURCE_LINES` / `MAX_SOURCE_SHELL_LINES` (500 / 300). The path filters (hidden
directories, `node_modules`, `target/`, `build/`) are tested against the path relative to the
target, so a target that itself sits under a dot directory or a `build/` folder still yields its
files, and the driver's `--list` estimate selects files the same way the collector does. A file cut at the cap carries a
`FILE TRUNCATED BY THE REVIEW TOOL` line in the dump, so agents know they saw only part of it. Any other language (Go,
Rust, C…) is still invisible. Widening coverage or the caps happens here and directly drives prompt
size and cost.

`MAX_SOURCE_EXCLUDE` is an extended regex matched against each **absolute** path; matches are
dropped *before* the cap applies, so vendored or generated trees don't consume the file budget.
This is the only scoping lever the collector has — it can subtract but never restrict to a subtree,
which is why `run_chunked_review.sh` has to enumerate the complement of what it wants to keep.

`SOURCE_FILE_LIST` is the other lever, and the only one that restricts: it names a file holding one
path per line (relative to the target; blank lines and `#` comments ignored), and the dump is then
exactly those files, in that order. The directory walk, the per-language caps and
`MAX_SOURCE_EXCLUDE` are all skipped; only `MAX_SOURCE_LINES` still applies, so raise it if any
listed file is longer than 500 lines. Any file type is accepted, which also makes it the way to
review a language the walk ignores. A listed path that does not exist is warned about and skipped;
if every path is missing the run stops with `empty_scope`.

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
everything the dump is allowed to contain. An empty include, or `.`, means the whole module, and a
trailing slash makes no difference. An include that is not an existing directory fails its chunk;
it used to shrink the chunk silently, so run `--list` after editing a manifest.

The manifest is validated before anything is created or deleted. A chunk id must be a plain name
(letters, digits, `.`, `_`, `-`, no `..`, not starting with `.` or `-`) because it names a directory
the driver removes and rewrites, and ids must be unique. `run_filelist_review.sh` applies the same
rule to the list file names it takes its ids from.

The driver exits 0 only when every selected chunk is reviewed or was recorded as empty, 1 for bad
arguments or a bad manifest, and 2 when one or more chunks failed. It used to exit 0 regardless.

Things the driver has to do because state in this repo is global, not per-run:

- `artifacts/` is named `iter{N}_...` with no chunk in the name, so chunk N+1 overwrites chunk N.
  The driver copies `artifacts/`, `logs/` and `tracking.json` into `<out>/<chunk_id>/` after each
  chunk, then empties `artifacts/` and the `iter*` logs itself before the next.
- **It must never call `--reset` between chunks.** `reset_all()` deletes `.review.lock`, which is
  the only thing stopping a second review from interleaving in `artifacts/`. Calling it per chunk
  once let two drivers run at the same time: one chunk's report was built from another package's
  prompt and still carried a valid status block. `reset_all()` now refuses while a live pid holds
  the lock, and the driver aborts if it finds one.
- **The driver holds its own lock for the whole run.** `.review.lock` belongs to
  `adversarial_review.sh` and is absent in the gap between two chunks, exactly when the driver
  clears and archives `artifacts/`. So the driver and `run_filelist_review.sh` take `.driver.lock/`
  (a directory made with `mkdir`, holding `pid`) and export `AR_DRIVER_LOCK_PID` to the reviews
  they start. A second driver or wrapper exits 4. `adversarial_review.sh` refuses to start, dry
  runs included, while a live `.driver.lock` names a pid that is neither `$AR_DRIVER_LOCK_PID` nor
  its parent. A lock whose pid is dead is taken over. On INT or TERM the driver stops its review,
  releases the lock and exits 130 or 143.
- The circuit breaker persists across invocations and OPEN is terminal, so the driver calls
  `--reset-circuit` per chunk. Without it one stalled chunk blocks every later one.
- Chunks default to report-only. Twenty unattended synthesis passes writing into a shared target is
  not something to start by accident; `--fix` opts in, and the driver passes `--fix` or `--no-fix`
  to every review explicitly.

`chunk_is_reviewed` in `lib/transient.sh` is the one answer to "is this chunk reviewed?", shared by
the driver, the supervisor, the file-list wrapper and the aggregator. The newest synthesis report
(by iteration number) must hold a complete `SYNTHESIS_STATUS` block, and no artifact may be a failed
agent call: a quota or connection error, an empty file, or the `CODEX PRODUCED NO FINAL MESSAGE`
note `run_codex` writes when Codex gives no answer, whatever the cause. A chunk both agents found
clean in phase 1 has no synthesis; it counts through `status: clean` in its `tracking.json`.
`--resume` redoes any chunk the function rejects.

A chunk is only archived as done if it also survives three checks:

- **Transient failure.** A quota refusal or a dropped network does not stop a phase. The agent
  writes a one-line error in place of the review, which parses to zero issues and looks exactly
  like clean code. `artifact_is_transient_failure` recognises two shapes: a short file (under 2 KB)
  holding a quota or connection error, or Codex's timestamped transport `ERROR` lines. The broad
  phrases are only trusted in short files; in a full review they match findings about rate
  limiting. A short file with a complete status block or a bare `NO_ISSUES` is a real answer and is
  never treated as a refusal. On a hit the driver waits
  until BOTH agent CLIs answer a small probe (every 5 minutes, up to 2 hours) and redoes the chunk;
  probing Claude alone returned at once whenever Codex was the refused one.
- **Any other failed call.** A Codex timeout, or a Claude call that printed nothing, is a failed
  call but not a transient one. The chunk is redone within the same run, up to three attempts,
  with no quota wait, and is recorded as `agent_failure` if it never succeeds.
- **Scope contamination.** The Codex transcript echoes the prompt, so its `=== FILE:` markers are a
  record of what the agent was really shown. Any path the chunk's exclude regex would have dropped
  means the artifacts came from another run.
- **Salvage.** If only synthesis failed, the six debate artifacts are kept and the retry runs
  `adversarial_review.sh --from-phase 4`, costing one agent call instead of seven. A debate with
  any failed call in it is not salvaged. `verify_resume_artifacts` refuses to start mid-run if an
  earlier artifact is missing, under 200 bytes or a failure note, or if `artifacts/scope.stamp`
  does not match. Phase 1 writes that stamp (the canonical target path and a hash of the source
  dump) so a saved debate cannot be resumed against another target or changed source; the same
  `MAX_SOURCE_*`, exclude and file-list settings are therefore needed to resume. Debates saved
  before the stamp existed are refused, and the driver then reruns the chunk in full.

Long runs outlive the harness: a background task can be killed for "low memory" while the review
underneath keeps going. Start the driver with `nohup ... &` writing to a log, and check `/proc` for
a live driver (see the Windows notes above) before starting another. `.review.lock` alone does not
prove the coast is clear: it is held by `adversarial_review.sh`, so it is absent in the gap between
two chunks while the driver is still alive. `.driver.lock/pid` does cover that gap; if a crashed
driver's pid was reused by an unrelated process the lock looks live, and the directory has to be
removed by hand.

For an unattended run, start `supervise_review.sh` instead of the driver. The driver gives up after
two hours without a working agent CLI, which an overnight quota reset or a sleeping laptop easily
exceeds. The supervisor restarts it with `--resume` until `chunk_is_reviewed` accepts every chunk the
driver would run, and waits for any driver already running rather than starting a second. It
respects `--only`, does not count chunks the driver recorded as empty, and gives up on chunks that
still fail after two extra passes. `--target`, `-o` and the manifest are resolved from the
directory it was started in. A manifest the driver rejects (exit 1) is not told apart from a crash,
so the supervisor retries it every five minutes; check the manifest with `--list` first. A saved debate sits beside
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

When a manifest cannot express the split (all the code is in one directory, or the files are
scattered across directories or repos), use `run_filelist_review.sh` with one `SOURCE_FILE_LIST`
file per chunk. It archives each chunk the same way, skips chunks `chunk_is_reviewed` accepts, and
runs `aggregate_review.sh` at the end. It is report-only and simpler than the driver: a few retries
per chunk, no waiting out a quota reset, no salvage. It takes the same `.driver.lock` (exit 4 if a
driver or another wrapper holds it) and does not retry a chunk that ended as `empty_scope`.

```bash
nohup ./run_filelist_review.sh --target ../whisp -o reviews/whisp chunks/whisp/*.files > reviews/whisp.log 2>&1 &
```

Sizing: aim for 150–350 KB of source per chunk. Phase 2 sends the dump *plus* the other agent's
review, so the real prompt is larger than the chunk. Cost is ~7 agent calls per chunk per
iteration.

An include path also pulls in the loose source files sitting in each of its ancestor directories.
Splitting a package whose root holds most of the code therefore duplicates that code across both
halves rather than dividing it.

## Known Traps

- **`-p/--prompt FILE` applies to that run only.** It used to copy the file over
  `prompts/initial_review.md`, permanently replacing the repo's template; it now reads the file as
  the phase-1 template and touches nothing. A missing file stops the run.
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
- Cost: ~7 agent invocations per iteration (2+2+2+1), so the default report-only run is 7 calls and a 3-iteration `--fix` run is ~21.
  No cost tracking exists. Use `--dry-run` for anything structural.

## Adding a Third Agent

Add `run_gemini()` mirroring `run_claude()`; launch it alongside the others in phases 1–3; extend
cross-review to N-way pairings (phases 2 and 3 currently hardcode the two-file swap); and extend
the phase-4 context concatenation. `prompts/cross_review.md` and `meta_review.md` assume exactly
one "other agent" and would need rewording.

## State Files

`tracking.json` (iteration, status, target, append-only `history[]`), `.circuit_breaker.json`,
`.circuit_breaker_history.json`, `.response_analysis.json`, `artifacts/` (with `scope.stamp`),
`logs/` (with `*.codex.log` and `*.claude.log`), and the locks `.review.lock`,
`.review.lock.recover/` and `.driver.lock/` — all gitignored and regenerated. `artifacts/iter{N}_{phase}_{agent}_{type}.md` is the naming convention.

## Reference

Based on [asimov-ralph](https://github.com/frankbria/ralph-claude-code); debate approach follows
[D3](https://arxiv.org/abs/2410.04663) and [ChatEval](https://github.com/thunlp/ChatEval).
