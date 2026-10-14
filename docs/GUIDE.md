# Adversarial Review: User Guide

This guide covers everything needed to use the tool: setting it up, reviewing a
project, reviewing a project too big for one pass, reading the results, and, in
the second half, getting Claude Code or Codex to run the whole thing for you so
you never have to type the commands yourself.

- [1. What it does and what it costs](#1-what-it-does-and-what-it-costs)
- [2. Setup](#2-setup)
- [3. Your first review](#3-your-first-review)
- [4. Choosing what gets reviewed](#4-choosing-what-gets-reviewed)
- [5. Large projects: chunked reviews](#5-large-projects-chunked-reviews)
- [6. Reading the results](#6-reading-the-results)
- [7. Fix mode](#7-fix-mode)
- [8. Letting Claude Code run it](#8-letting-claude-code-run-it)
- [9. Letting Codex run it](#9-letting-codex-run-it)
- [10. Fully unattended: schedules and CI](#10-fully-unattended-schedules-and-ci)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Command cheat sheet](#12-command-cheat-sheet)

---

## 1. What it does and what it costs

You point the tool at a project. It collects the project's source into one text
dump and runs a four-step debate between two different AI models:

1. **Independent review.** Claude and Codex each review the code on their own.
2. **Cross-review.** Each checks the other's findings against the code: confirmed,
   refuted, or unverifiable, plus anything serious the other missed.
3. **Meta-review.** Each answers the challenges to its own findings, conceding or
   defending them with code, and ends with a table of final positions.
4. **Synthesis.** Claude merges everything into one deduplicated report: issues to
   fix (with diffs), disputed items for a human to decide, and rejected items.

Two different models catch different bugs, and making each one verify the other
filters out a lot of confident false positives. By default nothing in the
reviewed project is changed; you get a report.

**Cost.** One review of one scope is **7 agent calls**: 2 + 2 + 2 + 1. They come
out of your Claude and Codex quotas (or API budgets). The biggest cost is the
source dump, which is sent four times (phases 1 and 2, to both agents). A clean
result in phase 1 stops after 2 calls. Plan on tens of minutes per review; each
phase waits for the slower agent.

Is it worth it? For a quick look at a small change, a single agent is cheaper.
This tool earns its cost when you want a careful review of code that matters and
you want findings you can trust without checking each one yourself.

## 2. Setup

You need bash, `jq`, and both agent CLIs, logged in.

```bash
# Agent CLIs
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex
claude          # log in once, interactively, then exit
codex login     # log in once

# jq: macOS / Linux / Windows
brew install jq        # or: apt install jq / winget install jqlang.jq

# macOS only: GNU timeout, so a stuck agent call is stopped
brew install coreutils
```

On Windows, run everything from **Git Bash or WSL**, not PowerShell or cmd.

Get the repository and check it:

```bash
git clone https://github.com/herrtunante/adversarial-review
cd adversarial-review
chmod +x *.sh                      # the wrapper scripts are not executable in git
claude --version && codex --version && jq --version
./adversarial_review.sh --dry-run ../some-project   # no agent calls; checks the plumbing
./adversarial_review.sh --reset                     # clear the dry run's stub files
```

All state (artifacts, logs, locks) lives inside this repository's directory, so
the tool never writes into the project you review unless you use `--fix`. Set
`AR_STATE_DIR=/some/dir` to keep it somewhere else instead; the chunk driver and
the file-list wrapper pass it on to every review they start, and their default
output folder `reviews/` moves with it. Two runs with different state directories
are independent, like two worktrees.

## 3. Your first review

```bash
./adversarial_review.sh ../my-project
```

That is a report-only review with the default scope (see section 4). Useful
options:

| Option | Meaning |
|---|---|
| `-t 15` | timeout per agent call, in minutes (default 10; use 15–30 for big scopes) |
| `-v` | verbose progress |
| `--changed-only` | review only files with uncommitted git changes |
| `-p my_prompt.md` | use another phase-1 prompt for this run |
| `--dry-run` | stub every agent call |
| `--status` | show the state of the last run |

When it finishes, the report is in **`artifacts/iter1_4_synthesis.md`**. The
next run clears `artifacts/`, so copy the report somewhere if you want to keep it:

```bash
mkdir -p reviews && cp artifacts/iter1_4_synthesis.md reviews/my-project-$(date +%F).md
```

The run's outcome is in `tracking.json` (`./adversarial_review.sh --status`):

| Status | Exit | Meaning |
|---|---|---|
| `report_only` | 0 | finished; read the report |
| `clean` | 0 | both agents found nothing at MEDIUM or above in phase 1 |
| `agent_failure` | 1 | an agent call failed (quota, network, timeout); nothing usable |
| `empty_scope` | 1 | the source dump was empty: wrong path or scope settings |
| `max_iterations`, `circuit_open` | 1 | fix mode only (section 7) |

To keep a long run going after you close the terminal:

```bash
nohup ./adversarial_review.sh -t 15 ../my-project > reviews/my-project.log 2>&1 &
```

## 4. Choosing what gets reviewed

The agents see one source dump. What goes into it decides both the quality of the
review and its cost.

**Default walk.** Java, Python and TS/JS files, up to 30 files per language
(`MAX_SOURCE_FILES`), plus up to 10 shell scripts, each cut at 500 lines (300
for shell). Files are taken in alphabetical path order, so a large project is
truncated, not sampled. Other languages (Go, Rust, C…) are skipped. Hidden
directories, `node_modules`, `target/` and `build/` are skipped (the TS/JS walk
does not skip `target/`, `dist/` or `build/`, so add an exclude for those).

**Exclude what you don't want** (an extended regex matched against absolute paths,
applied before the caps):

```bash
MAX_SOURCE_EXCLUDE='/(dist|vendor|generated)/|\.min\.js$' ./adversarial_review.sh ../my-project
```

**Name exactly the files you want** (any language, in that order; only the line
cap still applies):

```bash
cat > review.files <<'EOF'
# paths relative to the target
src/server/auth.go
src/server/session.go
EOF
SOURCE_FILE_LIST=review.files MAX_SOURCE_LINES=2000 ./adversarial_review.sh ../my-project
```

**Review only what you changed** (uncommitted files, up to 3000 lines each), the
cheapest way to review work in progress:

```bash
./adversarial_review.sh --changed-only ../my-project
```

Sizing rule of thumb: keep one dump between about **150 and 350 KB** of source.
Phase 2 sends the dump plus the other agent's review, so larger dumps risk
filling the agents' context or timing out.

## 5. Large projects: chunked reviews

For a project bigger than one dump, split it into chunks and let a driver review
them one after another. Two ways to define chunks:

### 5.1 A manifest (multi-module projects)

One line per chunk: `chunk_id | module_root | include_path[,include_path...]`.
The module root is relative to the target and becomes the agents' working
directory; include paths are relative to the module root and are all the dump
may contain (empty or `.` means the whole module).

```text
# chunks/myproj.manifest
core-model    | core    | src/main/java/com/acme/model
core-service  | core    | src/main/java/com/acme/service,src/main/java/com/acme/util
web-api       | web     | src/main/java/com/acme/api
frontend      | webapp  | src/app
```

Always look at the plan first. It runs nothing, and warns about chunks that are
too big or that exceed the file caps:

```bash
bash run_chunked_review.sh --target ../myproj --list chunks/myproj.manifest
```

Then run it:

```bash
bash run_chunked_review.sh --target ../myproj -t 20 -o reviews/myproj chunks/myproj.manifest
bash run_chunked_review.sh --target ../myproj --resume -o reviews/myproj chunks/myproj.manifest  # after an interruption
bash run_chunked_review.sh ... --only 'core-*' ...                                              # a subset
```

Order the manifest most-important-first, so an interrupted run has already
covered what matters. `chunks/collect.manifest` is a full real example.

Note that an include path also pulls in source files sitting directly in its
parent directories, so splitting a package whose root holds most of the code
duplicates that code in both halves.

### 5.2 File lists (when directories don't match the split)

One `.files` file per chunk, same format as `SOURCE_FILE_LIST`. The chunk id is
the file name.

```bash
bash run_filelist_review.sh --target ../whisp -o reviews/whisp chunks/whisp/*.files
```

Re-running the same command skips chunks that are already done, as long as their
scope is unchanged. If you edit a file list or a manifest include, or point
`--target` somewhere else, the affected chunks are reviewed again with a warning
saying what changed. Changes to the source code itself never force a redo. The
supervisor does not notice a changed scope, so after editing a manifest run the
driver itself with `--resume`.

### 5.3 Unattended runs that survive quota limits

The driver waits up to two hours for a refused agent to come back, then gives up.
For overnight runs use the supervisor, which restarts the driver with `--resume`
until every chunk is done:

```bash
nohup bash supervise_review.sh --target ../myproj -t 20 -o reviews/myproj chunks/myproj.manifest > /dev/null 2>&1 &
tail -f reviews/myproj/supervise.log
```

To start at a quiet hour (for example after your quota resets at 18:00):

```bash
nohup bash scheduled_restart.sh --at 18 --driver supervise_review.sh -- \
    --target ../myproj -o reviews/myproj chunks/myproj.manifest > /dev/null 2>&1 &
```

To stop a supervised run, stop the **supervisor first** (`kill <pid>`), then the
driver. Killing only the driver makes the supervisor start it again five minutes
later.

### 5.4 The merged report

```bash
bash aggregate_review.sh reviews/myproj        # writes reviews/myproj/REPORT.md and summary.json
```

`reviews/myproj/index.tsv` has one row per chunk with its status and duration;
each chunk's full debate is under `reviews/myproj/<chunk_id>/artifacts/`.

Only one review can run per checkout. To review two projects at once, run the
second from a separate `git worktree` of this repository.

## 6. Reading the results

Each report has the same sections:

- **Summary**: how many issues, the most serious one.
- **Issues to fix**, ordered by severity, each with location, the problem
  (trigger → impact), a concrete fix, and how it was agreed: *found by both*,
  *found by one, confirmed by the other*, or *verified by the arbiter*. Items
  found by both are the most trustworthy.
- **Disputed**: the reviewers still disagree after checking the code. Each entry
  gives both positions; these need a human decision.
- **Rejected**: findings dropped, with the code that disproves them.
- **Minor notes**: low-severity remarks that were not debated.

Findings carry IDs: `C-F3` is finding 3 of Claude's review, `X-F3` is Codex's, and
`C-N1` / `X-N1` are issues added during cross-review. To see how any item was
argued, search for its number in that chunk's phase 2 and 3 artifacts
(`iter1_2_*`, `iter1_3_*`).

The models can still be wrong. Treat CRITICAL and HIGH items as strong leads and
check each one against the code before acting on it.

## 7. Fix mode

```bash
git -C ../my-project status        # commit first: fix mode edits files in place
./adversarial_review.sh --fix -m 3 ../my-project
```

With `--fix`, phase 4 also applies the accepted fixes (file tools only, no shell,
so it cannot run tests), and the loop re-reviews up to `-m` times. That is 7 calls
per iteration. The reviewed source is quoted in the prompt of an agent that can
write, so a comment planted in that source could steer it: **use `--fix` only on
code you trust**, and review the diff before you commit it. The supervisor and the
file-list wrapper are report-only by design.

If the circuit breaker opens (no progress, persistent disagreement, or the same
issues every time), reset it with `./adversarial_review.sh --reset-circuit`.

---

## 8. Letting Claude Code run it

The scripts already drive both agents; what you hand to Claude Code is the
operator's job: picking the scope, writing manifests, starting the run correctly
in the background, watching it, and turning the report into a short answer (and
fixes, if you ask). A nested `claude --print` started from inside a Claude Code
session works, so Claude Code can run the review directly.

### 8.1 Install the skill as a plugin (recommended)

The repository is also a Claude Code **plugin** with its own marketplace, so you
can install the skill and the scripts it runs in one step, and use it from any
project. In Claude Code:

```text
/plugin marketplace add herrtunante/adversarial-review
/plugin install adversarial-review@herrtunante-tools
```

or from a terminal:

```bash
claude plugin marketplace add herrtunante/adversarial-review
claude plugin install adversarial-review@herrtunante-tools
```

The skill tells Claude exactly how to operate the tool: preflight checks,
choosing the scope, always starting detached with `nohup`, checking on the run,
collecting the report, verifying the top findings, and the safety rules
(report-only unless you say otherwise, never `--reset` during a run, one run at a
time, ask before spending quota on a chunked run).

Invoke it as `/adversarial-review:adversarial-review ../my-project` (plugin skills
carry the plugin's name in front), or just ask in plain words; the skill is
picked up from its description:

```text
Run an adversarial review of ../my-project and tell me what it finds.
Review only my uncommitted changes in ../my-project.
Plan chunks for ../collect, show me the plan, then run it overnight.
How is the review going?
Summarize the last report and check the top three findings against the code.
Fix findings 1 and 4 from that report in ../my-project.
```

Where things go when it is installed as a plugin:

- **The scripts** are in Claude Code's plugin cache. Every update replaces that
  copy, so nothing is kept there.
- **Run state** (`artifacts/`, `logs/`, locks, `tracking.json`) goes to the
  plugin's data directory, which survives updates. The skill passes it to the
  scripts as `AR_STATE_DIR`.
- **Reports and logs** go to `~/adversarial-reviews/`, unless you name another
  place. Manifests and file lists you write with Claude go to
  `~/adversarial-reviews/chunks/`.

The plugin has no version number, so `/plugin update` (or the automatic update)
brings in each new commit on `main`. You still need `codex`, `jq` and a logged-in
Claude on the machine (section 2).

### 8.1b Using the skill from a clone

In a clone of this repository the same skill is available as plain
`/adversarial-review`, through a short pointer in `.claude/skills/` that loads
`skills/adversarial-review/SKILL.md`. There, state and reports stay inside the
clone as described in the rest of this guide. To try the plugin build of a local
checkout without installing it, run `claude --plugin-dir .` from the clone.

### 8.2 Fewer permission prompts

Claude asks before running each new command. To pre-approve the tool's own
scripts, add this to `.claude/settings.local.json` in this repository (local
settings are not committed):

```json
{
  "permissions": {
    "allow": [
      "Bash(./adversarial_review.sh:*)",
      "Bash(nohup ./adversarial_review.sh:*)",
      "Bash(bash run_chunked_review.sh:*)",
      "Bash(bash run_filelist_review.sh:*)",
      "Bash(bash supervise_review.sh:*)",
      "Bash(nohup bash:*)",
      "Bash(bash aggregate_review.sh:*)",
      "Bash(jq:*)",
      "Bash(tail:*)",
      "Bash(cat reviews/:*)"
    ]
  }
}
```

Leave `--fix` runs and anything that edits the target to be approved by hand.

### 8.3 Keeping an eye on a long run

A review outlives a single command, so Claude starts it with `nohup` and checks
back. Ask "how is the review going?" at any time, or have Claude poll on a
schedule within the session:

```text
/loop 30m check the adversarial review in reviews/collect and tell me when it finishes or fails
```

### 8.4 Headless: one command, no chat

`claude -p` runs a single prompt non-interactively, which is handy in a script or
cron job. The skill still applies when run from this repository:

```bash
cd ~/adversarial-review
claude -p "Use the adversarial-review skill: review ../my-project report-only, \
wait for it to finish, then write a 15-line summary of the issues to fix to \
reviews/my-project-summary.md" \
  --allowedTools "Bash(./adversarial_review.sh:*)" "Bash(nohup ./adversarial_review.sh:*)" \
                 "Bash(cat:*)" "Bash(tail:*)" "Bash(jq:*)" "Bash(cp:*)" "Bash(mkdir:*)" Read Write
```

For a plain unattended run you don't need Claude in front at all: the script
itself is the automation (`nohup ./adversarial_review.sh ...` or the supervisor).
Put Claude in front when you want the result interpreted, the scope chosen, or
failures handled.

### 8.5 Claude Code on the web (cloud sessions)

You can run reviews from a cloud session at claude.ai/code instead of your own
machine, so a review keeps going with your laptop closed. Claude itself is
available there already; the environment needs Codex and the target code:

1. **Repositories**: start the session with this repository *and* the project to
   review selected (or ask Claude to add the second one).
2. **Setup script** (environment settings → Edit → Setup script):
   ```bash
   npm install -g @openai/codex
   command -v jq || (apt-get update && apt-get install -y jq)
   ```
3. **Codex credentials**: add an OpenAI API key to the environment's secrets
   (environment settings → Edit), never in the chat. Codex reads it from
   `CODEX_API_KEY` in `codex exec`, or you can log in once in the setup script
   with `printenv OPENAI_API_KEY | codex login --with-api-key`; check
   `codex login --help` for your version.
4. **Network**: the environment's network policy must allow the OpenAI API
   (`api.openai.com`).

Then ask exactly as in 8.1. Cloud containers are reclaimed after a period of
inactivity, so ask Claude to copy the finished report into `reviews/` and commit
it, or to paste the summary into the chat. Scheduled tasks on claude.ai can start
a fresh cloud session on a schedule with a prompt such as *"Run the
adversarial-review skill on the project's uncommitted changes and summarize"*.

---

## 9. Letting Codex run it

Codex reads `AGENTS.md` at the repository root, which points it to the same
runbook as the Claude skill. Start Codex in this repository and ask the same way:

```text
Run an adversarial review of ../my-project, report-only, and summarize it.
```

Two things differ from Claude Code:

- **Sandbox.** The review calls both model APIs over the network and writes to
  `artifacts/`, `logs/` and `~/.claude`. Codex's default sandbox blocks network
  access, so the run either needs your approval to run outside the sandbox when
  Codex asks, or Codex started with full access:
  ```bash
  codex --sandbox danger-full-access
  ```
  Use that only in this repository, which contains no secrets of its own.
- **Long commands.** Codex stops shell commands after a time limit, so it must
  start the review with `nohup ... &` (AGENTS.md says so) and check back.

Headless, the equivalent of `claude -p` is `codex exec`:

```bash
cd ~/adversarial-review
codex exec --sandbox danger-full-access \
  "Follow AGENTS.md: run a report-only adversarial review of ../my-project, wait \
   for it to finish, and write a short summary to reviews/my-project-summary.md"
```

Flags change between Codex versions; check `codex exec --help` if one is refused.

---

## 10. Fully unattended: schedules and CI

**On your own machine.** A cron entry is the simplest scheduler; the supervisor
handles quota outages:

```cron
# Every night at 01:15, review uncommitted work in my-project (report-only)
15 1 * * * cd $HOME/adversarial-review && ./adversarial_review.sh --changed-only $HOME/my-project > reviews/nightly.log 2>&1 && cp artifacts/iter1_4_synthesis.md reviews/nightly-$(date +\%F).md
```

**In CI (GitHub Actions).** Possible, with two caveats: each run is 7 calls billed
to API keys, and both CLIs need credentials as repository secrets. A sketch, to
adapt:

```yaml
# .github/workflows/adversarial-review.yml (in the project to review)
on:
  workflow_dispatch:        # run by hand; avoid running on every push
jobs:
  review:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4
        with: { path: target }
      - uses: actions/checkout@v4
        with: { repository: herrtunante/adversarial-review, path: ar }
      - run: npm install -g @anthropic-ai/claude-code @openai/codex && sudo apt-get install -y jq
      - run: cd ar && ./adversarial_review.sh -t 20 ../target
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          CODEX_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: adversarial-review, path: "ar/artifacts\nar/logs" }
```

For pull requests, review only the changed files: write the changed paths
(`git diff --name-only origin/main...HEAD`) to a file and pass it as
`SOURCE_FILE_LIST`.

---

## 11. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `agent_failure`, log mentions a limit or quota | An agent's quota is used up. Wait for the reset and run again. Chunked: re-run with `--resume`, or use the supervisor. |
| `agent_failure`, `timed out after Nm` | The scope is too big for the timeout. Raise `-t`, or split the chunk. |
| Only the synthesis failed | `./adversarial_review.sh --from-phase 4 <target>` redoes 1 call instead of 7 (same scope settings required). |
| `empty_scope` | Nothing matched: check the path, the language (only Java/Python/JS/TS/shell are walked), `MAX_SOURCE_EXCLUDE`, or use `SOURCE_FILE_LIST`. |
| `Another review is running` / exit 4 | One run per checkout. Wait, or use a separate `git worktree`. A lock whose pid is dead is taken over automatically. |
| `Circuit breaker is OPEN` | `./adversarial_review.sh --reset-circuit`. |
| `Permission denied` running a wrapper | Run it with `bash <script>` or `chmod +x *.sh`. |
| `codex --version` works in PowerShell but not Git Bash | A stray `node_modules/node` in `%APPDATA%\npm` shadows node; the script falls back to `codex.cmd` itself, or set `CODEX_BIN=codex.cmd`. |
| A chunk is redone over and over | Look at `<out>/<chunk>/logs/*.log` for the failing call; a chunk that always times out needs splitting. |
| The report quotes code that no longer exists | The review ran on an older state of the target; re-run. |

Full internals, every failure mode and the reasoning behind them: `CLAUDE.md`.

## 12. Command cheat sheet

```bash
# one review
./adversarial_review.sh ../proj                       # report-only
./adversarial_review.sh --changed-only ../proj        # uncommitted changes only
SOURCE_FILE_LIST=x.files ./adversarial_review.sh ../proj
./adversarial_review.sh --status | --reset | --reset-circuit
./adversarial_review.sh --from-phase 4 ../proj        # redo only the synthesis

# big projects
bash run_chunked_review.sh --target ../proj --list chunks/proj.manifest
nohup bash supervise_review.sh --target ../proj -o reviews/proj chunks/proj.manifest >/dev/null 2>&1 &
bash run_filelist_review.sh --target ../proj -o reviews/proj chunks/proj/*.files
bash aggregate_review.sh reviews/proj

# through an agent
/plugin install adversarial-review@herrtunante-tools   # once, after /plugin marketplace add herrtunante/adversarial-review
/adversarial-review:adversarial-review ../proj        # installed as a plugin
/adversarial-review ../proj                           # in a clone of this repo
claude -p "Use the adversarial-review skill on ../proj ..." --allowedTools ...
codex exec --sandbox danger-full-access "Follow AGENTS.md: review ../proj ..."
```
