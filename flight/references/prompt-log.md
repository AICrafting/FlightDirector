# The prompt ledger — `.flightdirector/prompt-log.jsonl`

Flight's work-ledger comments ("this issue cost $X across N turns on model M") are built from a
per-repo **prompt ledger**: one JSON record per agent turn, appended to `.flightdirector/prompt-log.jsonl` under the
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
writes nothing. `setting-up-a-repo` offers to enable it and adds `.flightdirector/prompt-log.jsonl` to
`.gitignore`; do that by hand for an existing repo:

```
echo '.flightdirector/prompt-log.jsonl' >> .gitignore
```

The ledger lives under `.flightdirector/` on purpose: a generic name at the repo root (the
original `prompt_log.jsonl`) is one another tool or a hand-rolled hook could plausibly pick too,
and two producers appending different schemas to one file corrupts both. Flight never reads or
moves an old root `prompt_log.jsonl`; if one is left over, delete it by hand.

> **Other prompt hooks can coexist.** Flight's hooks are plugin-bundled and write only their own
> file; a user's own `UserPromptSubmit`/`Stop` hooks (an audit log, a cost dashboard, another
> plugin's telemetry) keep working alongside them. Never edit, disable, or advise deleting hooks
> in the user's settings files on flight's behalf — at most, mention that another prompt-related
> hook was noticed.

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
  // "part": 2,                  Claude Code: this agent's 2nd, 3rd… row — an agent logs one row per stop, each
  //                              holding only the usage since its previous row (absent on the first)
  // "parent_agent_id": "a1b2…", Claude Code: the agent that launched this one (absent when the main loop did)
  // "spawn_depth": 2,           Claude Code: 1 = launched by the main loop, 2 = by that agent, 3 = the deepest
  // "interrupted": true,        the turn was interrupted; usage is whatever had been reported
  // "usage_missing": "no-usage", only on a row whose token fields are null — why:
  //                              "no-path" (payload named no transcript) | "unreadable" | "no-usage"
  // "models": {"m1": 123, …}   a turn that spanned models — output tokens per model; `model` is the dominant one
}
```

### Semantics that matter for totals

- **`input_tokens` is the total prompt**, including cached tokens. OpenAI reports it that way;
  Anthropic reports the *uncached* portion separately, so the Claude producer adds
  `cache_creation` + `cache_read` to it. Uncached input = `input_tokens − cache_read_tokens −
  cache_creation_tokens`, and that is what the input rate is applied to.
- **A turn is one row**, however many model requests it took. Claude Code's transcript holds one
  entry per content block, all sharing a `requestId` — the producer counts each request once.
  The blocks do **not** all carry the same usage: an early block can hold the streaming-start
  placeholder (`output_tokens: 8`) while the request's last block holds the final count, so the
  producer keeps the block with the most output tokens (#155 — keeping the first undercounted a
  subagent's output about fourfold). Codex reports a cumulative `turn_token_usage`; the producer takes the latest record
  for the exact `turn_id`.
- **Missing data is `null`, never `0`.** If the transcript can't be read or has no usage for the
  turn, the token and cost fields are `null`, `usage_missing` records which of the three causes
  it was, and the hook prints a warning on stderr. A `0` means the provider said zero.
- **`cost_usd` is an estimate at API list prices.** `cost_basis` says how to read it:
  `actual-api` when the harness authenticates with an API key (Anthropic key, Bedrock/Vertex,
  `OPENAI_API_KEY`/`CODEX_API_KEY`) and the number is what you would be billed; `api-equivalent`
  under a subscription login (claude.ai, ChatGPT), where the number is what the same tokens
  *would* cost via the API — useful for comparing issues, not a bill. Override the guess with
  `FLIGHT_CLAUDE_AUTH_MODE=api|subscription` / `FLIGHT_CODEX_AUTH_MODE=api|chatgpt`.
- **Subagent rows** keep the parent `session_id` so a session total includes delegated work.
  On Claude Code one agent usually has **several rows** (see *Several stops per agent* below);
  they are increments, so adding rows is always right and "latest row per agent" is always wrong.
  A nested agent's usage is only ever in its own rows, never its parent's.

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
usage (then the total is a lower bound) — broken down by `usage_missing` cause, with rows that
predate the field counted as "reason not recorded". With no rows for the session it says so explicitly —
"estimate only" is claimed only when there truly is no data. `--json` returns the same aggregate
for scripting. `working-an-issue` Step 4 and the `queue-batches` worker prompt call this.

## Producers

Both producers and `summary.py` are Python 3, standard library only — `python3` on `PATH` is the
ledger's one extra prerequisite (the rest of flight is `bash` + `curl` + `jq`). A repo that never
enables `code.promptLog` never invokes them.

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
and prices per model, since subagents often run a different model than the main loop. A payload
with no `agent_transcript_path` falls back to the parent `transcript_path`, counting only the
sidechain entries whose `agentId` is this agent's.

**Several stops per agent.** `SubagentStop` does not mean "finished". A live capture (34 stops,
14 agents, #155) showed every agent stopping 2–4 times: whenever it parks on a background shell
or on a child agent, again each time it is woken, and once more after handing its report back —
even an agent that ran everything in the foreground stopped twice. Each stop re-reads the whole
transcript, so the producer logs the **increment**: the transcript's totals minus what this
agent's earlier rows already hold, read back from the ledger under the append lock (no side
state to lose). A stop that adds nothing writes no row; rows after the first carry `part`.
Measured against the final transcripts, first-stop-only logging (what flight did before) recorded
72–86% of the real cost, logging every stop whole 155–239%, and increments 100%. The payload's
`background_tasks` cannot be used to pick "the last stop": it lists every shell in the session
with no owner, and an agent still lists itself as running in its own final stop. One residue: the
transcript can trail the stop event by a moment, so a row may miss the last response — the next
stop picks it up, and only an agent's very last response can stay uncounted.

**Agents launched by agents.** A subagent can launch its own (depth 2), and that one another
(depth 3); a depth-3 agent has no Agent tool, so that is the floor. Every nested agent fires its
own `SubagentStop`s with its own `agent_id` and transcript, and a parent's transcript holds none
of its child's requests — so nothing is double-counted and nothing is rolled up. The producer
copies `parentAgentId` / `spawnDepth` from the `agent-<id>.meta.json` beside the transcript onto
the row (`parent_agent_id`, `spawn_depth`) so a reader can attribute a child's cost to the worker
that spawned it. That file is undocumented harness state: when it is missing or changes shape the
fields are simply absent.

**Harness-helper stops.** Claude Code also fires `SubagentStop` for short-lived internal helpers
— observed about every 30 seconds per running background agent — whose payload has an `agent_id`
but no `agent_type`, and whose transcript is never written to disk. They are not agents anyone
launched and nothing about them is measurable, so a `SubagentStop` with **no `agent_type` and no
usage** writes no row (a warning on stderr says so). Before #155 each one became a null row, which
is how one batch run reached 997 "unmeasured" rows out of 1,007. `summary` sets those legacy rows
aside (`helper_stop_rows`) instead of counting them as unmeasured. Whatever tokens the helpers
themselves consume is invisible to the hook, so it is not in any total.

Transcript formats are internal to each harness and can change between CLI versions. Each
producer recognises the shapes it was verified against (Claude Code JSONL with `type:
"assistant"` / `message.usage` / `requestId` / `isSidechain`; Codex rollouts with
`token_usage_record.turn_token_usage` and `turn_context`) and degrades to `null` + warning
otherwise — fixture-based tests under `scripts/tests/` pin both.
