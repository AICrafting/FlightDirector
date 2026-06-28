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

The dispatcher resolves coordinates, token, and label names from `.lightspeed.json` — you pass
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
  own worktree under `.worktrees/` — never commit an issue's work straight onto the trunk branch.
- **Each issue gets its own worktree under `.worktrees/` (already gitignored)** — that's what
  enables working several issues in parallel. Never reuse one worktree for two issues.
- **Keep the board honest.** Every lifecycle transition updates the status label, so the issue's
  state always matches reality. `issues set-status` is atomic — it adds the new status and
  removes the others in one call, so the board can never show two states. Don't do the work and
  forget the transition.

## Lifecycle

### 1. Start work

- Determine the issue number `N` and derive a short slug from its title (lowercase, hyphens, no
  special characters) — e.g. issue #42 "Add login page" → slug `add-login-page`.
- Pick `feature` vs `bug` from the issue's type label or content.
- Create a worktree off `stages[0]` (the first integration branch):

```
# stages[0] is the first integration branch; fork the feature worktree from it.
BASE="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.stages[0].name')"
git worktree add ".worktrees/<N>-<slug>" -b "feature/<N>-<slug>" "$BASE"
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

### 4. On approved merge — finish the issue

Only after explicit approval:

1. **Promote the branch** `feature/<N>-<slug>` → `stages[0]` using `promoting-a-branch` (it
   applies the hop's merge strategy and gate). Do not hand-merge here.
2. **Clear the status labels** from the issue:
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues clear-status --number N
   ```
3. **Comment a finishing record.** Write it to a scratchpad file and pass `--body-file`:
   - A summary of the work that was done.
   - **Token cost and model(s).** Preferred source: a `prompt_log.jsonl` in the repo root, if
     one is being maintained (each line has `session_id`, `model`, token counts, `cost_usd`).
     Filter to this work's `session_id`(s), sum `cost_usd`/tokens, and read `model`. If no such
     log exists, fall back to a rough estimate and the model you know you're running. (The log
     is optional and personal — gitignored, not shipped by this plugin.)
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues comment --number N --body-file "$SCRATCH/done.md"
   ```
4. **Add the `model/<primary>` label** for the main model used (e.g. `model/opus`) — the one with
   the most tokens/cost in the log when available, else the model you ran. See the `model/*` set
   in [default-labels.md](../../references/default-labels.md):
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues label-add --number N --label model/opus
   ```
5. **Close the issue:**
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues close --number N
   ```
6. **Remove the issue's worktree** once merged:
   ```
   git worktree remove ".worktrees/<N>-<slug>"
   ```

## Common mistakes

- Merging because tests passed, without the user's explicit go-ahead. The gate is the user, not
  the test result.
- Doing the work but leaving the status at `in-progress` (or never setting it) — the board now
  lies. Transition every time.
- Closing the issue but forgetting the finishing comment (summary / cost / model) — that record
  is the auditable point of the whole workflow.
- **Orphaned worktrees** — if a promotion is abandoned, remove the worktree
  (`git worktree remove --force .worktrees/<N>-<slug>`) rather than leaving it dangling.
- Hand-merging instead of delegating to `promoting-a-branch` — the merge strategy and any gate
  checks live there, not here.
