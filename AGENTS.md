# AGENTS.md

Instructions for coding agents (Codex and others) working in this repository.

This repository is a Bash orchestrator that runs `claude` and `codex` through a
four-phase review debate over another project's source code. `CLAUDE.md` describes
the internals in full; read it before changing any script or prompt.

## When asked to run a review

Follow `skills/adversarial-review/SKILL.md` step by step. It is written for
Claude Code but applies unchanged to you; in its step 0 you are in the "clone of the
repository" case. In short:

- Report-only unless the user explicitly asks for fixes; never add `--fix` yourself.
- Start every run detached (`nohup ... > reviews/<run>.log 2>&1 &`): a run takes
  tens of minutes per chunk, far longer than a shell command may run.
- One run per checkout; never `--reset` or delete a lock while one is running.
- Tell the user the plan and its cost (about 7 agent calls per chunk) before a
  chunked run.

**Sandbox:** the review calls the Claude and OpenAI APIs and writes to
`artifacts/`, `logs/` and `~/.claude`, so it cannot run inside a read-only or
network-less sandbox. Request to run the command outside the sandbox (or the user
starts you with `--sandbox danger-full-access`). Starting it detached does not
change that: the detached process keeps the sandbox it was started in.

## When asked to change the scripts

- `bash -n adversarial_review.sh lib/*.sh run_*.sh supervise_review.sh aggregate_review.sh`
  must pass, and `./adversarial_review.sh --dry-run <some dir>` must complete.
- Prompts and parser are one contract: see "The status-block protocol" and
  "The prompts" in `CLAUDE.md` before editing anything in `prompts/`.
