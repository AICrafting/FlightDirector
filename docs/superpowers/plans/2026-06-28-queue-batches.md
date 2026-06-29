# queue-batches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `lightspeed/skills/queue-batches` skill that dispatches N background agents, each grinding M issues sequentially through the native `working-an-issue` lifecycle in isolated worktrees, with live status streaming, question routing, and a serial-ship hand-off — adapted from Aaron's zone-batched source skill.

**Architecture:** A *batch is a zone*. Each background `Agent` owns one zone and works its M issues **one-issue-one-branch** (`feature/<N>-<slug>` off `stages[0]`), stopping each at the `to-test` merge gate — never promoting, never pushing. Zones (optional `code.zones`) keep the N concurrently-active issues in disjoint file paths so they stay merge-clean; absent config, the orchestrator infers pseudo-zones from issue bodies and warns. The orchestrator triages (reusing `triaging-issues`' workable filter), gets plan approval, dispatches, then renders a phone-legible board from per-zone log files via `Monitor`, routing `status=blocked` questions back to the user. All backend access is through the **dispatcher** (`lightspeed issues …`, `lightspeed config …`) — never curl.

**Tech Stack:** bash + `jq` (dispatcher reads), Markdown SKILL.md + a prompt template, the `Agent`/`Monitor`/`Task*`/`SendMessage` orchestration tools, and the `test-rig/forgejo` disposable Forgejo for live verification. No new language or dependency.

**Verification model:** This repo has no unit-test framework; its established pattern is `shellcheck -x` on extracted bash + offline dispatcher `config` checks + the rig smoke script. SKILL/template changes get a shellcheck-clean command audit plus a scripted rig walkthrough of the verbs they invoke. Config additions get an offline `lightspeed config` read with exact expected output.

**Source to adapt:** Aaron's private skills folder (`SKILL.md`, `templates/agent-prompt.md`). Keep its reusable orchestration prose verbatim where unchanged (DRY — don't re-transcribe); the tasks below give the **exact** replacement text for every part that changes.

**Phasing:** Phase 1 (Tasks 1–2) is the config foundation — independently committable. Phase 2 (Tasks 3–5) builds the template + skill on top. Phase 3 (Task 6) registers + documents + does an end-to-end rig walkthrough. Do them in order.

**Spec:** `docs/superpowers/specs/2026-06-28-queue-batches-design.md`.

---

## Phase 1 — Config foundation

### Task 1: Document `code.zones` + `code.queueBatches` config keys

The dispatcher's `config` group already reads any jq path, so no dispatcher code changes — this task documents the new optional keys and proves the read paths (including the absent→`null` behavior the skill's fallback relies on).

**Files:**
- Modify: `lightspeed/references/lightspeed-setup.md` (add a "queue-batches config" section)

- [ ] **Step 1: Write the offline check (new keys read; absent → null)**

```bash
cat > "$SCRATCH/ls-qb-config-check.sh" <<'EOF'
set -euo pipefail
DISP="$PWD/lightspeed/scripts/lightspeed"
T="$(mktemp -d)"; cd "$T"; git init -q
cat > .lightspeed.json <<'JSON'
{ "code": {
    "backend":"forgejo","owner":"o","repo":"r","api":"http://127.0.0.1:9/api/v1",
    "stages":[{"name":"develop","merge":"direct"}],
    "zones":[{"name":"auth","paths":["src/auth/**"]},{"name":"core","paths":["src/db.*"]}],
    "queueBatches":{"defaultModel":"sonnet","agentRulesFile":".rules.md"} } }
JSON
echo '{ "code": { "token":"t" } }' > .lightspeed.secrets.json
echo "zones[0].name: $("$DISP" config '.code.zones[0].name')"                 # expect: auth
echo "defaultModel:  $("$DISP" config '.code.queueBatches.defaultModel')"     # expect: sonnet
echo "rulesFile:     $("$DISP" config '.code.queueBatches.agentRulesFile')"   # expect: .rules.md
# Absent-key behavior the skill relies on:
echo '{ "code": { "backend":"forgejo","owner":"o","repo":"r","api":"x","stages":[{"name":"develop","merge":"direct"}] } }' > .lightspeed.json
echo "absent zones:  $("$DISP" config '.code.zones // "none"')"               # expect: none
echo "absent model:  $("$DISP" config '.code.queueBatches.defaultModel // "sonnet"')"  # expect: sonnet
EOF
bash "$SCRATCH/ls-qb-config-check.sh"
```

- [ ] **Step 2: Run it to verify it passes already (no code change needed)**

Run: `bash "$SCRATCH/ls-qb-config-check.sh"`
Expected: prints `auth`, `sonnet`, `.rules.md`, then `none`, `sonnet`. (The generic `config` passthrough handles arbitrary paths and jq `//` defaults — confirming the skill can safely read optional keys.)

- [ ] **Step 3: Document the keys in `lightspeed-setup.md`**

Add this section near the `code.stages` documentation:

```markdown
### queue-batches config (all optional)

Consumed only by the `queue-batches` skill; absent keys fall back safely.

- `code.zones` — `[{ "name": "...", "paths": ["glob", ...] }]`. Disjoint file zones used to
  schedule parallel work so concurrently-running issues never touch the same paths. If omitted,
  `queue-batches` infers pseudo-zones from issue bodies at triage time and warns it is a guess.
- `code.queueBatches.defaultModel` — worker-agent model when the user gives no per-run override.
  Seeded by `bootstrapping-labels`; falls back to `sonnet` if unset.
- `code.queueBatches.agentRulesFile` — path (repo-relative) to a markdown file of repo-specific
  agent hard-rules / CI gotchas, injected verbatim into each worker prompt. Defaults to
  `.lightspeed-agent-rules.md`; if that file is absent, workers run with universal rails only.
```

- [ ] **Step 4: Verify the doc references match the check**

Run: `grep -nE 'code\.zones|code\.queueBatches\.(defaultModel|agentRulesFile)|lightspeed-agent-rules\.md' lightspeed/references/lightspeed-setup.md`
Expected: matches for all three keys and the default rules-file name.

- [ ] **Step 5: Commit**

```bash
git add lightspeed/references/lightspeed-setup.md
git commit -m "queue-batches: document code.zones + code.queueBatches config keys

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: Seed `code.queueBatches.defaultModel` in `bootstrapping-labels`

**Files:**
- Modify: `lightspeed/skills/bootstrapping-labels/SKILL.md` (the `.lightspeed.json` write step + a note about zones)

- [ ] **Step 1: Locate the config-write block**

Run: `grep -n 'Write `.lightspeed.json`\|"stages"\|"labels"' lightspeed/skills/bootstrapping-labels/SKILL.md`
Expected: shows the "Write `.lightspeed.json` at the repo root …" step and the JSON skeleton containing `"stages"` and `"labels"`. Read that block (≈lines 98–125).

- [ ] **Step 2: Add `queueBatches.defaultModel` to the written config skeleton**

In the `.lightspeed.json` skeleton inside that step, add a `queueBatches` block to the `code`
object, immediately after the `stages` array. The skeleton's `code` object becomes:

```jsonc
"code": {
  "backend": "...",
  "owner": "...",
  "repo": "...",
  "api": "...",
  "stages": [ /* chosen preset */ ],
  "queueBatches": { "defaultModel": "sonnet" }
},
```

Add this sentence to the prose right after the skeleton:

```markdown
`code.queueBatches.defaultModel` sets the default model the `queue-batches` skill gives its
worker agents (overridable per run). `sonnet` is a sensible default for mechanical implementation
work; change it here to retarget all future parallel runs (e.g. to a newer model) without editing
the skill. You can also add an optional `code.zones` array later — see
[lightspeed-setup.md](../../references/lightspeed-setup.md) — to make `queue-batches` schedule
deterministically instead of inferring zones.
```

- [ ] **Step 3: Offline check — a generated config seeds the key and reads back**

```bash
cat > "$SCRATCH/ls-bootstrap-model-check.sh" <<'EOF'
set -euo pipefail
DISP="$PWD/lightspeed/scripts/lightspeed"
T="$(mktemp -d)"; cd "$T"; git init -q
# Mimic the skeleton bootstrapping-labels now writes:
cat > .lightspeed.json <<'JSON'
{ "code": { "backend":"forgejo","owner":"o","repo":"r","api":"http://127.0.0.1:9/api/v1",
            "stages":[{"name":"develop","merge":"direct"}],
            "queueBatches":{"defaultModel":"sonnet"} },
  "issues": { "labels": {} } }
JSON
echo '{ "code": { "token":"t" } }' > .lightspeed.secrets.json
echo "seeded model: $("$DISP" config '.code.queueBatches.defaultModel // "MISSING"')"  # expect: sonnet
EOF
bash "$SCRATCH/ls-bootstrap-model-check.sh"
```

Run: `bash "$SCRATCH/ls-bootstrap-model-check.sh"`
Expected: prints `seeded model: sonnet`.

- [ ] **Step 4: Verify the SKILL.md skeleton actually contains the key**

Run: `grep -n 'queueBatches' lightspeed/skills/bootstrapping-labels/SKILL.md`
Expected: at least one match in the config skeleton and one in the prose note.

- [ ] **Step 5: Commit**

```bash
git add lightspeed/skills/bootstrapping-labels/SKILL.md
git commit -m "bootstrapping-labels: seed code.queueBatches.defaultModel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 2 — Template + skill

### Task 3: Create the worker agent prompt template

**Files:**
- Create: `lightspeed/skills/queue-batches/templates/agent-prompt.md`

The orchestrator renders this per zone, filling placeholders, then launches it as a background
`Agent`. Adapt the structure of Aaron's private `agent-prompt.md` template
but replace its curl calls, install/test setup, and zone-branch model with the lightspeed
dispatcher + native per-issue worktree lifecycle below.

- [ ] **Step 1: Write the template file**

Create `lightspeed/skills/queue-batches/templates/agent-prompt.md` with exactly this content:

````markdown
# Batch agent prompt (template)

Placeholders the orchestrator fills before dispatch:
- `{zone}` — batch/zone name, e.g. `auth`
- `{model}` — worker model, for traceability
- `{dispatcher}` — absolute path to the lightspeed dispatcher script
- `{base_branch}` — name of `stages[0]` (feature branches fork from it)
- `{repo_root}` — absolute path to the MAIN repo checkout
- `{log_path}` — absolute path to this zone's status log
- `{scratch}` — a writable scratch dir for `--body-file` temp files
- `{issues_ordered}` — newline-separated `#N <slug>` list, execution order (smallest-first)
- `{repo_rules}` — verbatim contents of the repo's agent-rules file, or `None configured.`
- `{pre_made_decisions}` — bullet list of orchestrator decisions so the agent doesn't stall

---

# Prompt body

I'm dispatching you as a background sub-agent to work a queue of issues for zone **{zone}**
(model **{model}**), each in its own isolated worktree. **No pushes. No promotions.** All backend
access goes through the lightspeed dispatcher at `{dispatcher}` — never curl, never MCP.

## Setup (once, before the first issue)

```bash
cd {repo_root}
mkdir -p "$(dirname {log_path})"; touch {log_path}
# Confirm the dispatcher resolves config from here:
{dispatcher} config '.code.stages[0].name'   # should print {base_branch}
```

Record the baseline test status for {base_branch} (run the repo's test command if one exists).
You'll report deltas at the end.

## Issues (work in this order, one at a time)

```
{issues_ordered}
```

Fetch each issue's full body as you reach it:

```bash
{dispatcher} issues get --number <N>
```

## Pre-made decisions (from orchestrator)

{pre_made_decisions}

If you hit a decision not covered here, use the **safety valve** — don't guess.

## Per-issue lifecycle (native working-an-issue, ×M)

For each issue `#N` with slug `<slug>`:

1. **Create the worktree off `stages[0]`** (run from `{repo_root}`):
   ```bash
   git -C {repo_root} worktree add -b "feature/<N>-<slug>" \
     "{repo_root}/.worktrees/<N>-<slug>" "{base_branch}"
   {dispatcher} issues set-status --number <N> --status in-progress
   echo "$(date -u +%FT%TZ) {zone} ticket=#<N> status=starting" >> {log_path}
   ```
2. **Work inside `{repo_root}/.worktrees/<N>-<slug>`.** Re-read the issue's Acceptance section;
   treat each bullet as a separate must-pass condition. Tests must pass after every commit; one
   commit per issue (small logical subcommits OK). Midway, optionally:
   ```bash
   echo "$(date -u +%FT%TZ) {zone} ticket=#<N> status=working note=\"<short>\"" >> {log_path}
   ```
3. **Before declaring done — walk the user-visible surface.** Don't satisfy only the literal
   acceptance phrase; trace every related field/element a reporter would see. If the real scope
   is materially larger than the issue's framing, safety-valve instead of shipping a narrow read.
4. **Hand to the merge gate (do NOT promote):**
   ```bash
   {dispatcher} issues set-status --number <N> --status to-test
   # Finishing record -> a temp file, then comment via --body-file:
   #   summary of work + token/model note (see working-an-issue for the record format)
   {dispatcher} issues comment --number <N> --body-file "{scratch}/done-<N>.md"
   SHA=$(git -C "{repo_root}/.worktrees/<N>-<slug>" rev-parse --short HEAD)
   echo "$(date -u +%FT%TZ) {zone} ticket=#<N> status=complete commit=$SHA" >> {log_path}
   ```
   Leave the worktree in place (unmerged) and move to the next issue. The user promotes serially
   later via `promoting-a-branch`.

## Safety valve (use it liberally)

Append `status=blocked` with a concrete question whenever you stall >15 min, hit an uncovered
judgment call, can't quickly fix breaking tests, or find the scope materially larger than
described:

```bash
echo "$(date -u +%FT%TZ) {zone} ticket=#<N> status=blocked note=\"<short question>\"" >> {log_path}
```

Then stop and return. The orchestrator routes your question to the user and continues you with the
answer. Shipping 3 solid issues beats forcing 5 shaky ones.

## Universal hard rules (always)

- **No `git push`.** Branches stay local for user review.
- **No promotion / no merge to any stage.** Stop each issue at `to-test`.
- **Dispatcher only** for backend access (`{dispatcher} issues …`) — never curl or MCP.
- **Tests green after every commit.**
- **Safety-valve on uncertainty** rather than guessing.

## Repo-specific rules

{repo_rules}

## Final report (when the queue is complete OR you safety-valve)

Return a concise report: commits (`<SHA> #<N> <title>`), test deltas, judgment calls made without
asking, anything deferred/safety-valved (with a suggested follow-up). Then the final log line:

```bash
echo "$(date -u +%FT%TZ) {zone} ticket=all status=<done|safety-valved> note=\"<summary>\"" >> {log_path}
```
````

- [ ] **Step 2: Audit the template's bash for shell correctness**

Extract every fenced ```bash block and shellcheck them with placeholders stubbed (placeholders
aren't valid shell tokens, so substitute dummy values first):

```bash
python3 - <<'PY' > "$SCRATCH/agent-prompt.bash"
import re,sys
t=open("lightspeed/skills/queue-batches/templates/agent-prompt.md").read()
blocks=re.findall(r"```bash\n(.*?)```", t, re.S)
s="\n".join(blocks)
for ph in ["{zone}","{model}","{dispatcher}","{base_branch}","{repo_root}","{log_path}","{scratch}","{issues_ordered}","{repo_rules}","{pre_made_decisions}","<N>","<slug>","<short>","<short question>","<SHA>","<title>","<done|safety-valved>","<summary>"]:
    s=s.replace(ph,"x")
open("/dev/stdout","w").write("#!/usr/bin/env bash\nset -euo pipefail\n"+s+"\n")
PY
shellcheck -x "$SCRATCH/agent-prompt.bash" || true
```

Run: the block above.
Expected: shellcheck reports no errors (warnings about unused `SHA` are acceptable since the
extracted concatenation drops surrounding context — confirm there are no SC2xxx **errors**).

- [ ] **Step 3: Confirm every dispatcher verb the template calls actually exists**

Run:
```bash
grep -oE '\{dispatcher\} (issues|config) [a-z-]+' lightspeed/skills/queue-batches/templates/agent-prompt.md | sort -u
for v in list get set-status comment; do
  grep -q "  $v)" lightspeed/scripts/adapters/forgejo/issues && echo "issues $v: OK" || echo "issues $v: MISSING"
done
```
Expected: the template uses `issues get`, `issues set-status`, `issues comment`, and `config` —
and the `issues` adapter reports `OK` for `get`, `set-status`, `comment`.

- [ ] **Step 4: Commit**

```bash
git add lightspeed/skills/queue-batches/templates/agent-prompt.md
git commit -m "queue-batches: worker agent prompt template (dispatcher-based, merge-gate hand-off)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4: Create the orchestrator SKILL.md

**Files:**
- Create: `lightspeed/skills/queue-batches/SKILL.md`

Adapt the orchestration prose from Aaron's private `queue-batches` SKILL.md — keep
its phone-legible **Display format**, **Status log format**, **Question routing protocol**, and
**Common mistakes** sections close to verbatim. Replace the porting-notes, file-zones, curl
triage, dispatch, and completion sections with the lightspeed versions specified across the steps
below.

- [ ] **Step 1: Write frontmatter + intro + arguments**

Create `lightspeed/skills/queue-batches/SKILL.md` starting with:

```markdown
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
```

- [ ] **Step 2: Write the preflight guard section**

Append:

```markdown
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
```

- [ ] **Step 3: Write the triage + select section**

Append:

```markdown
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
```

- [ ] **Step 4: Write the dispatch section**

Append:

```markdown
## 3. Dispatch

Resolve once:
```bash
DISP="$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"
# MAIN repo root (parent of the common git dir) — worktree-safe, matches the dispatcher:
ROOT="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"
BASE="$("$DISP" config '.code.stages[0].name')"
MODEL="$("$DISP" config '.code.queueBatches.defaultModel // "sonnet"')"   # unless user overrode
RULES_FILE="$("$DISP" config '.code.queueBatches.agentRulesFile // ".lightspeed-agent-rules.md"')"
REPO_RULES="$( [ -f "$ROOT/$RULES_FILE" ] && cat "$ROOT/$RULES_FILE" || echo 'None configured.' )"
mkdir -p "$SCRATCH/queue-status"
```

If `REPO_RULES` is `None configured.`, note it in the plan output so the user knows workers run
with universal rails only.

Per zone:
- Create + pre-seed the log so the board renders every issue as `○` before agents start:
  ```bash
  LOG="$SCRATCH/queue-status/<zone>.log"; : > "$LOG"
  for N in <issues smallest-first>; do
    echo "$(date -u +%FT%TZ) <zone> ticket=#$N status=queued" >> "$LOG"
  done
  ```
- Render `templates/agent-prompt.md`, filling `{zone} {model} {dispatcher}=$DISP
  {base_branch}=$BASE {repo_root}=$ROOT {log_path}=$LOG {scratch}=$SCRATCH {issues_ordered}
  {repo_rules}=$REPO_RULES {pre_made_decisions}`.
- Launch with the `Agent` tool: `run_in_background: true`, `model: <MODEL or override>`.
- `TaskCreate` one task per issue — subject `[<zone>] #<N> — <title>`, description
  `<zone> · <labels>` — plus one per-zone ship task `Ship <zone> (serial promote + cleanup)`.
- Launch `tail -f "$LOG"` with `run_in_background: true` and attach `Monitor` so each new log line
  becomes a notification.
```

- [ ] **Step 5: Write the monitor/render + status-contract + display + question-routing sections**

Append (keep the Display/Status-log/Question-routing wording close to the source skill):

```markdown
## 4. Monitor + render

On every `Monitor` notification: parse the log line, re-render the board, and `TaskUpdate` the
matching issue task (`starting`/`working` → in_progress; `complete` → completed; `blocked`/`failed`
→ keep in_progress + append the note). Match tasks by the `[<zone>] #<N>` subject prefix.

## Status log format (contract)

Agents append one line per state change to `$SCRATCH/queue-status/<zone>.log`:

```
<ISO-timestamp> <zone> ticket=<#N> status=<starting|working|complete|blocked|failed> [commit=<sha7>] [note="…"]
```
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

Legend: `✓` complete · `◐` working · `?` blocked · `○` queued · `✗` failed. One line per issue.

## Question routing protocol

When an agent writes `status=blocked`: parse `note="…"`, render the board, then below it:

> **[<zone>] #<N> needs input:** <question>

Wait for the user's answer, then `SendMessage` to the blocked agent's id with body
`User says: <answer>. Continue.` Treat the agent as `working` until its next log line.
```

- [ ] **Step 6: Write the completion + common-mistakes sections**

Append:

```markdown
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
```

- [ ] **Step 7: Audit the SKILL.md bash for shell correctness**

```bash
python3 - <<'PY' > "$SCRATCH/qb-skill.bash"
import re
t=open("lightspeed/skills/queue-batches/SKILL.md").read()
print("#!/usr/bin/env bash\nset -euo pipefail")
for b in re.findall(r"```bash\n(.*?)```", t, re.S):
    for ph in ["<zone>","<N>","<issues smallest-first>","<MODEL or override>","<question>","<answer>","<slug>","<title>"]:
        b=b.replace(ph,"x")
    print(b)
PY
shellcheck -x "$SCRATCH/qb-skill.bash" || true
```

Run: the block above.
Expected: no SC2xxx **errors** (warnings from cross-block variable use are acceptable).

- [ ] **Step 8: Cross-check template placeholders match what the skill fills**

Run:
```bash
grep -oE '\{[a-z_]+\}' lightspeed/skills/queue-batches/templates/agent-prompt.md | sort -u > "$SCRATCH/ph-template.txt"
grep -oE '\{[a-z_]+\}=|\{[a-z_]+\}' lightspeed/skills/queue-batches/SKILL.md | tr -d '=' | sort -u > "$SCRATCH/ph-skill.txt"
echo "in template but not mentioned by skill dispatch step:"; comm -23 "$SCRATCH/ph-template.txt" "$SCRATCH/ph-skill.txt"
```
Expected: empty output — every `{placeholder}` the template declares is named in the skill's
dispatch step (Task 4 Step 4).

- [ ] **Step 9: Commit**

```bash
git add lightspeed/skills/queue-batches/SKILL.md
git commit -m "queue-batches: orchestrator skill (zone-gated dispatch, merge-gate hand-off)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 5: Live rig walkthrough of the dispatcher verbs the skill drives

Proves the verbs the orchestrator + workers call behave as the skill assumes, against the
disposable Forgejo. No code; this is a recorded verification.

**Files:**
- (none — verification only; uses `test-rig/forgejo`)

- [ ] **Step 1: Bring the rig up**

Run: `cd test-rig/forgejo && ./up.sh && ./smoke.sh; cd -`
Expected: rig reports healthy; smoke passes (a `.lightspeed.json` + seeded issues/labels exist for the rig repo).

- [ ] **Step 2: Walk the orchestrator's read path**

From the rig repo checkout, run:
```bash
DISP="$PWD/lightspeed/scripts/lightspeed"   # adjust to the rig repo's dispatcher path if separate
"$DISP" issues list --state open --limit 50
"$DISP" config '.code.stages[0].name'
"$DISP" config '.code.queueBatches.defaultModel // "sonnet"'
"$DISP" config '.code.zones // "none"'
```
Expected: a TSV issue list; the first stage name; `sonnet` (or the seeded value); `none` (rig has
no zones) — confirming the inference-fallback branch triggers.

- [ ] **Step 3: Walk one worker lifecycle by hand on a throwaway issue**

Pick an open rig issue `#K`, then:
```bash
BASE="$("$DISP" config '.code.stages[0].name')"
git worktree add -b "feature/$K-smoke" ".worktrees/$K-smoke" "$BASE"
"$DISP" issues set-status --number "$K" --status in-progress
"$DISP" issues set-status --number "$K" --status to-test
printf 'queue-batches rig smoke.' > "$SCRATCH/done-$K.md"
"$DISP" issues comment --number "$K" --body-file "$SCRATCH/done-$K.md"
```
Expected: each call exits 0; the rig issue shows status flipping in-progress → to-test and a
comment posted — i.e. the worker template's lifecycle works end to end.

- [ ] **Step 4: Tear down + clean the throwaway artifacts**

```bash
git worktree remove --force ".worktrees/$K-smoke"; git branch -D "feature/$K-smoke" || true
"$DISP" issues clear-status --number "$K" || "$DISP" issues set-status --number "$K" --status in-progress
cd test-rig/forgejo && ./down.sh; cd -
```
Expected: worktree + branch gone; rig down. (No commit — verification only. Record the observed
output in the task hand-off notes.)

---

## Phase 3 — Register + document

### Task 6: Register the skill in the README/manifest + GUIDE, and final audit

**Files:**
- Modify: `lightspeed/README.md` (skills list)
- Modify: `lightspeed/GUIDE.md` (mention parallel runs, if it has a skills/workflow section)

- [ ] **Step 1: Find where skills are listed**

Run: `grep -rn 'working-an-issue\|promoting-a-branch\|triaging-issues' lightspeed/README.md lightspeed/GUIDE.md`
Expected: shows the README skills table/list and any GUIDE workflow section that enumerates skills.

- [ ] **Step 2: Add `queue-batches` to the README skills list**

Match the existing format. Add an entry equivalent to:

```markdown
- **queue-batches** — `/queue-batches NxM`: dispatch N background agents, each working M issues
  sequentially through the `working-an-issue` lifecycle in isolated worktrees (a *batch is a
  zone*, kept merge-clean by `code.zones`), stopping at the `to-test` gate. Live status board +
  question routing; hands back for serial `promoting-a-branch`.
```

- [ ] **Step 3: Add a GUIDE mention (only if GUIDE enumerates skills/workflows)**

If `GUIDE.md` has a workflow/skills section, add one short paragraph: when several independent
issues are queued and you want them ground out in parallel, `/queue-batches` runs them as zoned
background agents and hands back branches to ship serially. (If GUIDE has no such section, skip —
do not invent one.)

- [ ] **Step 4: Final placeholder + reference audit across the new skill**

```bash
grep -rnE 'TODO|TBD|FIXME|XXX|\{[a-z_]+\}' lightspeed/skills/queue-batches/SKILL.md \
  && echo "REVIEW: SKILL.md must contain no unfilled {placeholder} or TODO (placeholders belong only in the template)" \
  || echo "SKILL.md clean"
grep -rn 'curl\|/api/v1\|FORGEJO_' lightspeed/skills/queue-batches/ \
  && echo "REVIEW: found raw API access — must go through the dispatcher" \
  || echo "no raw API access — dispatcher only: OK"
```
Expected: `SKILL.md clean` and `no raw API access — dispatcher only: OK`. (The `{placeholder}`
tokens are expected **only** in `templates/agent-prompt.md`, never in `SKILL.md`.)

- [ ] **Step 5: Commit**

```bash
git add lightspeed/README.md lightspeed/GUIDE.md
git commit -m "queue-batches: register skill in README + GUIDE

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done when

- All six tasks committed on `feature/queue-batches`.
- `lightspeed/skills/queue-batches/{SKILL.md,templates/agent-prompt.md}` exist; SKILL.md is
  placeholder-free and dispatcher-only; the template's lifecycle drives `issues
  set-status`/`comment`/`get` + `config`, stops at `to-test`, never pushes/promotes.
- `code.zones` + `code.queueBatches.{defaultModel,agentRulesFile}` documented; `defaultModel`
  seeded by `bootstrapping-labels`; all read paths verified (present + absent→fallback).
- Rig walkthrough (Task 5) observed green and recorded.
- Ready to merge `feature/queue-batches` → `develop` via `finishing-a-development-branch`.
```
