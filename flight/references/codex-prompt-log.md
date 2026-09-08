# Codex prompt ledger

Flight's Codex plugin bundles lifecycle hooks that can append one record per turn to the
shared `.flightdirector/prompt-log.jsonl` described in [prompt-log.md](prompt-log.md). The hooks are off by
default. Enable them for a repository with:

```json
{
	"code": {
		"promptLog": {
			"enabled": true
		}
	}
}
```

Merge that setting into the main worktree's `.flightdirector/config.json`; do not commit
credentials. Codex discovers the hook file through `.codex-plugin/plugin.json`. Open `/hooks`
in Codex to review and trust the plugin's current hook definition. A plugin update changes the
hook hash and may require review again.

The hook resolves the installed logger through `$PLUGIN_ROOT`, then resolves the ledger at the
main worktree through Git's common directory. Linked worktrees therefore share one log. Add
`.flightdirector/prompt-log.jsonl` to the repository's `.gitignore` because records contain prompt text.

Codex history persistence must remain enabled: `Stop`, `Interrupt`, and `SubagentStop` parse the
transcript paths supplied by Codex. Do not use `codex exec --ephemeral` when ledger output is
required. Normal `codex exec --json` runs persist rollout files and execute the same bundled
hooks; the JSONL event stream is not used as a second accounting source. This path was verified
end to end with a locally installed plugin and Codex CLI 0.153.4: one short prompt produced one
complete ledger row.

`flight prompt-log <prompt|stop|interrupt|subagent-stop>` is the internal hook entrypoint. A
manually maintained repo-local `.codex/hooks.json` may invoke the installed plugin by absolute
path, but that is an unsupported convenience rather than the installation path.

The logger currently recognises Codex rollout records containing `session_meta`, `turn_context`,
`event_msg` task timing, and `token_usage_record.turn_token_usage` (verified with Codex CLI
0.153.4). It selects usage by the hook's exact `turn_id`. A delegated row follows the shared
schema by writing `agent_id` as its ledger `turn_id`, while using the hook turn id only to select
the delegated transcript records. Unknown formats produce null usage and cost fields with a
visible warning.

Bundled OpenAI prices are the Standard, short-context rates from the official API pricing
page. The current ledger schema does not carry request context length or service tier, so
long-context, Batch, Flex, and Fast mode variants require a repo pricing override or a future
schema extension rather than being inferred silently.

OpenTelemetry `response.completed` export is a possible more stable source later. It is outside
the per-repository JSONL scope and is not enabled here.
