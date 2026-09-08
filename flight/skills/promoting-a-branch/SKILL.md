---
name: promoting-a-branch
description: Use when advancing the current branch to the next stage — "promote this", "promote to qa", "promote develop to main", "open a PR for this branch", "this branch is ready". Moves the current branch one hop up the configured stages pipeline (e.g. feature → develop → qa → main), applying that hop's merge strategy and gate.
---

# Promoting a Branch

Before the first command, follow [runtime preflight](../../references/runtime.md).

Advance the current branch **one stage** up the pipeline. A promotion is the same operation at
every hop — feature → `stages[0]`, `stages[i]` → `stages[i+1]` — parameterized by which hop.

All backend access is through the dispatcher; pipeline lives in `.flightdirector/config.json` `code.stages`:

    flight config '.code.stages'

See [flight-setup.md](../../references/flight-setup.md) and
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
- **Every git command is `git -C "$WT" …` / `git -C "$MAIN" …`. A bare `git` command is a bug,
  even if you think you're in the right directory.** A promotion juggles *two* checkouts — the
  feature worktree (`$WT`) and the one holding the target stage (`$MAIN`, or a throwaway) — and
  the shell's working directory persists across tool calls. An unanchored `git merge` or
  `git push` at this step lands on the wrong repo or the wrong branch, which is exactly the
  failure a promotion must never have. Bind both paths in Step 1 and anchor everything after.
  Paths passed to an anchored command resolve relative to that `-C` directory, not to your
  current one — always pass repo-relative paths.
- **Never merge into a target branch you haven't just fetched.** A promotion merges into a
  *local* copy of `<target>` and then pushes; if `origin/<target>` has moved (another agent,
  another machine, a batch promote, a hotfix) the merge is computed against a stale base and the
  push either fails or gets "fixed" by a reflex nobody reviewed. Run the Step 4 freshness check
  first, on **every** hop — `direct` and `pr` alike.
- **Never `git pull` a diverged stage branch.** If `<target>` is ahead of or diverged from
  `origin/<target>`, **STOP and tell the user**. Reconciling a diverged integration branch is a
  decision the user makes, not a merge or rebase the agent invents. Behind is the only case you
  may fix yourself, and only by fast-forward.

## Step 1: Resolve the hop

Bind the two checkout paths **once**, then anchor every later git command to one of them. The
`git rev-parse --git-common-dir` below is the single permitted bare `git` — it is the bootstrap
that discovers the paths; everything after it uses `-C`.

```
# $WT — the worktree holding the branch being promoted (where you are working).
WT="$(cd "$(git rev-parse --show-toplevel)" && pwd)"
# $MAIN — the main checkout (root of the shared git object store), which usually holds <target>.
MAIN="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"

BRANCH="$(git -C "$WT" branch --show-current)"
STAGES="$(flight config '.code.stages')"
```

- If `BRANCH` is one of the stage names at index `i`, the target is stage `i+1` (error if it's
  already the last stage).
- Otherwise `BRANCH` is a feature branch → target is `stages[0]`.
- An explicit `--to <stage>` from the user overrides inference (must be the immediate next stage).

Read the target hop's `merge` (`direct`|`pr`), `gate` (`pre-merge`|`post-merge-qa`, default
`pre-merge`) and `strategy` (`merge`|`squash`|`rebase`, **default `merge`**) from that stage
entry — never hard-code the strategy:

```
STRATEGY="$(flight config '.code.stages[<i>].strategy // "merge"')"   # <i> = target stage index
```

`strategy` applies to `pr` hops (Step 4); a `direct` hop always merges with `--no-ff`.

## Step 2: Identify resolved issues

Scan this branch's commits for issue references:

```
git -C "$WT" log <target>..HEAD --oneline
```

Record the `#N` that are actually *resolved* by this branch (judgment — a mention isn't a
resolution). These drive the PR's `$KEYWORD #N` lines (see Step 4) and the test-plan block.

## Step 3: Test plans (pr hops) — HALT if missing

For each resolved `#N`, fetch the issue **and its comments** and draft a user-visible test plan.
Scope corrections and acceptance changes live in the thread, and the work-ledger comments say
what was actually built — the plan must test *that*, not the original body:

```
flight issues get      --number N
flight issues comments --number N
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
# $MAIN and $WT were bound in Step 1 — reuse them; do not re-derive from $PWD.
# Run git worktree list --porcelain and look for a line `branch refs/heads/<target>`.
# Present → <target> is checked out (Case 1); absent → not checked out anywhere (Case 2).
git -C "$MAIN" worktree list --porcelain | grep -q "branch refs/heads/<target>"
```

#### Step 4a: Upstream freshness check — before any merge or push

Required on **both** hop types and **both** cases below. The merge must be computed against the
tip that is actually on the remote, not whatever the local ref happens to point at:

```
git -C "$MAIN" fetch -q origin "<target>" "$BRANCH"
LOCAL="$(git -C "$MAIN" rev-parse "<target>")"
REMOTE="$(git -C "$MAIN" rev-parse "origin/<target>")"
MB="$(git -C "$MAIN" merge-base "<target>" "origin/<target>")"
```

| State | Test | Action |
|---|---|---|
| **Up to date** | `LOCAL` = `REMOTE` | Proceed. |
| **Behind** | `LOCAL` = `MB` | Fast-forward and **say so**: `git -C "$MAIN" merge --ff-only "origin/<target>"` (in the checkout holding `<target>`; it must be clean). Then proceed. |
| **Ahead** | `REMOTE` = `MB` | **STOP.** Unpushed local commits on the target stage — something happened outside the workflow. Report and let the user decide. |
| **Diverged** | neither | **STOP.** Do **not** auto-reconcile, and do **not** `git pull`. Report both tips and stop. |

The same fetch also re-affirms the **source** branch on a `direct` hop (the `pr` hop's own
source guard is below): if `$BRANCH` differs from `origin/$BRANCH` in a way you did not expect,
say so before merging.

If there is no `origin`, or the fetch fails (offline), **warn and continue** from the local refs
— but state plainly that the target was **unverified**, and remember the push will be the first
thing to discover any drift.

**Case 1 — `<target>` is checked out in a worktree** (the usual case for `feature → stages[0]`,
where the main checkout sits on `develop`): merge in that worktree's path (usually `$MAIN`).

```
# Merge and push without touching your current (feature) worktree.
git -C "$MAIN" merge --no-ff "$BRANCH" && git -C "$MAIN" push
```

**Case 2 — `<target>` is NOT checked out in any worktree** (e.g. promoting to a `main` stage
that no worktree holds): use a throwaway worktree, then remove it. The `-$$` (PID) suffix keeps
the path unique so a crashed prior run can't collide.

Fork the throwaway worktree from **`origin/<target>`**, not from the local ref, so a stale local
`<target>` cannot be the merge base at all — then push explicitly to `<target>`:

```
git -C "$MAIN" fetch -q origin "<target>"
git -C "$MAIN" worktree add --detach "$SCRATCH/promote-<target>-$$" "origin/<target>"
git -C "$SCRATCH/promote-<target>-$$" merge --no-ff "$BRANCH" && \
    git -C "$SCRATCH/promote-<target>-$$" push origin "HEAD:<target>"
git -C "$MAIN" worktree remove "$SCRATCH/promote-<target>-$$"
# Bring the (unchecked-out) local ref back in line with what you just pushed:
git -C "$MAIN" fetch -q origin "<target>:<target>"
```

Run Step 4a first even here: if the local `<target>` ref is **ahead of** `origin/<target>`,
forking from the remote would silently drop those commits — STOP and report instead.

> **Red flag:** Never run `git switch <target>` from inside the feature worktree — git will
> abort with "fatal: '<target>' is already checked out at …".

**`pr` hop:** open a PR into the target stage and watch CI. Assemble the body in a scratchpad
file (Summary + the `## Test plans` block + `$KEYWORD #N` lines — `Closes` when the target stage closes issues, else `Ready`), then:

Resolve whether the **target stage** closes issues (drives the PR keyword *and* Step 5). `<i>` is
the target stage's index:

```
LAST_IDX=$(( $(flight config '.code.stages | length') - 1 ))
CLOSES="$(flight config ".code.stages[<i>].closesIssues // null")"
if [ "$CLOSES" = "null" ]; then [ "<i>" -eq "$LAST_IDX" ] && CLOSES=true || CLOSES=false; fi
ISSUE_STATUS="$(flight config ".code.stages[<i>].issueStatus // empty")"
# PR issue keyword: Closes only if the target stage closes issues, else Ready (keeps issue open).
KEYWORD=Ready; [ "$CLOSES" = true ] && KEYWORD=Closes
```

The PR is built from the **pushed** branch tip, not your local working copy. Before opening it,
verify local `$BRANCH` isn't ahead of the remote — otherwise the PR (and the CI you'd watch)
silently omits your latest commit:

```
git -C "$WT" fetch -q origin "$BRANCH"
if [ "$(git -C "$WT" rev-parse HEAD)" != "$(git -C "$WT" rev-parse "origin/$BRANCH")" ]; then
   # STOP — local is ahead of / diverged from origin/$BRANCH. Push (or reconcile)
   # before promoting, then re-run. Do not open the PR against a stale remote tip.
   echo "local $BRANCH differs from origin/$BRANCH — push first" >&2
fi
```

```
PR="$(flight pr open --head "$BRANCH" --base <target> \
        --title "…" --body-file "$SCRATCH/pr-body.md")"   # → number⇥url
PR_NUM="$(printf '%s' "$PR" | cut -f1)"
```

A typo or a late test-plan edit does **not** need the web UI: correct an already-open PR with
`flight pr update --number "$PR_NUM" --title "…" --body-file "$SCRATCH/pr-body.md"` (only the
fields you pass are patched), and read back what is on it with `flight pr get --number "$PR_NUM"`.

Then watch CI in the background and surface state via Monitor. Watch by **`--pr`**, not by a local
SHA: the adapter resolves the PR's head commit — the exact SHA the run reports — so a local tip
that was never pushed can't send the watcher chasing a run that doesn't exist. It exits non-zero on
a `--timeout` (default 900s) rather than polling forever:

```
flight ci watch --pr "$PR_NUM" \
   --status-file "$SCRATCH/ls-ci-$BRANCH.json"
```

On failure: `ci log --failed "$BRANCH"`, fix, push, re-watch. On success: tell the user
**"CI passed — ready to merge #$PR_NUM."** Merge only on the user's go-ahead (`pre-merge` gate) or
per your `post-merge-qa` policy. Use the `$STRATEGY` resolved in Step 1 — the stage's configured
strategy, defaulting to `merge`:

```
flight pr merge --number "$PR_NUM" --strategy "$STRATEGY"
```

## Step 5: Drive linked-issue lifecycle from the target stage

After the merge into `<target>` succeeds, the **target stage** decides what happens to each
resolved `#N` — the *same* rule at every hop, `direct` or `pr`. Reuse `CLOSES` / `ISSUE_STATUS`
from the resolution block in Step 4 (for a `direct` hop, which skips that `pr`-only block, compute
them now with the same snippet). For each resolved `#N`:

- `ISSUE_STATUS` non-empty → set the stage's status atomically:
  ```
  flight issues set-status --number N --status "$ISSUE_STATUS"
  ```
- `CLOSES` is `true` → close it; otherwise leave it **open** so a later promotion handles it:
  ```
  flight issues close --number N
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
- Running a bare `git merge` / `git push` / `git switch` here. A promotion always spans two
  checkouts; anchor every command with `-C "$MAIN"` or `-C "$WT"` so it cannot act on whichever
  directory the shell happens to be sitting in.
- Merging into `<target>` without fetching it first — the tree you promote isn't the tree the
  user thinks they promoted, and the push fails (or strands a merge commit on a now-diverged
  branch).
- Reaching for `git pull` when the push is rejected. That invents a merge or a rebase nobody
  reviewed, at exactly the moment the user has said "promote" and stopped watching. Stop and
  report; only *behind* is safe to fix, and only with `--ff-only`.
- Hard-coding `--strategy squash` (or any strategy) instead of reading the target stage's
  `strategy` field. The default is `merge`, and a repo that wants otherwise says so in config.
