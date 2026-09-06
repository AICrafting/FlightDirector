# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Flight Director — AI Crafting's Claude Code + Codex plugins (marketplace `flightdirector`; `flight` is the first plugin).

## Code Style

- **Code:** Prefer tabs (width 4) over spaces.
- **Trailing whitespace:** Trimmed on save (except for .md files)
- **Final newlines:** Trimmed (but leave one final newline)

## Issue tracking — flight

This repo manages issues/PRs/CI with the **flight** plugin. The backend is
**Forgejo** at `forge.example.com` — NOT GitHub — so never reach for `gh` here.
Coordinates, stage pipeline, and label names live in `.flightdirector/config.json`
(token in `.flightdirector/secrets.json`, git-ignored). This repo's own config is
still in the legacy `.lightspeed/` folder until the dogfood plugin cache is
refreshed to `flight` — the dispatcher reads it with a notice; migrate it then. Act through the flight
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

## Prompt logging

Every prompt is automatically logged to `prompt_log.jsonl` (git-ignored) via hooks in `.claude/settings.local.json` (personal/local — the hooks shell out to scripts in `~/.claude-shared`, so they don't travel with the repo). Each line is a JSON record:

```json
{
  "timestamp": "2026-04-10T12:00:00.000000+00:00",
  "session_id": "abc123",
  "prompt": "...",
  "model": "claude-sonnet-4-6-20251001",
  "input_tokens": 1234,
  "output_tokens": 567,
  "cache_creation_tokens": 0,
  "cache_read_tokens": 0,
  "cost_usd": 0.012345,
  "duration_seconds": 4.2
}
```
