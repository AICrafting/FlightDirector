# queue-batches — design

Adapt Aaron's `queue-batches` parallel-work skill (shared at
Aaron's private skills folder) into the **lightspeed** plugin as
`lightspeed/skills/queue-batches`. This is the parallel-issue capability the
worktrees/stages/promotion work was phase-one groundwork for.

The source skill is **zone-batched**: N parallel agents, each owning one branch
(`feat/<zone>-<date>`) that carries M issues. lightspeed is **one-issue-one-branch-one-worktree**
(`working-an-issue`), each branch promoted individually via `promoting-a-branch`. This design
resolves that fork and ports the reusable orchestration onto lightspeed's dispatcher, stages,
and status-label conventions.

## Decisions (locked during brainstorming)

1. **Granularity — hybrid.** A *batch* is a *zone*. Each of the N background agents owns one
   zone and grinds its M issues **sequentially**, each issue in its own native
   `feature/<N>-<slug>` worktree off `stages[0]`, mirroring `working-an-issue` ×M. No
   shared/multi-issue branches. Merge-cleanliness is guaranteed **across** zones (the N
   concurrently-active issues live in disjoint file zones); **within** a zone, sequential
   branches fork independently from `stages[0]` and any overlap is resolved by serial shipping.
2. **Zones — optional config with inference fallback.** `code.zones` in `.lightspeed.json` if
   present (deterministic); otherwise the orchestrator infers N disjoint pseudo-zones from issue
   bodies at triage time and warns it is a best guess.
3. **Hand-off point — full lifecycle up to the merge gate.** Each agent takes its issue through
   `in-progress → work+commit → to-test → finishing comment`, then **STOPS**. Never promotes,
   never pushes. Honors `working-an-issue`'s merge-gate red flag; the board reflects every
   transition live.
4. **Per-repo agent rules — repo-root markdown file.** `.lightspeed-agent-rules.md` at repo root
   (override via `code.queueBatches.agentRulesFile`), injected verbatim into the agent prompt.
   Absent → universal rails only + a notice.
5. **Worker model — config-driven, bootstrap-seeded.** Resolution order: plan-approval override →
   `code.queueBatches.defaultModel` → built-in fallback (`sonnet`). `bootstrapping-labels` seeds
   the config key. Future-proofs for later models.

## Invocation

`/queue-batches NxM` (default `3x5`). Format `<batchCount>x<ticketsPerBatch>`.

- `N` = zones run concurrently. Cap **3** (orchestrator-context safety).
- `M` = issues per zone, worked sequentially. Cap **8** (sub-agent-context safety).

## Config surface (`.lightspeed.json`, `code` axis)

```jsonc
"code": {
  "stages": [ /* existing */ ],
  "zones": [                                  // optional; absent → inference fallback
    { "name": "auth", "paths": ["src/auth/**", "src/routes/auth.*"] },
    { "name": "core", "paths": ["src/db.*", "migrations/**", "scripts/**"] }
  ],
  "queueBatches": {                            // optional block; all keys optional
    "defaultModel": "sonnet",                  // bootstrap-seeded; plan-approval can override
    "agentRulesFile": ".lightspeed-agent-rules.md"  // default path if key omitted
  }
}
```

- Read via the dispatcher's `config` group, e.g.
  `lightspeed config '.code.zones'`, `lightspeed config '.code.queueBatches.defaultModel'`.
- Resolution at the **main repo root** (worktree-safe) — same mechanism the dispatcher already uses.

## Flow

### 0. Preflight — "I'm workin' here!" guard
Detect an in-flight or awaiting-cleanup prior run before dispatching: scan for leftover
`queue-status/<zone>.log` files in the scratchpad and leftover `.worktrees/` entries / unmerged
`feature/<N>-<slug>` branches from a previous queue. If a run is still active or awaiting ship,
render the current board and block unless the user passes `force`.

### 1. Triage & select (reuses `triaging-issues` logic — does not re-implement)
- `lightspeed issues list --state open --limit 50` (paginate if a full page returns).
- Apply the **workable filter**: exclude any issue carrying a `labels.status` role (same rule
  `triaging-issues` uses — in flight / to-test / review / qa / blocked / deferred).
- Read each issue **body** (labels are a hint) to assign a zone. Skip cross-zone issues with a
  note. Score/select top M per zone (priority tiers, smaller scope first). If a zone has < M
  eligible, shrink that batch and report it.

### 2. Present the plan — HALT for approval
Show N×M: zones, issues, rationale per batch, resolved worker model. Wait for approval. User may
swap/drop/re-zone issues or override the model per batch.

### 3. Dispatch (all backend via the dispatcher — never curl)
Per zone:
- Resolve worker model (override → `code.queueBatches.defaultModel` → `sonnet`).
- Read `code.queueBatches.agentRulesFile` (default `.lightspeed-agent-rules.md`); inject its
  contents verbatim into the agent prompt's repo-rules slot, or note absence.
- Create `<scratchpad>/queue-status/<zone>.log`, pre-seed a `ticket=#N status=queued` line per
  issue (smallest-first).
- Render the prompt from `templates/agent-prompt.md`, launch with `Agent`,
  `run_in_background: true`, resolved `model`.
- `TaskCreate` one task per issue: `[<zone>] #N — <title>`, plus a per-zone ship task.
- Launch `tail -f <scratchpad>/queue-status/<zone>.log` (`run_in_background: true`) + attach
  `Monitor`.

### 4. Each agent's per-issue lifecycle (sequential, ×M)
For each issue, in order:
1. Create worktree: `git worktree add -b feature/<N>-<slug> .worktrees/<N>-<slug> "$BASE"`
   where `$BASE` = `lightspeed config '.code.stages[0].name'`.
2. `lightspeed issues set-status --number N --status in-progress`; log `status=starting`.
3. Work + commit (tests green per commit); log `status=working` midway as useful.
4. `lightspeed issues set-status --number N --status to-test`.
5. Comment a finishing record via `lightspeed issues comment --number N --body-file …`.
6. Log `status=complete commit=<sha7>`. **STOP** — leave the worktree unmerged; move to next issue.

Never promote, never push. Worktrees persist until serial promotion by the user.

### 5. Monitor + render
On each Monitor notification: parse the log line (contract below), re-render the stacked
phone-legible board, and `TaskUpdate` the matching issue task. `status=blocked` → surface tagged
by zone → user answers → `SendMessage` to the agent to continue.

### 6. Completion & ship
Summarize each zone (commits, test deltas, judgment calls, deferrals). Hand back with **serial
promotion guidance pointing at `promoting-a-branch`** (promote one branch → wait for merge →
next). The orchestrator never auto-promotes.

## Status log format (contract — kept from source)

```
<ISO-timestamp> <zone> ticket=<#N> status=<starting|working|complete|blocked|failed> [commit=<sha7>] [note="…"]
```
Final line per zone: `<ts> <zone> ticket=all status=<done|safety-valved> note="…"`.

## Display format (stacked, phone-legible — kept from source)
Per-zone header `━━━ <zone> ━━━`, one line per issue.
Legend: `✓` complete · `◐` working · `?` blocked · `○` queued · `✗` failed.

## Universal agent rails (baked into the template, not configurable)
No push · no promote · safety-valve on uncertainty / >15 min stall / out-of-scope · tests green
per commit · all backend access via the lightspeed dispatcher (never curl/MCP) · re-read
acceptance and walk the user-visible surface before declaring done.

## Components

| Unit | Responsibility | Depends on |
|---|---|---|
| `skills/queue-batches/SKILL.md` | Orchestrator: preflight, triage, plan, dispatch, monitor, completion | dispatcher (`issues`/`config`), `triaging-issues` filter, `Agent`/`Monitor`/`Task*`/`SendMessage` |
| `skills/queue-batches/templates/agent-prompt.md` | Per-agent worker prompt (dispatcher-based, repo-rules slot, universal rails) | dispatcher (`issues`), `working-an-issue` lifecycle, `promoting-a-branch` (referenced, not run) |
| `.lightspeed.json` `code.zones` + `code.queueBatches` | Per-repo zones, worker model, rules-file path | dispatcher `config` |
| `.lightspeed-agent-rules.md` (target repo) | Repo-specific CI gotchas, injected verbatim | — |
| `bootstrapping-labels` (extended) | Seed `code.queueBatches.defaultModel` | dispatcher `config` |

## Out of scope (optional future companions)
- `statusline.sh` — companion artifact, not a skill.
- `bootstrapping-labels` seeding a starter `code.zones` block.
- Orchestrator auto-promotion (deliberately excluded — violates the merge gate).
- Additional backends — handled by the existing adapter contract, not this skill.
