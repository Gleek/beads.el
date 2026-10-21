# Agent Instructions

## Current Compatibility

This fork has been validated with **bd 1.3.1** and **Emacs 30.2**.
The original package targeted bd 0.49.1; do not assume its CLI contract still applies.
Check `bd version` and `bd <command> --help` before changing integrations.

- The default connection strategy is `cli`. Let bd resolve the workspace from
  the working directory and `BEADS_DIR`; a SQLite database file is not required.
- Current bd has no legacy socket daemon, activity command, or mutations API.
  Capability checks gate those features. Do not restore unconditional daemon
  startup or pass legacy flags such as `--no-daemon` to modern commands.
- CLI JSON can contain arrays, nested summaries, and stderr diagnostics.
  Reuse `beads-backend--call-json` and existing normalization helpers.
- Fetch the full issue list with `--all --limit 0` for Emacs-side filtering.
  Ready work comes from `bd ready`, including its dependency checks.
- Deletion needs `--force` after the UI's existing confirmation. Without it,
  bd previews deletion without performing it.
- Modern conflict resolution uses `bd conflicts show` and
  `bd conflicts resolve --all --strategy ours|theirs` with explicit UI confirmation.

## Fork and Upstream Contributions

- `origin` is Umar's fork, `Gleek/beads.el`; local `main` tracks `origin/main`.
- `upstream` is `ChristianTietze/beads.el`.
- The broad compatibility PR (#1) was closed by the user because its scope was
  too large. Do not reopen it or keep updating its branch as a submission.
- Keep fixes on the fork. Future upstream PRs should each address one focused
  problem and include relevant validation; discuss scope before opening them.

## Emacs Behavior and User Configuration

- Use standard Emacs faces (`warning`, `success`, `error`, font-lock faces,
  `hl-line`) through inheritance. Do not hardcode colors or depend on Doom.
- `beads-switch-project` offers known project.el roots with their own Beads
  metadata or redirect. It excludes unrelated projects and telemetry-only
  `.beads` directories. A missing project may need registration in project.el.
- Issue-list refresh uses asynchronous CLI processes for issues, readiness, and
  header statistics, even with legacy daemon strategies. New refreshes cancel
  older requests; buffer cleanup cancels pending work. Keep refresh callbacks
  free of synchronous CLI calls and preserve existing rows while loading.
- Issue-list auto-refresh defaults to 30 seconds in the library. A fetch failure
  disables it in the affected buffer to avoid repeated error messages.
- Umar disables polling in his Emacs configuration, in the Beads block in
  `~/.config/emacs/core/core-ai.el`:
  ```elisp
  (setq beads-autoupdate-enable nil
        beads-autoupdate-interval nil)
  ```
  Preserve this preference. Refresh manually with `g`. Activity follow mode is
  a separate, explicit polling feature on CLIs that support it.
- After changing Lisp, use `emacsclient` to load or evaluate it in the running
  Emacs so the user can test immediately. Face default changes may require
  `face-spec-set` to update existing faces while preserving user overrides.

## Issue Tracking

Use the Beads skill at `~/.agents/skills/beads/SKILL.md` (or the project-local
installation) and the `bd` CLI for all durable task tracking.

```bash
bd prime
bd ready --json
bd create "Issue title" --type bug --priority 2 --description "Details" --json
bd update <id> --claim --json
bd close <id> --reason "Completed and validated" --json
```

Use `--json` for programmatic operations. Link discovered work with
`--deps discovered-from:<parent-id>`. Do not create markdown task lists or ad hoc
memory files; use `bd remember` for durable project memory.

Issues live in a local Dolt database. `.beads/issues.jsonl` is a passive export,
not an automatically imported/exported source of truth. Do not assume the old
SQLite daemon's five-second auto-sync behavior or run `bd sync` as a generic
Git synchronization step.

When committing issue state, export with `bd export -o <temporary-path>` and
update the affected records in `.beads/issues.jsonl` alongside the change.
Preserve unrelated records: a full export may normalize historical metadata.
Keep database files, locks, and runtime backups out of commits.

## Validation

Run checks appropriate to the change. Core CLI changes need disposable-workspace
integration tests; never exercise destructive tests against a user's database.

```bash
python3 scripts/test.py                # Unit tests; excludes integration tests
python3 scripts/test.py --integration  # Isolated tests tagged :cli
python3 scripts/lint.py                # Lint and byte-compilation
```

Batch Emacs needs `vui` and `markdown-mode` on its load path. On Umar's machine:

```bash
export EMACSLOADPATH="$HOME/.config/emacs/elpaca/builds/vui:$HOME/.config/emacs/elpaca/builds/markdown-mode:"
```

The compatibility baseline passed 473 unit tests, 4 CLI integration tests, and
lint/byte-compilation. Documentation-only changes need a diff review and
`git diff --check`, rather than the full suite.

## Session Completion

Close completed Beads issues, record follow-up work, run relevant checks, and
review the diff. The user has authorized committing and pushing this work to
their fork: pull with rebase, push to `origin`, and verify a clean working tree
and an up-to-date tracking branch. Do not push to upstream or alter unrelated
user changes or stashes. Report what changed and how it was validated.
