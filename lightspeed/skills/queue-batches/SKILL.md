---
name: queue-batches
description: Use when the user invokes `/queue-batches`, `/queue-batches NxM` (e.g. `3x5`), or says "queue up some batches", "kick off parallel work on some issues", "run N groups of M issues in parallel". Dispatches N background agents in isolated git worktrees, each working M issues sequentially through the working-an-issue lifecycle (stopping at the to-test merge gate), with live status streaming and question routing back to the user.
---

# Queue Batches

Dispatches N parallel background agents, each grinding M issues **sequentially** through the
native per-issue lifecycle (`working-an-issue`) in its own worktree. A *batch is a zone*: the N
agents work disjoint file zones so the concurrently-active issues stay merge-clean. Every issue
gets its own `feature/<N>-<slug>` branch off `stages[0]` and stops at `to-test` — **no agent ever
promotes or pushes**. Live status via per-zone log files + `Monitor`; `status=blocked` questions
route back to the user tagged by zone. Hands back for **serial** promotion via `promoting-a-branch`.

All backend access is through the **lightspeed dispatcher** — never curl, never MCP:

    "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" <group> <verb> [--flag value …]

Builds on `superpowers:dispatching-parallel-agents`. See
[lightspeed-setup.md](../../references/lightspeed-setup.md) and
[adapter-contract.md](../../references/adapter-contract.md).

## Arguments

`/queue-batches NxM` — default `3x5`. Format `<batchCount>x<ticketsPerBatch>`.
- `N` = zones run concurrently. Cap **3** (orchestrator-context safety).
- `M` = issues per zone, worked sequentially. Cap **8** (sub-agent-context safety).

Status logs live under your **session scratchpad directory**, referred to below as `$SCRATCH`
(`$SCRATCH/queue-status/<zone>.log`). Substitute the actual scratchpad path provided for this
session; it is per-session and isolated from the target repo.

## When NOT to use

- Work needing tight interactive iteration mid-task (many judgment calls).
- A single issue — just use `working-an-issue`.
- Issues that all live in one file zone — run them sequentially on one zone instead.

## 0. Preflight — "I'm workin' here!" guard

Before anything else, detect an in-flight or awaiting-cleanup prior run. Block (unless the user
passes `force`) if either is true:

```bash
# Leftover per-issue worktrees from a previous queue:
git worktree list | grep -E '\.worktrees/[0-9]+-' || true
# Leftover zone status logs not yet cleaned up:
ls "$SCRATCH"/queue-status/*.log 2>/dev/null || true
```

For each leftover, classify from the log's last line: no `ticket=all status=done` → **agent still
working**; `status=done` but worktrees still present → **done, awaiting serial ship/cleanup**.
Render the current board (Display format below) and push back:

> 🛑 **Ey — I'm workin' here!** There's still a queue in flight: `auth ◐○○` · `core ✓✓ ⇥ ready`.
> Let me finish these (ship serially via `promoting-a-branch`, then remove the worktrees) before
> the next run. Options: **wait** · **force** (share zones with the in-flight run; not advised) ·
> **cancel**.

## 1. Triage & select

1. List open issues via the dispatcher (this is the same data `triaging-issues` uses):
   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues list --state open --limit 50
   ```
   Output is `<number>⇥<title>⇥<labels>`. Paginate if a full page returns.
2. Apply the **workable filter** (identical rule to `triaging-issues`): **exclude** any issue
   whose label column carries any configured `labels.status` role (in-progress, to-test, review,
   qa, blocked, deferred) — it's already in the workflow, not a fresh pick.
3. Resolve zones:
   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.zones // "none"'
   ```
   - **Configured** → read each issue's **body** (`issues get --number N`); match predicted
     touched paths to a zone's `paths` globs. Labels are a hint, not gospel. Skip issues that
     span multiple zones with a note.
   - **`none`** → infer up to N disjoint pseudo-zones by grouping issues whose bodies imply
     non-overlapping paths, and **warn**: "no `code.zones` configured — zones inferred from issue
     bodies; review carefully before approving."
4. Fill N zones with the top M issues each (priority: critical/security → high-value → quick-win →
   rest; smaller scope first within a tier). If a zone has < M eligible issues, shrink that batch
   and report it.

## 2. Present the plan — HALT for approval

Show N×M: per zone, the issues + one-line rationale + the resolved worker model
(`config '.code.queueBatches.defaultModel // "sonnet"'`). Wait for explicit approval. The user may
swap/drop/re-zone issues or override the model (per run or per batch).

## 3. Dispatch

Resolve once:
```bash
DISP="$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"
# MAIN repo root (parent of the common git dir) — worktree-safe, matches the dispatcher:
ROOT="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"
BASE="$("$DISP" config '.code.stages[0].name')"
MODEL="$("$DISP" config '.code.queueBatches.defaultModel // "sonnet"')"   # unless user overrode
RULES_FILE="$("$DISP" config '.code.queueBatches.agentRulesFile // ".lightspeed/agent-rules.md"')"
REPO_RULES="$( [ -s "$ROOT/$RULES_FILE" ] && cat "$ROOT/$RULES_FILE" || echo 'None configured.' )"
mkdir -p "$SCRATCH/queue-status"
```

If `REPO_RULES` is `None configured.`, note it in the plan output so the user knows workers run
with universal rails only.

Per zone:
- Create + pre-seed the log so the board renders every issue as `○` before agents start:
  ```bash
  LOG="$SCRATCH/queue-status/<zone>.log"; : > "$LOG"
  # ISSUES = this zone's issue numbers, smallest-first (e.g. "72 73 74")
  for ISSUE_NUM in $ISSUES; do
    echo "$(date -u +%FT%TZ) <zone> ticket=#$ISSUE_NUM status=queued" >> "$LOG"
  done
  ```
- Render `templates/agent-prompt.md`, filling `{zone} {model} {dispatcher}=$DISP
  {base_branch}=$BASE {repo_root}=$ROOT {log_path}=$LOG {scratch}=$SCRATCH {issues_ordered}
  {repo_rules}=$REPO_RULES {pre_made_decisions}`.
- Launch with the `Agent` tool: `run_in_background: true`, `model: <MODEL or override>`.
  (`<MODEL or override>` is `$MODEL`, unless the user set a model override for this specific zone
  during plan approval — then use that zone's value.)
- `TaskCreate` one task per issue — subject `[<zone>] #<N> — <title>`, description
  `<zone> · <labels>` — plus one per-zone ship task `Ship <zone> (serial promote + cleanup)`.
- Launch `tail -f "$LOG"` with `run_in_background: true` and attach `Monitor` so each new log line
  becomes a notification.

## 4. Monitor + render

On every `Monitor` notification: parse the log line, re-render the board, and `TaskUpdate` the
matching issue task (`queued` → leave the task `pending`, render `○`; `starting`/`working` →
in_progress; `complete` → completed; `blocked` → keep in_progress + append the note). When a zone's
final line is `status=done`, render that zone's header with `⇥` (done, awaiting promotion); a final
`status=safety-valved` means the zone did not finish its queue — render its header with `✗` and
surface its unfinished issues as deferred. Once every zone has emitted a terminal line (`done` or
`safety-valved`), proceed to Section 5. Match tasks by the `[<zone>] #<N>` subject prefix.

## Status log format (contract)

Agents append one line per state change to `$SCRATCH/queue-status/<zone>.log`:

```
<ISO-timestamp> <zone> ticket=<#N> status=<queued|starting|working|complete|blocked> [commit=<sha7>] [note="…"]
```
`queued` is pre-seeded by the orchestrator before dispatch; workers emit `starting`/`working`/`complete`/`blocked`.
Final per-zone line: `<ts> <zone> ticket=all status=<done|safety-valved> note="…"`.

## Display format (stacked, phone-legible)

```
━━━ auth ━━━
  ✓ #77 complete (a1b2c3d)
  ◐ #73 working — writing tests
  ○ #74 #72 queued

━━━ core ━━━
  ? #112 blocked — "which migration tool?"
  ○ #64 #65 queued
```

Legend: `✓` complete · `◐` working (also shown for `starting`) · `?` blocked · `○` queued · `✗` zone safety-valved · `⇥` done, awaiting promotion. One line per issue.

## Question routing protocol

When an agent writes `status=blocked`: parse `note="…"`, render the board, then below it:

> **[<zone>] #<N> needs input:** <question>

Wait for the user's answer, then `SendMessage` to the blocked agent's id with body
`User says: <answer>. Continue.` Treat the agent as `working` until its next log line.

## 5. Completion & ship

When all agents return: summarize each zone (commits with SHA + title, test deltas, judgment
calls, deferrals). Surface any skipped/deferred issue with a follow-up suggestion. Then hand back
for **serial** shipping — the orchestrator never auto-promotes:

> Ship one branch at a time with `promoting-a-branch`: promote → wait for the merge → promote the
> next. The merge after each ship is what keeps the following branch conflict-free (especially for
> same-zone branches, which fork independently from `stages[0]`). After each branch merges, remove
> its worktree: `git worktree remove .worktrees/<N>-<slug>`.

## Common mistakes

- **Over-filling batches.** Start `3x5`; escalate only when proven. `3x8` nears the orchestrator
  context ceiling.
- **Zoning by label alone.** Labels lie — read the issue body before placing.
- **Skipping plan approval.** The user must OK the triage before dispatch.
- **Forgetting `tail -f` + `Monitor`.** Without them you're blind between completions.
- **Letting an agent push or promote.** Both are banned in the prompt — keep it that way.
- **Auto-promoting at the end.** Hand back for serial, user-gated `promoting-a-branch`.
