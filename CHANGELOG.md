# Changelog

Versions follow [semantic versioning](https://semver.org/): the major number
changes when a command line, an output path or the report format changes in a way
that breaks existing use; the minor number for new features; the patch number for
fixes. The version lives in `.claude-plugin/plugin.json`, and
`./adversarial_review.sh --version` prints it.

Installed plugins only update when this version changes, so every release that
should reach users bumps it.

## 1.0.0 - 2026-10-15

First versioned release.

- Four-phase review: Claude and Codex review independently, verify each other's
  findings against the code, answer the challenges, and Claude writes one
  deduplicated report with "found by both", "confirmed" and "disputed" labels.
- Report-only by default; `--fix` lets the synthesis edit the target with file
  tools only (no shell).
- Large projects: chunk manifests (`run_chunked_review.sh`), file lists
  (`run_filelist_review.sh`), an unattended supervisor that survives quota
  limits, scheduled starts, and a merged report (`aggregate_review.sh`).
- Prompts with finding IDs, mandatory code evidence, a MEDIUM severity floor and
  word budgets.
- Claude Code plugin and marketplace (`herrtunante-tools`), with the
  `adversarial-review` skill that plans, runs, watches and summarizes a review.
  Run state goes to `AR_STATE_DIR`, the plugin's data directory when installed.
- `AGENTS.md` so Codex can operate the tool too.
- `--version`.
