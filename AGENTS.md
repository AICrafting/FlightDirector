# AGENTS.md

Shared guidance for every coding agent working in this repository — Codex discovers this
file directly; Claude Code reads it through the `@AGENTS.md` import in `CLAUDE.md`. Put
repo-wide rules here; put harness-specific notes (Claude-only hooks, Codex-only settings) in
that harness's own file.

## Project

Flight Director — AI Crafting's Claude Code + Codex plugins (marketplace `flightdirector`; `flight` is the first plugin).

## Code Style

- **Code:** Prefer tabs (width 4) over spaces.
- **Trailing whitespace:** Trimmed on save (except for .md files)
- **Final newlines:** Trimmed (but leave one final newline)
- **File and script names:** kebab-case (`run-checks.sh`, `verify-git-logs.sh`), never camelCase.
  Scripts end in `.sh`, unit tests in `.test.sh`; tracked scripts carry the exec bit (`100755`).

## Issue tracking — flight

This repo manages issues/PRs/CI with the **flight** plugin. The backend is
**Forgejo** — NOT GitHub — so never reach for `gh` here. Its host,
coordinates, stage pipeline, and label names live in `.flightdirector/config.json`
(token in `.flightdirector/secrets.json`, git-ignored). Act through the flight
skills (working-an-issue, promoting-a-branch, filing-issues, …) or the
dispatcher: `flight <group> <verb>`.

Workflow red lines — these hold for every model and survive context
compaction; re-read them before any git write, especially if the session's
earlier instructions were summarized away or the model changed mid-session:

- Each issue is worked on its own `feature/<N>-<slug>` branch in its own
  `.worktrees/<N>-<slug>` worktree — NEVER commit directly to `develop` or
  any later stage.
- Merging is gated on the user's explicit go-ahead ("promote"); it happens
  through the promoting-a-branch skill, never by hand.
- Keep the issue's status label honest at every transition
  (in-progress → to-test → …) via `flight issues set-status`.

## Additional local notes

Claude:
@AGENTS.local.md

Codex:
Please read the file AGENTS.local.md if it exists and treat its contents as if
it were in this file directly.
