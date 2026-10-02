---
name: queue-batches
description: Use when the user invokes `/queue-batches`, `/queue-batches NxM` (e.g. `3x5`), or says "queue up some batches", "kick off parallel work on some issues", "run N groups of M issues in parallel". Dispatches N background agents in isolated git worktrees, each working M issues sequentially through the working-an-issue lifecycle (stopping at the to-test merge gate), with live status streaming and question routing back to the user.
---

# Queue Batches

Before the first command, follow [runtime preflight](../../references/runtime.md).

Dispatches N parallel background agents, each grinding M issues **sequentially** through the
native per-issue lifecycle (`working-an-issue`) in its own worktree. A *batch is a zone*: the N
agents work disjoint file zones so the concurrently-active issues stay merge-clean. Every issue
gets its own `feature/<branchPrefix>-<slug>` branch (`feature/12-…` with one tracker,
`feature/fj-12-…` with several — the prefix `flight issues resolve` returns) off `stages[0]` and stops at `to-test` — **no agent ever
promotes or pushes**. Live status via per-zone log files + `Monitor`; `status=blocked` questions
route back to the user tagged by zone. Hands back for **serial** promotion via `promoting-a-branch`.

All backend access is through the **flight dispatcher** — never curl, never MCP:

    flight <group> <verb> [--flag value …]

Uses the active harness's native parallel-agent facilities. See
[flight-setup.md](../../references/flight-setup.md) and
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
# Bind the MAIN repo root once (the one permitted bare git — it bootstraps the path);
# every git command below is anchored to it with -C.
ROOT="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"

# Leftover per-issue worktrees from a previous queue:
git -C "$ROOT" worktree list | grep -E '\.worktrees/([a-z][a-z0-9]*-)?[0-9]+-' || true
# Leftover zone status logs not yet cleaned up:
ls "$SCRATCH"/queue-status/*.log 2>/dev/null || true
```

For each leftover, classify from its `ticket=all` line, wherever it sits: no
`ticket=all status=done` → **agent still working**; `status=done` but worktrees still present →
**done, awaiting serial ship/cleanup**.

A lingering **run manifest** (`batch-manifest groups` prints zones) is *not* by itself a block:
a manifest whose issues have **no** `.worktrees/<branchPrefix>-*` worktree left is **stale** — its run was
promoted but never consumed (or was cleaned up by hand). Drop it with
`batch-manifest consume --issues "<those qualified identities>"` and carry on; only a manifest whose issues
still have worktrees is an in-flight run.

Render the current board (Display format below) and push back:

> 🛑 **Ey — I'm workin' here!** There's still a queue in flight: `auth ◐○○` · `core ✓✓ ⇥ ready`.
> Let me finish these (ship serially via `promoting-a-branch`, then remove the worktrees) before
> the next run. Options: **wait** · **force** (share zones with the in-flight run; not advised) ·
> **cancel**.

## 1. Triage & select

1. List open issues via the dispatcher (this is the same data `triaging-issues` uses):
   ```bash
   flight issues list --all-trackers --state open --limit 50
   ```
   Output is `<id>⇥<native id>⇥<title>⇥<labels>` (`FJ-12⇥12⇥…`, `JIR-7⇥PROJ-7⇥…`) across
   every configured tracker — or `#12⇥12⇥…` when the repo has a single tracker, where the prefix
   says nothing. That first column is the issue's id from here on (every flight verb accepts it
   as `--number`, and agents log by it) — two trackers
   can both have an issue 12. A tracker reported `unavailable` on stderr is unavailable, not
   empty. The adapter pages underneath `--limit`. If it warns on
   stderr that it is showing 50 of more, raise `--limit` and list again — otherwise the batch can
   only ever be drawn from the same slice of the backlog, however many agents are aimed at it.
2. Apply the **workable filter** (identical rule to `triaging-issues`): **exclude** any issue
   whose label column carries one of **its own tracker's** `labels.status` roles (in-progress,
   to-test, review, qa, blocked, deferred) — read them with
   `flight issues tracker --tracker "$REF" | jq '.labels.status'`, `$REF` being the id's prefix
   (with a single tracker, `#12`, omit `--tracker`); never match one tracker's rows against another's names. The `new` role, when a
   tracker configures it, stays workable.
3. Resolve zones:
   ```bash
   flight config '.code.zones // "none"'
   ```
   - **Configured** → read each issue's **body** by its id
     (`flight issues get --number FJ-12` — the id routes to its own tracker); match predicted
     touched paths to a zone's `paths` globs. Labels are a hint, not gospel. Skip issues that
     span multiple zones with a note.
   - **`none`** → infer up to N disjoint pseudo-zones by grouping issues whose bodies imply
     non-overlapping paths, and **warn**: "no `code.zones` configured — zones inferred from issue
     bodies; review carefully before approving."
4. Fill N zones with the top M issues each (priority: critical/security → high-value → quick-win →
   rest; smaller scope first within a tier). If a zone has < M eligible issues, shrink that batch
   and report it.

## 2. Present the plan — HALT for approval

Show N×M: per zone, the issues + one-line rationale + the resolved worker model. Wait for explicit
approval. The user may swap/drop/re-zone issues or override the model (per run or per batch); an
override always wins over the configured list.

Resolve the worker model against **this** harness — `code.queueBatches.defaultModel` is a model
name or an ordered preference list, and the same repo is worked from both Claude Code and Codex:

```bash
flight config worker-model --harness "$HARNESS"   # one line per entry: <model>⇥use|skip⇥<reason>
```

- The first `use` line is the worker model. Later `use` lines are the fallbacks for Section 3.
- Show the choice and every skipped entry in the plan, e.g.
  `worker model: gpt-5.6-sol (opus skipped: claude model, not available in codex)`.
- **No `use` line → stop and ask the user which model to use.** Never silently pick one — not
  `sonnet`, not whatever you happen to be running.

## 3. Dispatch

Resolve once:
```bash
DISP=flight
# MAIN repo root (parent of the common git dir) — worktree-safe, matches the dispatcher.
# Already bound in step 0; re-derive only if this is a fresh shell. Every git command in this
# skill and in the dispatched agents is anchored with `git -C <path>` — a bare `git` is a bug.
ROOT="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"
BASE="$("$DISP" config '.code.stages[0].name')"
# Section 2's approved model: the user's override, else the first `use` line. Keep the rest.
MODELS="$("$DISP" config worker-model --harness "$HARNESS" | awk -F'\t' '$2 == "use" { print $1 }')"
MODEL="${OVERRIDE:-$(head -n1 <<<"$MODELS")}"
RULES_FILE="$("$DISP" config '.code.queueBatches.agentRulesFile // ".flightdirector/agent-rules.md"')"
REPO_RULES="$( [ -s "$ROOT/$RULES_FILE" ] && cat "$ROOT/$RULES_FILE" || echo 'None configured.' )"
# The repo's own check command (flight-setup.md → Repo preflight gate). Empty = not configured,
# and the gate sweep in Section 4a is then skipped entirely.
PREFLIGHT="$("$DISP" config '.code.preflight // empty')"
mkdir -p "$SCRATCH/queue-status"
# A run id for this batch; also names the manifest that records issue→zone
# grouping so batch promotion can honor "promote each zone" later.
RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
```

If `REPO_RULES` is `None configured.`, note it in the plan output so the user knows workers run
with universal rails only.

Per zone:
- Create + pre-seed the log so the board renders every issue as `○` before agents start:
  ```bash
  LOG="$SCRATCH/queue-status/<zone>.log"; : > "$LOG"
  # ISSUES = this zone's ids, smallest-first (e.g. "FJ-72 GH-73", or "#72 #73" with one tracker)
  for ISSUE_ID in $ISSUES; do
    echo "$(date -u +%FT%TZ) <zone> ticket=$ISSUE_ID status=queued" >> "$LOG"
  done
  ```
- Render `templates/agent-prompt.md`, filling `{zone} {model} {dispatcher}=$DISP
  {base_branch}=$BASE {repo_root}=$ROOT {log_path}=$LOG {scratch}=$SCRATCH {issues_ordered}
  {repo_rules}=$REPO_RULES {preflight}=${PREFLIGHT:-None configured.} {pre_made_decisions}`
  (`{preflight}` follows `{repo_rules}`' convention: the literal `None configured.` when the repo
  sets no gate, so the rendered prompt never contains a blank command).
- Select and follow exactly one dispatch reference for the active harness:
  [Claude Code](references/dispatch-claude.md) or [Codex](references/dispatch-codex.md).
  Use the approved per-zone model override when present; otherwise use `$MODEL`.
- **If the dispatch fails because the model is unavailable** (no access, not on this plan, unknown
  or retired model), fall through to the next model in `$MODELS`: re-render the prompt with that
  `{model}` and dispatch again. Tell the user which model was dropped and why, and use the
  model that worked for the remaining zones. A failure for any other reason is not a model
  problem — surface it, don't fall through. An explicit user override has no fallbacks: if it
  fails, ask. When the list runs out, stop and ask the user for a model.

Once every zone's issue set is fixed, record the run manifest (one call, all zones) so batch
promotion can reconstruct the grouping — this survives even when zones were *inferred* (no
`code.zones`), which nothing else captures:

```bash
batch-manifest write --run-id "$RUN_ID" \
  --zone <zone-a> --issues "<zone-a ids>" \
  --zone <zone-b> --issues "<zone-b ids>"   # …one pair per zone
```

## 4. Monitor + render

On every worker or log update, parse the line and re-render the board. If the active harness has a
task-board primitive, update the matching issue task (`queued` → pending; `starting`/`working` → in
progress; `complete` → completed; `blocked` → in progress with the note; `preflight-fail` → back to
**in progress** with the failing log path, since that issue is not shippable and was already marked
completed; `preflight-skip` → **also** back to in progress with the note, because a gate that never
ran has verified nothing and leaving the task `completed` recreates exactly the two-boards-disagree
problem; `preflight-pass` → leave the task as it is). When a zone's `ticket=all`
line reads `status=done`, render that zone's header with `⇥` (done, awaiting promotion); `ticket=all
status=safety-valved` means the zone did not finish its queue — render its header with `✗` and
surface its unfinished issues as deferred. When a zone emits its terminal line, start that zone's
repo gate sweep (4a) before rendering it as `⇥`. Once every zone has emitted its terminal line
**and** its sweep has finished, proceed to Section 5. Match tasks by the `[<zone>] <ID>` subject
prefix (e.g. `[auth] FJ-77`).

**An agent returning is not that signal — its `ticket=all` line is.** When a zone's agent returns,
look for that zone's `ticket=all` line. No such line means the zone is **unfinished, regardless of
what the agent said**: a returned agent's account of its own state is the one piece of evidence that
cannot be trusted here (4a's "From the orchestrator, not from the agent" carries the argument; the
harness-specific mechanism is in [Claude Code](references/dispatch-claude.md)). Key on `ticket=all`
wherever it sits, never on position — with `code.preflight` configured, 4a's own lines land after
it. If the agent's latest line is `status=blocked`, that is a question still to route (below).
Otherwise it has most likely parked, so establish what is actually still running before doing
anything. Footgun: the orchestrator's own log watcher appears in a `ps` listing matched on the log
path or worktree, so a match is not proof the worker's job is alive — look for the worker's own
command. If nothing is, resume the agent through the harness's agent-messaging primitive (nothing is
running; redo the step in the foreground and carry on); if it cannot be resumed, surface its
unfinished issues as deferred, as for `safety-valved`.

### 4a. Repo gate sweep — the orchestrator runs it, not the agents

(The repo's `code.preflight` command. Not to be confused with Section 0's "I'm workin' here!"
preflight, which guards against a prior run, or the runtime preflight in
[runtime.md](../../references/runtime.md).)

Skip this entirely when `$PREFLIGHT` is empty; nothing below changes for a repo without the key.

When a zone logs its terminal line, run `$PREFLIGHT` once **per completed issue in that zone**,
in that issue's own worktree. Background the loop as a whole so the orchestrator stays responsive,
and let `Monitor` wake you on the log.

**One sweep runs at a time, across all zones.** Zones finish within minutes of each other, so
backgrounding *per zone* would still put N suites in flight at once — and a check command that
binds a port or a shared fixture then fails in the second zone for reasons that have nothing to do
with the code, recording false reds on green branches. The lock below is what makes that a
mechanism rather than an intention: sweeps are launched from separate `Monitor` wakeups with no
shared state, so "remember to serialize" is precisely the kind of instruction that gets dropped.
Nothing is waiting on a sweep, so serial costs only wall clock.

```bash
# ZONE and ZONE_LOG are this sweep's own, not whatever Section 3's loop left bound.
ZONE=<zone>
ZONE_LOG="$SCRATCH/queue-status/$ZONE.log"
LOCK="$SCRATCH/queue-status/.sweep.lock"

# mkdir is atomic on every platform flight supports, so it is the portable mutex:
# it succeeds for exactly one caller and fails for the rest. Wait, don't skip —
# this zone still needs its gate run. But BOUND the wait: the trap below covers
# EXIT/INT/TERM and cannot cover SIGKILL, so one hard kill leaves the directory
# standing and every later zone would spin here forever, emitting nothing. A wedged
# lock must surface as unverified issues, not as silence.
T=0
until mkdir "$LOCK" 2>/dev/null; do
  T=$((T + 20))
  if [ "$T" -ge 1800 ]; then
    # 30 minutes on a lock nobody released: assume a killed sweep, and say so per issue.
    # NOTE (#227): a fixed bound cannot tell *wedged* from *busy*, and this one is too
    # short for the documented 3x5 default — the last zone legitimately waits
    # (N-1) x M x <suite>, so 3 zones x 5 issues x 5 min means a 50-minute honest wait
    # that trips this at 30 and records five FALSE skips. Read 1800 as a stopgap, not a
    # considered value. #227 replaces it with a heartbeat, which can also reclaim the
    # stale directory this path deliberately leaves standing.
    for ISSUE_ID in <that zone's ids with status=complete>; do
      echo "$(date -u +%FT%TZ) $ZONE ticket=$ISSUE_ID status=preflight-skip note=\"lock timeout; stale $LOCK?\"" >> "$ZONE_LOG"
    done
    exit 0          # this zone reports unverified; it does NOT run ungated behind the lock
  fi
  sleep 20
done
# Set the trap only AFTER acquiring, or a caller that never got in would remove the
# holder's lock on its way out.
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

for ISSUE_ID in <that zone's ids with status=complete>; do
  PFLOG="$SCRATCH/queue-status/$ZONE-preflight-${ISSUE_ID#\#}.log"   # #12 → …-preflight-12.log
  # The branch prefix comes from the resolver (#12 → 12 with one tracker, FJ-12 → fj-12
  # with several); never derive it. The trailing "-" keeps 1 from matching 12's worktree.
  PREFIX="$("$DISP" issues resolve --number "$ISSUE_ID" | jq -r '.branchPrefix')"
  # Resolve the worktree by glob — the loop knows the identity, not the slug. Use the
  # positional params rather than a variable: a two-match glob collapses into one
  # space-joined string that fails `[ -d ]`, and "no worktree" would be a lie when the
  # truth is "more than one". No arrays — the BSD and MSYS legs run bash 3.2.
  set -- "$ROOT/.worktrees/$PREFIX"-*
  # A missing worktree is NOT a gate failure: recording it as one says "your code is
  # broken" when the truth is "I could not find your code".
  if [ "$#" -gt 1 ]; then
    echo "$(date -u +%FT%TZ) $ZONE ticket=$ISSUE_ID status=preflight-skip note=\"$# worktrees match\"" >> "$ZONE_LOG"
    continue
  fi
  if [ ! -d "$1" ]; then
    echo "$(date -u +%FT%TZ) $ZONE ticket=$ISSUE_ID status=preflight-skip note=\"no worktree\"" >> "$ZONE_LOG"
    continue
  fi
  if ( cd "$1" && sh -c "$PREFLIGHT" ) >"$PFLOG" 2>&1; then
    echo "$(date -u +%FT%TZ) $ZONE ticket=$ISSUE_ID status=preflight-pass" >> "$ZONE_LOG"
  else
    echo "$(date -u +%FT%TZ) $ZONE ticket=$ISSUE_ID status=preflight-fail note=\"$PFLOG\"" >> "$ZONE_LOG"
  fi
done
```

Write `$ZONE_LOG` from this sweep's own zone name. `$LOG` from Section 3 is bound **inside** the
per-zone dispatch loop, so by the time a sweep runs it holds the last-dispatched zone's path, and
every verdict would be filed against the wrong zone.

**Per worktree, not once per zone.** Each worktree holds exactly one issue's change on top of
`$BASE`, so a red gate names the issue that broke it. A single run over the merged result would
only tell you the zone is red.

**From the orchestrator, not from the agent** — this is mechanism, not preference. A returned
sub-agent's shell is gone with it, so a command backgrounded inside an agent has nothing left to
write its result into, and the gate would be recorded as neither pass nor fail. The
orchestrator's session survives the whole run and its `Monitor` wakes it when the log moves, so
it is the only place a multi-minute gate can be both backgrounded and believed. The agents still
get the command (they run it in the *foreground*, for the baseline and before each `to-test`) —
that is what "tests green after every commit" means in a repo that configures one. The
orchestrator's sweep is the authoritative record.

## Status log format (contract)

Agents append one line per state change to `$SCRATCH/queue-status/<zone>.log`:

```
<ISO-timestamp> <zone> ticket=<ID> status=<queued|starting|working|complete|blocked|preflight-pass|preflight-fail|preflight-skip> [commit=<sha7>] [note="…"]
```
`queued` is pre-seeded by the orchestrator before dispatch; workers emit `starting`/`working`/`complete`/`blocked`.
The three `preflight-*` statuses are written by the **orchestrator** after the zone's terminal
line (Section 4a) and appear only when `code.preflight` is configured: `preflight-fail` carries
the failing log's path in `note=`, and `preflight-skip` means the gate could not be **run** at all
rather than that it failed — never conflate the two, since one is a problem with the code and the
other is a problem with the workspace. Its `note=` says which: no worktree, several worktrees
matching the issue, or a lock timeout. All three mean *unverified*, so all three are
reported. Terminal line, the agent's last (4a's three statuses may follow it, so match on
`ticket=all`, not on position): `<ts> <zone> ticket=all status=<done|safety-valved> note="…"`.

## Display format (stacked, phone-legible)

```
━━━ auth ━━━
  ✓ FJ-77 complete (a1b2c3d)
  ◐ FJ-73 working — writing tests
  ○ FJ-74 GH-72 queued

━━━ core ━━━
  ? FJ-112 blocked — "which migration tool?"
  ! FJ-64 preflight failed — <log path>
  ○ JIR-65 queued
```

Legend: `✓` complete · `◐` working (also shown for `starting`) · `?` blocked · `○` queued ·
`!` preflight failed · `~` preflight skipped, i.e. never ran (see its `note=`) · `✗` zone
safety-valved · `⇥` done,
awaiting promotion. One line per issue. A `preflight-pass` line leaves the issue's `✓` alone —
the gate is only worth pixels when it doesn't pass.

## Question routing protocol

When an agent writes `status=blocked`: parse `note="…"`, render the board, then below it:

> **[<zone>] <ID> needs input:** <question>

Wait for the user's answer, then use the active harness's agent-messaging primitive with body
`User says: <answer>. Continue.` Treat the agent as `working` until its next log line.

## 5. Completion & ship

Once every zone has a `ticket=all` line reading `status=done` or `status=safety-valved` **and**
its 4a sweep (when one is configured) has finished — the Section 4 condition, not merely every
agent having returned: summarize each zone (commits with
SHA + title, test deltas, judgment calls, deferrals). Surface any skipped/deferred issue with a
follow-up suggestion. Report each `preflight-fail` issue by its id with its log path and a tail
of the failure, and say plainly that it should not be promoted until the gate is green —
`promoting-branches` will skip it anyway, but the user deserves to know before they say "ship the
batch". Report every `preflight-skip` too, with its `note=` reason: the gate never ran on that
issue, so it is **unverified**, not clean. Silence here would let an ungated issue read as a
passing one, which is the failure the sweep exists to prevent. Continuing that zone's agent with
the failing output (via the question-routing primitive) is a reasonable option to offer; it is not
automatic. Then hand back for shipping — the orchestrator never auto-promotes:

> Ship the batch with `promoting-branches`: say "promote each zone" (one PR per zone on a pr hop, or
> all branches merged on a direct hop), "promote the first zone", or "promote issues <…>". It honors
> `stages[0]`'s merge strategy and cleans up the run manifest as issues promote. For a single branch,
> or to hand-pick, use `promoting-a-branch` one at a time.

## Common mistakes

- **Over-filling batches.** Start `3x5`; escalate only when proven. `3x8` nears the orchestrator
  context ceiling.
- **Zoning by label alone.** Labels lie — read the issue body before placing.
- **Skipping plan approval.** The user must OK the triage before dispatch.
- **Taking a returned agent's word for its zone's state.** Look for the zone's `ticket=all`
  line; no such line means unfinished, whatever the report said.
- **Forgetting `tail -f` + `Monitor`.** Without them you're blind between completions.
- **Letting an agent push or promote.** Both are banned in the prompt — keep it that way.
- **Delegating the preflight sweep to the agents.** Their shells die when they return, so a
  backgrounded gate inside one reports nothing and a foreground one blocks the zone for minutes.
  The orchestrator owns the sweep; the agents run the same command in the foreground as they
  work, which is a different job.
- **Auto-promoting at the end.** Hand back for serial, user-gated `promoting-a-branch`.
