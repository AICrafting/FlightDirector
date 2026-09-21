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
  plan usually means the feature isn't reachable. Fix that before opening the PR, and don't reach
  for the `no user surface` hatch to get past it: that hatch is for an *inherently* absent
  surface, never an obstructed one (Step 3).
- **Never open a PR whose body defers work with no live tracker.** A "known gaps" or "out of
  scope" note in a merged PR body is not a backlog. Every deferred item names an issue you have
  verified open — never one this PR resolves, whether it closes now or at a later stage (Step 3).
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
- **The sync-down is a true merge — never squash it, never reset a stage.** After a
  stage-to-stage hop, Step 6 merges the target back into the source and cascades down. That
  back-merge fast-forwards when it can and makes one merge commit when it can't; it is never
  squashed (that re-diverges the branches) and a lower stage is never `reset` onto a higher
  tip. A conflict or a red CI on the sync stops the cascade and is reported, not resolved.

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

## Step 3: Test plans and deferrals (pr hops) — HALT if missing

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

### The `no user surface` hatch: absent vs obstructed

The hatch is for an **inherently** absent surface — infra, migration, refactor, type tightening,
log-only changes. There is nothing a user could drive, at any seed or state.

It is **not** for a surface that exists but you could not reach from where you happened to be
standing: "no seeded X", "needs an active session that isn't running", "the fixture only has Y".
That is an **obstructed** surface, and taking the hatch there turns the halt that exists to catch
an unverifiable change into a pass — the gate defeated through its own exemption. When obstructed:

1. Write the real user-visible plan anyway.
2. Drive the precondition as a numbered step inside it (seed the record, start the session).
3. File a successor issue for the durable fixture, so the next agent isn't obstructed the same way.

Both readings of "no user surface" are honest. Only the inherent one is what this hatch is for.

### Deferral scan — before `pr open`

The body drafted in Step 4 is the last place a deliberate omission is written down. Read it back
before you post it and look for deferrals. **The test is semantic, not textual**: anything the body
records as deliberately not done is a deferral, however it happens to be phrased. `## Known gaps`,
`## Out of scope`, "TODO", "future work", "not in scope", "punted", "deferred to", "left as-is",
"left for a separate pass", "follow-up", "not handled here", "deliberately not handled" are
*examples of the shape*, not a list to grep for — `TODO: handle the multi-tenant case` is exactly
what this rule exists to catch, and it matches none of them.

Every deferred item needs a **live tracker** — an `#N` you have verified *open*, or an issue you
file right then. `issues get` reports state as field 3, normalized to `open`/`closed` on every
backend (#205):

```
IFS=$'	' read -r _ _ STATE <<<"$(flight issues get --number "<N>")"
[ "$STATE" = open ]              # true → open, deferral is tracked; false → HALT
```

A number that doesn't exist makes `issues get` exit non-zero and leaves `$STATE` empty, so an
invented `#N` halts on the same test rather than slipping through.

A closed `#N` is a failure, not a pass. And **an issue this PR resolves does not count as the
tracker** — not even on a `Ready #N` hop where it stays open for now. It closes when the work
reaches a closing stage and takes the note with it, leaving the item recorded only in a merged PR
body nobody has a reason to open again. Being open *today* is not the test; surviving the work is.
**Halt if any deferred item has no live tracker** — file the successor issues, put their numbers
in the body, then open the PR.

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
file (Summary + the `## Test plans` block + `$KEYWORD #N` lines — `Closes` when the target
stage closes issues, else `Ready`). Run the Step 3 **deferral scan** over that file before it is
posted: every "known gap" / "out of scope" item needs a verified-open `#N`, and an issue this PR
resolves doesn't count. Then:

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
        --title "…" --body-file "$SCRATCH/pr-body.md" \
        --model <your-model-id>)"                          # → number⇥url; body gets signed
PR_NUM="$(printf '%s' "$PR" | cut -f1)"
```

A typo or a late test-plan edit does **not** need the web UI: correct an already-open PR with
`flight pr update --number "$PR_NUM" --title "…" --body-file "$SCRATCH/pr-body.md" --model <id>`
(only the fields you pass are patched; an existing signature is replaced, not stacked), and read back what is on it with `flight pr get --number "$PR_NUM"`.

Then watch CI in the background and surface state via Monitor. Watch by **`--pr`**, not by a local
SHA: the adapter resolves the PR's head commit — the exact SHA the run reports — so a local tip
that was never pushed can't send the watcher chasing a run that doesn't exist. It exits non-zero on
a `--timeout` (default 900s) rather than polling forever:

```
flight ci watch --pr "$PR_NUM" \
   --status-file "$SCRATCH/ls-ci-$BRANCH.json"
```

Read the verdict off the `status=` field of the last line, **not** off the exit code — `ci watch`
exits 0 on every terminal verdict and non-zero only on a timeout. There are three:

- `status=failure` — `ci log --pr "$PR_NUM"` (every failed run on the PR's head commit — the same
  commit `ci watch --pr` just judged), fix, push, re-watch.
- `status=success` — tell the user **"CI passed — ready to merge #$PR_NUM."** If `skipped=` is
  non-zero, say so as well (**"CI passed, N of M runs skipped"**): part of the suite did not run.
- `status=skipped` — **every** run was skipped, so CI verified *nothing*. This is not a pass and
  not a failure: say **"CI ran nothing for #$PR_NUM (all N runs skipped) — nothing was verified."**
  Don't merge on it, and don't treat it as a red either; it usually means a path filter matched
  nothing or a `needs:` dependency was skipped. The user decides whether that is acceptable here.

On a green verdict, merge only on the user's go-ahead (`pre-merge` gate) or
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

Once the merge has landed, the branch itself is leftovers — **cleaning-up-branches** finds it
(along with any others whose work already shipped) and deletes the local ref, the remote ref, and
the worktree behind a preview and a go-ahead.

This is the whole lifecycle: an issue's status and open/closed state follow its stage position.
The terminal stage (or any stage with `closesIssues: true`) closes; every earlier stage just
relabels and keeps it open. `working-an-issue` no longer closes at the first hop — it leaves a
work-ledger comment and delegates the status/close to this step.

## Step 6: Sync the lower stages back down (stage → stage hops only)

**Only when the branch you promoted is itself a stage** (`stages[i-1] → stages[i]`, `i ≥ 1`).
A feature → `stages[0]` hop never syncs down (the feature branch is leftovers), and neither does
`promoting-branches`. After the merge has landed and Step 5 is done, run one command:

```
flight branches sync-down --from <target>
```

It walks every stage below `<target>` — `stages[i-1]`, then `stages[i-2]`, … `stages[0]` — and
merges the stage above back into it, so `develop ≤ qa ≤ main` holds again by construction
([ADR 0002](../../../docs/adr/0002-sync-down-after-promotion.md)). Each receiving stage's
`syncDown` field (`direct` | `pr` | `none`, **default = that stage's own `merge`**) decides how:

- **`direct`** — fetch, run the Step 4a freshness check on the lower stage, merge the upper
  stage into it (`--ff` when it is a strict ancestor, which is the usual case and adds no
  commit; one merge commit otherwise), push. If the checkout holding the lower stage is dirty,
  the merge happens in a throwaway worktree and is pushed from there; the row then says the
  local checkout is behind (it fast-forwards at the next freshness check).
- **`pr`** — open a PR `<upper> → <lower>` (no `Closes`/`Ready` lines: the promotion already
  drove the issue lifecycle), watch CI, and **auto-merge on green with `--strategy merge`** —
  never the stage's promotion `strategy`. Red CI, a timeout or a refused merge leaves the PR
  open and stops.
- **`none`** — that stage is skipped and the cascade stops there.

The verb prints one row per stage, `stage⇥outcome⇥detail`, where outcome is `fast-forwarded`,
`merged`, `already-level`, `pr-merged`, `skipped`, or `stopped`, and exits non-zero on a
`stopped` row. Relay every row to the user. A `stopped` row is the user's call — an ahead or
diverged lower stage, a conflict (already aborted; nothing changed), or an open sync PR whose CI
is red. Do **not** rerun with a hand-merge, a rebase or a reset; report it and stop, exactly as
you would for a diverged target in Step 4a.

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
- Skipping Step 6 after a stage → stage hop, or running it after a feature hop. Only a stage
  source has stages below it to level; forgetting it leaves `develop` one commit behind `qa`
  after every promotion, which is exactly the drift ADR 0002 removes.
- "Fixing" a `stopped` sync-down row by squashing, rebasing, or resetting the lower stage. The
  sync is a true merge or nothing; a conflict there means the stages carry different work and
  the user decides how to reconcile.
