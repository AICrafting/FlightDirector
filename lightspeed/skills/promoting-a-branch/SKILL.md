---
name: promoting-a-branch
description: Use when advancing the current branch to the next stage — "promote this", "promote to qa", "promote develop to main", "open a PR for this branch", "this branch is ready". Moves the current branch one hop up the configured stages pipeline (e.g. feature → develop → qa → main), applying that hop's merge strategy and gate.
---

# Promoting a Branch

Advance the current branch **one stage** up the pipeline. A promotion is the same operation at
every hop — feature → `stages[0]`, `stages[i]` → `stages[i+1]` — parameterized by which hop.

All backend access is through the dispatcher; pipeline lives in `.lightspeed.json` `code.stages`:

    "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.stages'

See [lightspeed-setup.md](../../references/lightspeed-setup.md) and
[adapter-contract.md](../../references/adapter-contract.md).

## Red flags — STOP

- **One hop per invocation.** Promote to the *next* stage only. Multi-stage jumps happen as
  separate, deliberate promotions.
- **Never promote to a trunk stage without the hop's gate satisfied.** A `pre-merge` hop needs
  the user's go-ahead; a `post-merge-qa` hop uses `Ready #N` (not `Closes`) so issues are
  verified after merge.
- **Halt if you can't write a test plan** for a resolved issue on a `pr` hop — an unwritable
  plan usually means the feature isn't reachable. Fix that before opening the PR.

## Step 1: Resolve the hop

```
BRANCH="$(git branch --show-current)"
STAGES="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.stages')"
```

- If `BRANCH` is one of the stage names at index `i`, the target is stage `i+1` (error if it's
  already the last stage).
- Otherwise `BRANCH` is a feature branch → target is `stages[0]`.
- An explicit `--to <stage>` from the user overrides inference (must be the immediate next stage).

Read the target hop's `merge` (`direct`|`pr`) and `gate` (`pre-merge`|`post-merge-qa`, default
`pre-merge`) from that stage entry.

## Step 2: Identify resolved issues

Scan this branch's commits for issue references:

```
git log <target>..HEAD --oneline
```

Record the `#N` that are actually *resolved* by this branch (judgment — a mention isn't a
resolution). These drive the PR's `Ready #N` lines and the test-plan block.

## Step 3: Test plans (pr hops) — HALT if missing

For each resolved `#N`, fetch the issue and draft a user-visible test plan:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues get --number N
```

Write one plan per issue (numbered steps + an `Expected:` line; or `- no user surface — verify
via <cmd>` for pure infra). Present to the user: *use as-is / edit / blocker*. **If any resolved
issue has no plan or escape hatch, STOP — do not open the PR.**

## Step 4: Promote

**`direct` hop:** merge `<branch>` into `<target>` in the checkout that already holds
`<target>` — never `git switch` to the target from inside the feature worktree, because it
is checked out elsewhere and git will refuse.

Decide which case applies, then merge. (`$SCRATCH` is the session scratchpad directory —
write throwaway files there.)

```
# Find the root of the shared git object store (common dir one level up from .git).
MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"

# Run git worktree list --porcelain and look for a line `branch refs/heads/<target>`.
# Present → <target> is checked out (Case 1); absent → not checked out anywhere (Case 2).
git worktree list --porcelain | grep -q "branch refs/heads/<target>"
```

**Case 1 — `<target>` is checked out in a worktree** (the usual case for `feature → stages[0]`,
where the main checkout sits on `develop`): merge in that worktree's path (usually `$MAIN`).

```
# Merge and push without touching your current (feature) worktree.
git -C "$MAIN" merge --no-ff "$BRANCH" && git -C "$MAIN" push
```

**Case 2 — `<target>` is NOT checked out in any worktree** (e.g. promoting to a `main` stage
that no worktree holds): use a throwaway worktree, then remove it. The `-$$` (PID) suffix keeps
the path unique so a crashed prior run can't collide.

```
git worktree add "$SCRATCH/promote-<target>-$$" "<target>"
git -C "$SCRATCH/promote-<target>-$$" merge --no-ff "$BRANCH" && \
    git -C "$SCRATCH/promote-<target>-$$" push
git worktree remove "$SCRATCH/promote-<target>-$$"
```

> **Red flag:** Never run `git switch <target>` from inside the feature worktree — git will
> abort with "fatal: '<target>' is already checked out at …".

**`pr` hop:** open a PR into the target stage and watch CI. Assemble the body in a scratchpad
file (Summary + the `## Test plans` block + `Ready #N` lines), then:

```
PR="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" pr open --head "$BRANCH" --base <target> \
        --title "…" --body-file "$SCRATCH/pr-body.md")"   # → number⇥url
PR_NUM="$(printf '%s' "$PR" | cut -f1)"
```

Then watch CI in the background and surface state via Monitor:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" ci watch --sha "$(git rev-parse HEAD)" \
   --status-file "$SCRATCH/ls-ci-$BRANCH.json"
```

On failure: `ci log --failed "$BRANCH"`, fix, push, re-watch. On success: tell the user
**"CI passed — ready to merge #$PR_NUM."** Merge only on the user's go-ahead (`pre-merge` gate) or
per your `post-merge-qa` policy (`--strategy` may be `merge|squash|rebase` per the project's
convention):

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" pr merge --number "$PR_NUM" --strategy squash
```

## Step 5: Nudge linked issues per the gate

- **`pre-merge`** — the issues were verified before merge; `working-an-issue` handles their
  finishing record/close. Nothing to do here beyond the merge.
- **`post-merge-qa`** — the PR used `Ready #N` (issues stay open). On merge, move each to the
  `qa` status so it's verified in the promoted stage:
  ```
  "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues set-status --number N --status qa
  ```
  (requires a `qa` status role configured in `.lightspeed.json` `labels.status` — see
  `bootstrapping-labels`.)
  When a later promotion carries those issues to the final stage and QA passes, close them
  (`issues close --number N`).

## Common mistakes

- Promoting more than one hop at a time. One stage per invocation.
- Opening a `pr` hop without test plans for the resolved issues (the halt exists for a reason).
- Using `Closes #N` on a `post-merge-qa` hop — that auto-closes before verification. Use
  `Ready #N`.
- Hand-merging in `working-an-issue` instead of letting this skill own the hop.
