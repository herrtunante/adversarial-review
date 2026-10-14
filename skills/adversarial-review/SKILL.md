---
name: adversarial-review
description: Run the Claude + Codex adversarial code review on a target project (a whole directory, uncommitted changes, a chunk manifest, or file lists), keep it running in the background, and summarize the report when it finishes. Use when the user asks to review a project or some files with adversarial review, to start, resume, check on or summarize such a review, or to plan chunks for one.
---

# Run an adversarial review

You are operating the adversarial-review scripts on the user's behalf. The scripts
call `claude` and `codex` themselves; your job is to pick the scope, start the run
correctly, watch it, and report the result. Arguments, if any: `$ARGUMENTS`.

## 0. Find the three locations

Every command below uses three directories. Work them out once, write them down
for yourself, and put the real paths in place of `<tool>`, `<state>` and
`<reports>` in every command.

The tool directory reads: `${CLAUDE_PLUGIN_ROOT}`

- **If that line shows a real path**, this skill was installed as a Claude Code
  plugin:
  - `<tool>` = that path (it holds `adversarial_review.sh`). Never write into it:
    every plugin update replaces it.
  - `<state>` = `${CLAUDE_PLUGIN_DATA}` (survives plugin updates).
  - `<reports>` = `~/adversarial-reviews`, unless the user names another place.
- **If it shows the placeholder text itself** (a dollar sign and braces), you are in
  a clone of the repository:
  - `<tool>` = the repository root (the directory with `adversarial_review.sh`).
  - `<state>` = `<tool>`.
  - `<reports>` = `<tool>/reviews`.

Shell variables do not carry over between your commands, so put
`AR_STATE_DIR="<state>"` in front of **every** command that runs one of the
scripts. User guide: `<tool>/docs/GUIDE.md`; internals: `<tool>/CLAUDE.md`.

## Rules

- **Report-only unless the user explicitly asks for fixes.** Never add `--fix` on
  your own. If they do ask, the target must be a git repository with a clean
  working tree (`git -C <target> status --porcelain` prints nothing); if it is not,
  stop and say so.
- **Never run `--reset` while a review or driver is running**, and never delete
  `<state>/.review.lock` or `<state>/.driver.lock/` yourself.
- **One run at a time per state directory.** Before starting, check
  `ls <state>/.driver.lock/pid <state>/.review.lock 2>/dev/null` and, if either
  exists, whether its pid is alive (`kill -0 <pid>`). If something is running,
  report it and stop.
- **Runs take a long time** (tens of minutes per chunk, hours for a large
  project). Always start them detached with `nohup ... &` and a log file, never in
  the foreground: a foreground command is killed by your tool timeout.
- Each review costs about 7 agent calls per chunk on the user's Claude and Codex
  quotas. Before a chunked run, tell the user how many chunks it is and get a go-ahead.

## 1. Preflight

```bash
claude --version && codex --version && jq --version
bash -n <tool>/adversarial_review.sh
mkdir -p <reports>
```

If `codex --version` fails, stop and tell the user to install or log in to Codex
(`npm install -g @openai/codex`, then `codex login`). If `jq` is missing, ask them to
install it.

## 2. Choose the scope

| The user wants to review | Use |
|---|---|
| One small or medium project (up to ~300 KB of source) | `adversarial_review.sh <target>` |
| Only uncommitted changes | `adversarial_review.sh --changed-only <target>` |
| Specific files | a file list + `run_filelist_review.sh` |
| A large multi-module project | a manifest + `supervise_review.sh` |

Write new manifests and file lists under `<reports>/chunks/`, never under `<tool>`.
`<tool>/chunks/` holds examples to copy the style from. A manifest line is
`chunk_id | module_root | include_path[,include_path...]`; a file list is one path
per line, relative to the target.

For a manifest, always plan first and show the user the plan:

```bash
AR_STATE_DIR="<state>" bash <tool>/run_chunked_review.sh --target <target> --list <manifest>
```

Warnings about file caps or chunk sizes over ~350 KB mean the manifest needs
editing before a real run.

## 3. Start it detached

Pick a name for the run (for example the target's directory name plus the date).

```bash
# single target
AR_STATE_DIR="<state>" nohup bash <tool>/adversarial_review.sh -t 15 <target> > <reports>/<run>.log 2>&1 &
# file lists (report-only, resumable by re-running the same command)
AR_STATE_DIR="<state>" nohup bash <tool>/run_filelist_review.sh --target <target> -o <reports>/<run> <lists...> > <reports>/<run>.log 2>&1 &
# large project, unattended (restarts itself across quota resets)
AR_STATE_DIR="<state>" nohup bash <tool>/supervise_review.sh --target <target> -o <reports>/<run> <manifest> > /dev/null 2>&1 &
```

Tell the user the command you ran, where the log is, and how to check on it.

## 4. Check on it

- Single target: `AR_STATE_DIR="<state>" bash <tool>/adversarial_review.sh --status`
  and `tail -n 20 <reports>/<run>.log`.
- Chunked: `cat <reports>/<run>/index.tsv` (one row per finished chunk) and
  `tail -n 20 <reports>/<run>/driver.log`; the supervisor writes `supervise.log`.
- A run is alive while its pid is: check `<state>/.review.lock` and
  `<state>/.driver.lock/pid` with `kill -0`.

If the user wants you to keep watching, use `/loop` (for example every 30 minutes)
rather than sleeping in a shell command.

## 5. Report the result

Exit statuses (`<state>/tracking.json` → `status`):

| Status | Meaning |
|---|---|
| `report_only` | finished; the report is `<state>/artifacts/iter1_4_synthesis.md` |
| `clean` | both agents found nothing at MEDIUM or above |
| `agent_failure` | an agent call failed (quota, network, timeout) - see `<state>/logs/` |
| `empty_scope` | the source dump was empty - wrong path or scope settings |
| `max_iterations`, `circuit_open` | fix mode only |

For a single run, copy the report out straight away
(`cp <state>/artifacts/iter1_4_synthesis.md <reports>/<run>-report.md`): the next
run clears `<state>/artifacts/`. For a chunked run, build the merged report:

```bash
bash <tool>/aggregate_review.sh <reports>/<run>      # writes <reports>/<run>/REPORT.md
```

Then summarize for the user: the "Issues to fix" in severity order (title,
location, one line each), the number of disputed and rejected items, and which
chunks failed or were not reviewed. Before calling any CRITICAL or HIGH finding
real, open the cited lines yourself and say whether you agree. Offer to fix
specific findings; do not fix anything unasked. Tell the user where the report is.

## 6. If it failed

- `agent_failure` with a quota message: wait for the quota to reset, then re-run.
  Chunked runs resume with the same command plus `--resume` (the supervisor does
  this by itself).
- Only the synthesis failed in a single run:
  `AR_STATE_DIR="<state>" bash <tool>/adversarial_review.sh --from-phase 4 <target>`
  redoes one call instead of seven.
- `Circuit breaker is OPEN`: `AR_STATE_DIR="<state>" bash <tool>/adversarial_review.sh --reset-circuit`,
  then re-run.
- Anything else: show the user the last lines of the log and the failing call's
  `<state>/logs/*.claude.log` or `<state>/logs/*.codex.log`.
