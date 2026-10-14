---
name: adversarial-review
description: Run the Claude + Codex adversarial code review from this repository on a target project (a whole directory, a chunk manifest, or file lists), keep it running in the background, and summarize the report when it finishes. Use when the user asks to review a project or some files with adversarial review, to start, resume, check on or summarize such a review, or to plan chunks for one.
---

# Run an adversarial review

You are operating the scripts in this repository on the user's behalf. The scripts
call `claude` and `codex` themselves; your job is to pick the scope, start the run
correctly, watch it, and report the result. Arguments, if any: `$ARGUMENTS`.

The full user guide is `docs/GUIDE.md`; `CLAUDE.md` explains the internals.

## Rules

- **Report-only unless the user explicitly asks for fixes.** Never add `--fix` on
  your own. If they do ask, the target must be a git repository with a clean
  working tree (`git -C <target> status --porcelain` prints nothing); if it is not,
  stop and say so.
- **Never run `--reset` while a review or driver is running**, and never delete
  `.review.lock` or `.driver.lock/` yourself.
- **One run per checkout.** Before starting, check that nothing is running:
  `ls .driver.lock/pid .review.lock 2>/dev/null` and, if either exists, whether its
  pid is alive (`kill -0 <pid>`). If something is running, report it and stop.
- **Runs take a long time** (tens of minutes per chunk, hours for a large
  project). Always start them detached with `nohup ... &` and a log file, never in
  the foreground: a foreground command is killed by your tool timeout.
- Each review costs about 7 agent calls per chunk on the user's Claude and Codex
  quotas. Before a chunked run, tell the user how many chunks it is and get a go-ahead.

## 1. Preflight

```bash
cd <this repository>
claude --version && codex --version && jq --version
bash -n adversarial_review.sh lib/*.sh
```

If `codex --version` fails, stop and tell the user to install or log in to Codex
(`npm install -g @openai/codex`, then `codex login`).

## 2. Choose the scope

| The user wants to review | Use |
|---|---|
| One small or medium project (up to ~300 KB of source) | `./adversarial_review.sh <target>` |
| Only uncommitted changes | `./adversarial_review.sh --changed-only <target>` |
| Specific files | a file list + `bash run_filelist_review.sh` |
| A large multi-module project | a manifest in `chunks/` + `bash supervise_review.sh` |

For a manifest, always plan first and show the user the plan:

```bash
bash run_chunked_review.sh --target <target> --list chunks/<name>.manifest
```

Warnings about file caps or chunk sizes over ~350 KB mean the manifest needs
editing before a real run. A new manifest line is
`chunk_id | module_root | include_path[,include_path...]`; copy the style of the
existing files in `chunks/`.

## 3. Start it detached

Pick a name for the run (for example the target's directory name plus the date)
and use it for the output directory and the log.

```bash
mkdir -p reviews
# single target
nohup ./adversarial_review.sh -t 15 <target> > reviews/<run>.log 2>&1 &
# file lists (report-only, resumable by re-running the same command)
nohup bash run_filelist_review.sh --target <target> -o reviews/<run> chunks/<dir>/*.files > reviews/<run>.log 2>&1 &
# large project, unattended (restarts itself across quota resets)
nohup bash supervise_review.sh --target <target> -o reviews/<run> chunks/<name>.manifest > /dev/null 2>&1 &
```

Tell the user the command you ran, where the log is, and how to check on it.

## 4. Check on it

- Single target: `./adversarial_review.sh --status` and `tail -n 20 reviews/<run>.log`.
- Chunked: `cat reviews/<run>/index.tsv` (one row per finished chunk) and
  `tail -n 20 reviews/<run>/driver.log`; the supervisor writes `supervise.log`.
- A run is alive while its pid is: check `.review.lock` / `.driver.lock/pid` with
  `kill -0`.

If the user wants you to keep watching, use `/loop` (for example every 30 minutes)
rather than sleeping in a shell command.

## 5. Report the result

Exit statuses (`tracking.json` → `status`):

| Status | Meaning |
|---|---|
| `report_only` | finished; the report is `artifacts/iter1_4_synthesis.md` |
| `clean` | both agents found nothing at MEDIUM or above |
| `agent_failure` | an agent call failed (quota, network, timeout) - see `logs/` |
| `empty_scope` | the source dump was empty - wrong path or scope settings |
| `max_iterations`, `circuit_open` | fix mode only |

For a single run, copy the report out of `artifacts/` straight away
(`cp artifacts/iter1_4_synthesis.md reviews/<run>-report.md`): the next run clears
`artifacts/`. For a chunked run, build the merged report:

```bash
bash aggregate_review.sh reviews/<run>      # writes reviews/<run>/REPORT.md
```

Then summarize for the user: the "Issues to fix" in severity order (title,
location, one line each), the number of disputed and rejected items, and which
chunks failed or were not reviewed. Before calling any CRITICAL or HIGH finding
real, open the cited lines yourself and say whether you agree. Offer to fix
specific findings; do not fix anything unasked.

## 6. If it failed

- `agent_failure` with a quota message: wait for the quota to reset, then re-run.
  Chunked runs resume with the same command plus `--resume` (the supervisor does
  this by itself).
- Only the synthesis failed in a single run: `./adversarial_review.sh --from-phase 4 <target>`
  redoes one call instead of seven.
- `Circuit breaker is OPEN`: `./adversarial_review.sh --reset-circuit`, then re-run.
- Anything else: show the user the last lines of the log and the failing
  artifact's `logs/*.claude.log` or `logs/*.codex.log`.
