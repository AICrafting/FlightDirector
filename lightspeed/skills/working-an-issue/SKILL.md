---
name: working-an-issue
description: Use when starting, progressing, or finishing work on a specific issue — "let's work on #N", "start issue #N", "I'll take #N", "this is ready to test", "merge #N", "close out #N". Drives the per-issue branch → status-label → test → merge → finish lifecycle. Enforces: never merge to the trunk branch without explicit user approval.
---

# Working an Issue

The per-issue lifecycle: one branch per issue, status labels that mirror reality on the board,
an explicit human gate before merging, and a finishing record (summary, token cost, model) left
on the issue when it's done.

All issue actions go through the **lightspeed dispatcher**; branch/merge are git:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" <group> <verb> [--flag value …]
```

The dispatcher resolves coordinates, token, and label names from `.lightspeed/config.json` — you pass
**status roles** (`in-progress`, `to-test`, …) and it maps them to this repo's actual label
names. Read `stages[0]` (the first integration branch) via:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.stages[0].name'
```

Merge mechanics (strategy, gate) are owned by `promoting-a-branch` — do not read single-value
merge config fields or hand-merge here. Config + verbs:
[lightspeed-setup.md](../../references/lightspeed-setup.md),
[adapter-contract.md](../../references/adapter-contract.md).

## Red flags — STOP

- **Never merge to the trunk branch without explicit user approval.** Not when tests pass, not
  when it "obviously works", not to "save a round-trip." The user tests and says merge. Until
  then, the branch stays unmerged. This is the rule the whole skill exists to protect.
- **One branch, one worktree, per issue.** All work for an issue lives on its own branch in its
  own worktree under `.worktrees/` (already gitignored) — never commit an issue's work straight
  onto the trunk branch. Each issue's own worktree is what enables working several issues in
  parallel; never reuse one worktree for two issues.
- **Keep the board honest.** Every lifecycle transition updates the status label, so the issue's
  state always matches reality. `issues set-status` is atomic — it adds the new status and
  removes the others in one call, so the board can never show two states. Don't do the work and
  forget the transition.

## Lifecycle

### 1. Start work

- **Read the issue *and its comments* first.** The body alone can be stale — clarifications,
  scope corrections, and decisions often live in the comments. Fetch both before you plan:
  ```
  "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues get      --number N
  "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues comments --number N
  ```
  If a comment contradicts the body, the later comment wins — work to that, and say so.
- Determine the issue number `N` and derive a short slug from its title (lowercase, hyphens, no
  special characters) — e.g. issue #42 "Add login page" → slug `add-login-page`.
- Pick `feature` vs `bug` from the issue's type label or content.
- Create a worktree off `stages[0]` (the first integration branch):

```
# stages[0] is the first integration branch; fork the feature worktree from it.
# Run this from the repo root.
BASE="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.stages[0].name')"
git worktree add -b "feature/<N>-<slug>" ".worktrees/<N>-<slug>" "$BASE"
# Do the work inside .worktrees/<N>-<slug>.
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues set-status --number N --status in-progress
```

Do the work inside the `.worktrees/<N>-<slug>` directory.

### 2. Ready for testing

When the work is done and waiting on the user to verify, hand the board over and tell the user
it's ready to test, on which branch:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues set-status --number N --status to-test
```

(One call — it drops `in-progress` and adds `to-test` atomically.)

### 3. The merge gate — wait for confirmation

**Do not merge until the user has tested and explicitly says to merge.** Leave the issue at
`to-test` and stop. If unsure whether you have approval, you don't — ask.

### 4. On approved merge — record the work and promote

Only after explicit approval:

1. **Comment a work-ledger entry.** Each completed chunk of work leaves its *own* record — the
   issue's comment thread is a running ledger (initial code, later follow-up code, and QA each
   append their own entry). Write it to a scratchpad file and pass `--body-file`:
   - A summary of the work done in **this** episode.
   - **Token cost, token counts, and model(s).** Preferred source: a `prompt_log.jsonl` in the
     repo root, if maintained (each line has `session_id`, `model`, token counts, `cost_usd`).
     Filter to this work's `session_id`(s), sum `cost_usd`/tokens, read `model`. If no such log
     exists, fall back to a rough estimate and the model you know you're running. (The log is
     optional and personal — gitignored, not shipped by this plugin.)
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues comment --number N --body-file "$SCRATCH/done.md"
   ```
2. **Add the `model/<primary>` label** for the main model used (e.g. `model/opus`) — the one with
   the most tokens/cost in the log when available, else the model you ran. Idempotent; later
   episodes may add another `model/*`. See `model/*` in
   [default-labels.md](../../references/default-labels.md):
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues label-add --number N --label model/opus
   ```
3. **Promote the branch** `feature/<N>-<slug>` → `stages[0]` using `promoting-a-branch` (invoke
   the skill in this session). It applies the hop's merge strategy/gate **and** drives the
   issue's status/close from `stages[0]`'s `issueStatus`/`closesIssues` (Step 5 of that skill):
   a single-trunk repo's terminal `stages[0]` closes the issue; in a multi-stage pipeline it just
   sets the stage's status and the issue stays open until a closing stage. **Do not** set status
   or close the issue here — that is stage-driven now, and double-handling it makes the board lie.
4. **Remove the issue's worktree** once merged (run from the repo root, not inside the worktree):
   ```
   git worktree remove ".worktrees/<N>-<slug>"
   ```

## Common mistakes

- Merging because tests passed, without the user's explicit go-ahead. The gate is the user, not
  the test result.
- Doing the work but leaving the status at `in-progress` (or never setting it) — the board now
  lies. Transition every time.
- Promoting without leaving the work-ledger comment (summary / cost / tokens / model) — that
  per-episode record is the auditable point of the whole workflow; the merge is not the record.
- Manually closing or relabeling the issue on merge — `working-an-issue` no longer closes.
  Status and close are driven by the target stage in `promoting-a-branch` (Step 5). Setting them
  here too makes the board show a state the pipeline didn't ask for.
- **Orphaned worktrees** — if a promotion is abandoned, remove the worktree
  (`git worktree remove --force ".worktrees/<N>-<slug>"`) rather than leaving it dangling. If you
  abandon the work earlier (before promotion), also clear the issue's status label
  (`issues clear-status --number N`) after removing the worktree so the board doesn't lie.
- Hand-merging instead of delegating to `promoting-a-branch` — the merge strategy and any gate
  checks live there, not here.
