---
name: promoting-a-branch
description: Use when advancing the current branch to the next stage — "promote this", "promote to qa", "promote develop to main", "open a PR for this branch", "this branch is ready". Moves the current branch one hop up the configured stages pipeline (e.g. feature → develop → qa → main), applying that hop's merge strategy and gate.
---

# Promoting a Branch

Before the first command, follow [runtime preflight](../../references/runtime.md).

Advance the current branch **one stage** up the pipeline. A promotion is the same operation at
every hop — feature → `stages[0]`, `stages[i]` → `stages[i+1]` — parameterized by which hop.

All backend access is through the dispatcher; pipeline lives in `.lightspeed/config.json` `code.stages`:

    lightspeed config '.code.stages'

See [lightspeed-setup.md](../../references/lightspeed-setup.md) and
[adapter-contract.md](../../references/adapter-contract.md).

## Red flags — STOP

- **One hop per invocation.** Promote to the *next* stage only. Multi-stage jumps happen as
  separate, deliberate promotions.
- **Never promote to a trunk stage without the hop's gate satisfied.** A `pre-merge` hop needs
  the user's go-ahead; a `post-merge-qa` hop merges then verifies. The gate governs *merging*;
  issue close/relabel is governed separately by the target stage's `closesIssues`/`issueStatus`
  (Step 5). A `pr` hop uses `Closes #N` only when the target stage closes issues, else `Ready #N`.
- **Halt if you can't write a test plan** for a resolved issue on a `pr` hop — an unwritable
  plan usually means the feature isn't reachable. Fix that before opening the PR.

## Step 1: Resolve the hop

```
BRANCH="$(git branch --show-current)"
STAGES="$(lightspeed config '.code.stages')"
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
resolution). These drive the PR's `$KEYWORD #N` lines (see Step 4) and the test-plan block.

## Step 3: Test plans (pr hops) — HALT if missing

For each resolved `#N`, fetch the issue and draft a user-visible test plan:

```
lightspeed issues get --number N
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
git -C "$MAIN" worktree add "$SCRATCH/promote-<target>-$$" "<target>"
git -C "$SCRATCH/promote-<target>-$$" merge --no-ff "$BRANCH" && \
    git -C "$SCRATCH/promote-<target>-$$" push
git -C "$MAIN" worktree remove "$SCRATCH/promote-<target>-$$"
```

> **Red flag:** Never run `git switch <target>` from inside the feature worktree — git will
> abort with "fatal: '<target>' is already checked out at …".

**`pr` hop:** open a PR into the target stage and watch CI. Assemble the body in a scratchpad
file (Summary + the `## Test plans` block + `$KEYWORD #N` lines — `Closes` when the target stage closes issues, else `Ready`), then:

Resolve whether the **target stage** closes issues (drives the PR keyword *and* Step 5). `<i>` is
the target stage's index:

```
LAST_IDX=$(( $(lightspeed config '.code.stages | length') - 1 ))
CLOSES="$(lightspeed config ".code.stages[<i>].closesIssues // null")"
if [ "$CLOSES" = "null" ]; then [ "<i>" -eq "$LAST_IDX" ] && CLOSES=true || CLOSES=false; fi
ISSUE_STATUS="$(lightspeed config ".code.stages[<i>].issueStatus // empty")"
# PR issue keyword: Closes only if the target stage closes issues, else Ready (keeps issue open).
KEYWORD=Ready; [ "$CLOSES" = true ] && KEYWORD=Closes
```

The PR is built from the **pushed** branch tip, not your local working copy. Before opening it,
verify local `$BRANCH` isn't ahead of the remote — otherwise the PR (and the CI you'd watch)
silently omits your latest commit:

```
git fetch -q origin "$BRANCH"
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
   # STOP — local is ahead of / diverged from origin/$BRANCH. Push (or reconcile)
   # before promoting, then re-run. Do not open the PR against a stale remote tip.
   echo "local $BRANCH differs from origin/$BRANCH — push first" >&2
fi
```

```
PR="$(lightspeed pr open --head "$BRANCH" --base <target> \
        --title "…" --body-file "$SCRATCH/pr-body.md")"   # → number⇥url
PR_NUM="$(printf '%s' "$PR" | cut -f1)"
```

Then watch CI in the background and surface state via Monitor. Watch by **`--pr`**, not by a local
SHA: the adapter resolves the PR's head commit — the exact SHA the run reports — so a local tip
that was never pushed can't send the watcher chasing a run that doesn't exist. It exits non-zero on
a `--timeout` (default 900s) rather than polling forever:

```
lightspeed ci watch --pr "$PR_NUM" \
   --status-file "$SCRATCH/ls-ci-$BRANCH.json"
```

On failure: `ci log --failed "$BRANCH"`, fix, push, re-watch. On success: tell the user
**"CI passed — ready to merge #$PR_NUM."** Merge only on the user's go-ahead (`pre-merge` gate) or
per your `post-merge-qa` policy (`--strategy` may be `merge|squash|rebase` per the project's
convention):

```
lightspeed pr merge --number "$PR_NUM" --strategy squash
```

## Step 5: Drive linked-issue lifecycle from the target stage

After the merge into `<target>` succeeds, the **target stage** decides what happens to each
resolved `#N` — the *same* rule at every hop, `direct` or `pr`. Reuse `CLOSES` / `ISSUE_STATUS`
from the resolution block in Step 4 (for a `direct` hop, which skips that `pr`-only block, compute
them now with the same snippet). For each resolved `#N`:

- `ISSUE_STATUS` non-empty → set the stage's status atomically:
  ```
  lightspeed issues set-status --number N --status "$ISSUE_STATUS"
  ```
- `CLOSES` is `true` → close it; otherwise leave it **open** so a later promotion handles it:
  ```
  lightspeed issues close --number N
  ```

This is the whole lifecycle: an issue's status and open/closed state follow its stage position.
The terminal stage (or any stage with `closesIssues: true`) closes; every earlier stage just
relabels and keeps it open. `working-an-issue` no longer closes at the first hop — it leaves a
work-ledger comment and delegates the status/close to this step.

## Common mistakes

- Promoting more than one hop at a time. One stage per invocation.
- Opening a `pr` hop without test plans for the resolved issues (the halt exists for a reason).
- Using `Closes #N` when promoting into a stage that does **not** close issues (a non-terminal
  stage, or one with `closesIssues: false`) — that auto-closes before later verification. Use
  `Ready #N`; `Closes #N` is only for a stage whose effective `closesIssues` is true.
- Hand-merging in `working-an-issue` instead of letting this skill own the hop.
