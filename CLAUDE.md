# CLAUDE.md

@AGENTS.md

The shared project + workflow rules (including the flight red lines) live in `AGENTS.md`,
imported above so Codex and Claude Code read one source. Only Claude Code-specific notes
belong below.

## Claude Code specifics

### Prompt logging

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
