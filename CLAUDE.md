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

**One remaining prerequisite: `jq` is not installed.** `check_dependencies` hard-exits without it.
`choco install jq` or `winget install jqlang.jq`.

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
| 2 Cross-review | `run_phase_2` | claude ∥ codex | the *other* agent's phase-1 file | `iter{N}_2_claude_on_codex.md`, `iter{N}_2_codex_on_claude.md` |
| 3 Meta-review | `run_phase_3` | claude ∥ codex | the critique *of them* from phase 2 | `iter{N}_3_{agent}_meta.md` |
| 4 Synthesis | `run_phase_4` | claude only | all six prior artifacts | `iter{N}_4_synthesis.md` |

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
`record_iteration_result` at the end of phase 4, from three signals: `FILES_MODIFIED` from the
synthesis block, `CONSENSUS_REACHED` from Claude's meta-review, and a SHA-256 of the two phase-1
review files (identical hash across iterations ⇒ "same issues"). OPEN is terminal and requires
`--reset-circuit`; `can_execute` is checked at the top of each iteration.

### Source collection is the main scope limit

`collect_source_code()` builds one flat text dump and is the only thing the agents see in phase 1
— they do get the target as cwd, but the prompt itself is this dump. It is capped at **30 Python
files, 30 TS/JS files, and 10 shell scripts, truncated to the first 500 lines each (300 for
shell)**. Any other language (Go, Rust, Java, C…) is invisible to the review. Widening language
coverage or the caps happens here, and directly drives prompt size and cost.

## Known Traps

- **`-p/--prompt` is destructive**: it `cp`s your file *over* `prompts/initial_review.md`,
  permanently replacing the repo's template. Check `git status` after using it.
- **Phases 2 and 3 call `run_claude`/`run_codex` without the working-dir argument**, so they
  default to `$PWD` (this repo) rather than the target. Only phases 1 and 4 run in the target.
- **`lib/circuit_breaker.sh` and `lib/response_analyzer.sh` each assign `SCRIPT_DIR`**, clobbering
  the main script's. Currently harmless because the main script derives `LIB_DIR`/`PROMPTS_DIR`
  before sourcing — but don't add a post-source use of `SCRIPT_DIR`.
- **`lib/response_analyzer.sh` is dead code.** It is sourced, but none of `analyze_response`,
  `compare_responses`, `analyze_cross_review`, or `store_analysis` are ever called; the main script
  uses its own `parse_status_block` instead. Same for `format_duration`/`get_epoch_seconds` in
  `date_utils.sh`. Wire them in or delete them rather than assuming they run.
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
