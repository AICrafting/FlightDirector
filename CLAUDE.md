# CLAUDE.md

@AGENTS.md

The shared project + workflow rules (including the flight red lines) live in `AGENTS.md`,
imported above so Codex and Claude Code read one source. Only Claude Code-specific notes
belong below.

## Claude Code specifics

### Prompt logging (the cost ledger)

Each agent turn is logged — prompt, model, tokens, estimated cost — to a git-ignored
`prompt_log.jsonl` at the repo root, by the **flight plugin's bundled hooks**. Claude Code and
Codex write the same file with the same schema, so the work-ledger comment on a finished issue
is measured with `flight prompt-log summary --session <id>` rather than guessed. The switch is
`code.promptLog.enabled` in `.flightdirector/config.json`; the record format, pricing, and
semantics are documented once in `flight/references/prompt-log.md` — don't duplicate them here.

Switchover note for this repo: the older personal logger (`~/.claude-shared/hooks/prompt_logger.py`,
wired in `.claude/settings.local.json`) must be removed when the bundled ledger is enabled, or
every turn is logged twice. The bundled hooks take effect only once the dogfood plugin cache is
refreshed to a build that contains them.
