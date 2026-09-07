# The prompt ledger — `prompt_log.jsonl`

Flight's work-ledger comments ("this issue cost $X across N turns on model M") are built from a
per-repo **prompt ledger**: one JSON record per agent turn, appended to `prompt_log.jsonl` at the
**main worktree root**. Both harnesses write the **same file with the same schema**, so a repo
worked from Claude Code and Codex — even in the same project, even concurrently — has one ledger
that `flight prompt-log summary` can total per session.

The ledger is **opt-in per repository** and the file is **gitignored** (records contain prompt
text). Nothing is written until you turn it on.

## Turning it on

```jsonc
// .flightdirector/config.json
"code": {
  "promptLog": { "enabled": true }
}
```

That single switch is the only producer control. The plugin ships its hooks **bundled** for both
harnesses — `flight/hooks/hooks.json` (Claude Code, via `$CLAUDE_PLUGIN_ROOT`) and
`flight/hooks/codex-hooks.json` (Codex, declared in `.codex-plugin/plugin.json`, via
`$PLUGIN_ROOT`) — and every hook invocation first runs the dispatcher route
`flight prompt-log <mode>`, which exits 0 silently unless the repo it is running in has the
switch on. So installing the plugin costs a repo that never opted in one `jq` read per turn and
writes nothing. `setting-up-a-repo` offers to enable it and adds `prompt_log.jsonl` to
`.gitignore`; do that by hand for an existing repo:

```
echo 'prompt_log.jsonl' >> .gitignore
```

> Migrating from a personal logger (a `~/.claude-shared/hooks/prompt_logger.py` wired in
> `.claude/settings.local.json`)? Remove those hook lines when you enable the bundled one, or
> every turn is logged twice.

## Record format

One JSON object per line. Every field below is present on every row (a value may be `null`);
producers may add the optional extras at the end.

```jsonc
{
  "timestamp": "2026-09-06T03:44:30.832557+00:00",  // when the row was written (turn end), UTC ISO-8601
  "provider": "anthropic",                          // "anthropic" | "openai"
  "harness": "claude",                              // "claude" | "codex"
  "session_id": "…",                                // the harness's session id — the work ledger sums by this
  "turn_id": "…",                                   // one row per turn; Codex supplies it, Claude Code mints a uuid
  "prompt": "…",                                    // the user's prompt text for the turn
  "model": "claude-fable-5-1",                      // the model that served *this* turn (it can change mid-session)
  "input_tokens": 704462,                           // TOTAL prompt tokens = uncached + cache_read + cache_creation
  "output_tokens": 1525,                            // total output, reasoning included
  "reasoning_output_tokens": 342,                   // informational; already inside output_tokens — never add it again
  "cache_creation_tokens": 0,                       // prompt tokens written to the provider's cache
  "cache_read_tokens": 667776,                      // prompt tokens served from the cache
  "cost_usd": 0.123456,                             // priced from pricing.json; null when the model or usage is unknown
  "cost_basis": "api-equivalent",                   // "actual-api" | "api-equivalent" | null — see below
  "duration_seconds": 42.1                          // turn wall time
  // optional extras:
  // "subagent": true,           row for a delegated agent (SubagentStop); turn_id is the agent id
  // "interrupted": true,        the turn was interrupted; usage is whatever had been reported
  // "models": {"m1": 123, …}   a turn that spanned models — output tokens per model; `model` is the dominant one
}
```

### Semantics that matter for totals

- **`input_tokens` is the total prompt**, including cached tokens. OpenAI reports it that way;
  Anthropic reports the *uncached* portion separately, so the Claude producer adds
  `cache_creation` + `cache_read` to it. Uncached input = `input_tokens − cache_read_tokens −
  cache_creation_tokens`, and that is what the input rate is applied to.
- **A turn is one row**, however many model requests it took. Claude Code's transcript holds one
  entry per content block, all sharing a `requestId` and the same usage — the producer sums once
  per request. Codex reports a cumulative `turn_token_usage`; the producer takes the latest record
  for the exact `turn_id`.
- **Missing data is `null`, never `0`.** If the transcript can't be read or has no usage for the
  turn, the token and cost fields are `null` and the hook prints a warning on stderr. A `0` means
  the provider said zero.
- **`cost_usd` is an estimate at API list prices.** `cost_basis` says how to read it:
  `actual-api` when the harness authenticates with an API key (Anthropic key, Bedrock/Vertex,
  `OPENAI_API_KEY`/`CODEX_API_KEY`) and the number is what you would be billed; `api-equivalent`
  under a subscription login (claude.ai, ChatGPT), where the number is what the same tokens
  *would* cost via the API — useful for comparing issues, not a bill. Override the guess with
  `FLIGHT_CLAUDE_AUTH_MODE=api|subscription` / `FLIGHT_CODEX_AUTH_MODE=api|chatgpt`.
- **Subagent rows** keep the parent `session_id` so a session total includes delegated work.

## Pricing

`flight/scripts/prompt-logger/pricing.json` is the one shared table, USD per million tokens:

```jsonc
{
  "models":   { "<exact model id>": { "input_per_million": …, "output_per_million": …,
                                      "cache_creation_per_million": …, "cache_read_per_million": … } },
  "families": { "<id prefix>": { …same rates… } }   // longest matching prefix wins: "claude-opus-5" matches claude-opus-5-1
}
```

Put repo-specific or newer prices in **`.flightdirector/pricing.json`** (same shape); it is merged
on top of the bundled file. An unknown model logs its tokens with `cost_usd: null` and a warning
naming the model, so the gap is visible in the ledger rather than silently priced at a stale rate.

## Reading the ledger — the work-ledger step

```
flight prompt-log summary --session <session_id> [--session <id> …] [--since <ISO-8601>] [--json]
```

prints a Markdown block for the issue comment: one line per harness × model with turns, tokens,
and cost; a total; the cost basis; and notes when subagent rows are included or when rows had no
usage (then the total is a lower bound). With no rows for the session it says so explicitly —
"estimate only" is claimed only when there truly is no data. `--json` returns the same aggregate
for scripting. `working-an-issue` Step 4 and the `queue-batches` worker prompt call this.

## Producers

| Harness | Hook file | Events | Producer |
|---|---|---|---|
| Claude Code | `flight/hooks/hooks.json` | `UserPromptSubmit`, `Stop`, `SubagentStop` | `flight/scripts/prompt-logger/claude.py` |
| Codex | `flight/hooks/codex-hooks.json` | `UserPromptSubmit`, `Stop`, `Interrupt`, `SubagentStop` | `flight/scripts/prompt-logger/codex.py` — see [codex-prompt-log.md](codex-prompt-log.md) |

Both import `common.py` (main-worktree resolution via the git common dir, the opt-in check,
pricing lookup, atomic state files, a locked and de-duplicated append). Turn state between the
prompt and stop hooks lives under `$TMPDIR/flight-prompt-logger/` (`FLIGHT_PROMPT_LOG_STATE_DIR`
overrides it — the tests use that).

Claude Code has no `Interrupt` hook: an interrupted turn produces no row until the next `Stop`,
which then covers everything since the last prompt. Its `SubagentStop` payload names the
subagent's transcript (`agent_transcript_path`); the producer sums every assistant request in it
and prices per model, since subagents often run a different model than the main loop.

Transcript formats are internal to each harness and can change between CLI versions. Each
producer recognises the shapes it was verified against (Claude Code JSONL with `type:
"assistant"` / `message.usage` / `requestId` / `isSidechain`; Codex rollouts with
`token_usage_record.turn_token_usage` and `turn_context`) and degrades to `null` + warning
otherwise — fixture-based tests under `scripts/tests/` pin both.
