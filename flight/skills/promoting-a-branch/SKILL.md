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
  (Step 5). A `pr` hop uses `Closes #N` only when the target stage closes issues, else `Ready #N` —
  and only for an issue that lives in the code repository itself. Another tracker's issue is
  named ``Tracks `GH-12` `` (the id in backticks, so GitHub doesn't autolink it) and driven explicitly in Step 5; a bare `#12` for it would close the code
  repository's *own* issue 12 (Step 4).
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
- **Never skip a configured `code.preflight`, and never "interpret" its exit code.** When the
  repo sets one, it *is* the gate for a `direct` hop — the hop has no CI to fall back on. Run it
  (Step 4b) and halt on non-zero; a red gate is not merged around, not re-run until it is green
  by luck, and not waved through because the failure "looks unrelated". If the user overrides it,
  that is their call and it is said out loud in the promotion report.
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
# Any FILENAME built from a branch name needs the slash flattened first. `feature/fj-12-foo`
# in a redirect target or a --status-file path names a *directory* that does not exist, so
# the write fails and whatever depended on it reports a failure that never happened.
SAFE_BRANCH="$(printf '%s' "$BRANCH" | tr '/' '-')"
STAGES="$(flight config '.code.stages')"
```

- If `BRANCH` is one of the stage names at index `i`, the target is stage `i+1` (error if it's
  already the last stage).
- Otherwise `BRANCH` is a feature branch → target is `stages[0]`.
- An explicit `--to <stage>` from the user overrides inference (must be the immediate next stage).

**These bindings do not survive a fresh shell, so this block is safe to repeat.** If your harness
starts a new shell for each tool call, restate it at the top of each later block; nothing
persists the variables for you. That is only safe because the block binds paths and names and
**never a verdict**. Step 4b's result is deliberately not a variable: it is written to a file
under `$SCRATCH` and every merge and `pr open` site reads it back from there, so there is nothing
to carry across a tool call and nothing a restated block can quietly reset to green.

Read the target hop's `merge` (`direct`|`pr`), `gate` (`pre-merge`|`post-merge-qa`, default
`pre-merge`) and `strategy` (`merge`|`squash`|`rebase`, **default `merge`**) from that stage
entry — never hard-code the strategy:

```
STRATEGY="$(flight config '.code.stages[<i>].strategy // "merge"')"   # <i> = target stage index
```

`strategy` applies to `pr` hops (Step 4); a `direct` hop always merges with `--no-ff`.

## Step 2: Identify resolved issues

Each resolved issue is carried by its **retained identity** — the
`{tracker, number, qualified, display, branchPrefix}` JSON `flight issues resolve` prints — never by a bare
number: the repo may have several issue trackers, two of them can both have an issue 12, and the
default tracker may have changed since the work started. `$ISSUE_IDENTITY` is the helper from
[runtime preflight](../../references/runtime.md).

- **Feature branch** (→ `stages[0]`): the branch names its issue.
  ```
  ISSUE="$("$ISSUE_IDENTITY" from-branch --branch "$BRANCH")"
  ```
  It reads qualified names (`feature/fj-12-…`, `feature/proj-7-…`) and the migration's bindings for
  legacy `feature/12-…` branches. Exit 4 = a legacy branch whose tracker cannot be recovered: ask
  the user which tracker it belongs to and rerun with `--tracker REF` (the answer is retained) —
  never assume the current default. Exit 3 = the branch names no issue; use the commit scan below.
- **Stage branch** (`stages[i]` → `stages[i+1]`), or any further issue a feature branch resolves:
  scan the commits.
  ```
  git -C "$WT" log <target>..HEAD --oneline
  ```
  Record the issues actually *resolved* (judgment — a mention is not a resolution). Commits and
  merges name them by display id — qualified while the repo has several trackers
  (`feat(FJ-12): …`, `Merge branch 'feature/fj-12-…'`), a bare `#12` while it has one (#258) —
  and history from before the repo moved to named trackers names a bare `#12` too. Resolve each one:
  ```
  ISSUE="$("$ISSUE_IDENTITY" from-history --ref "FJ-12")"      # or --ref "#12"
  ```
  A bare `#12` from history belongs to the tracker the repo migrated from — never to whichever is
  the default now. But PR bodies written since the migration still say `Closes #12` for the code
  repo's own tracker, so when that tracker is not the migrated one the helper cannot tell them
  apart and exits 4. Exit 4 always means "ask": ask the user which tracker the reference means and
  rerun with `--tracker REF`. A merged branch name can go through
  `from-branch` instead.

For each identity keep `ISSUE` and
`TRACKER="$(jq -r .tracker <<<"$ISSUE")"`, `NUMBER="$(jq -r .number <<<"$ISSUE")"` (native: `17`,
or `PROJ-17` on Jira), `QUALIFIED="$(jq -r .qualified <<<"$ISSUE")"`. Every later issue and label
call passes `--tracker "$TRACKER" --number "$NUMBER"`.

## Step 3: Test plans and deferrals (pr hops) — HALT if missing

For each resolved identity, fetch the issue **and its comments** and draft a user-visible test plan.
Scope corrections and acceptance changes live in the thread, and the work-ledger comments say
what was actually built — the plan must test *that*, not the original body:

```
flight issues get      --tracker "$TRACKER" --number "$NUMBER"
flight issues comments --tracker "$TRACKER" --number "$NUMBER"
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

Every deferred item needs a **live tracker** — an issue you have verified *open*, or one you
file right then — written by its qualified id (`FJ-31`, `GH-8`) so it names one issue however
many trackers the repo has. `issues get` reports state as field 3, normalized to `open`/`closed`
on every backend (#205), and a qualified id routes to its own tracker:

```
IFS=$'\t' read -r _ _ STATE <<<"$(flight issues get --number "FJ-31")"
[ "$STATE" = open ]              # true → open, deferral is tracked; false → HALT
```

An issue that doesn't exist makes `issues get` exit non-zero and leaves `$STATE` empty, so an
invented id halts on the same test rather than slipping through.

A closed issue is a failure, not a pass. And **an issue this PR resolves does not count as the
tracker** — not even on a `Ready #N` hop where it stays open for now. It closes when the work
reaches a closing stage and takes the note with it, leaving the item recorded only in a merged PR
body nobody has a reason to open again. Being open *today* is not the test; surviving the work is.
**Halt if any deferred item has no live tracker** — file the successor issues, put their qualified ids
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

#### Step 4b: Repo preflight gate — after the freshness check, before the merge

Run the repo's preflight gate now, **on every promotion**, gated or not. It goes **after** Step 4a
deliberately: a diverged target stops the promotion in seconds, and there is no sense spending
minutes on a test run that a STOP was going to discard.

```
# $SAFE_BRANCH, not $BRANCH: Step 1 flattened the slash, so these are plain file names.
flight preflight run --worktree "$WT" \
    --log "$SCRATCH/preflight-$SAFE_BRANCH.log" \
    --verdict "$SCRATCH/preflight-verdict-$SAFE_BRANCH"
```

`preflight run` reads `code.preflight`, runs it in the branch's own worktree, and records a
**verdict file** stamped with the commit it judged: `pass <sha>`, `fail <sha>`, or `none <sha>`
when the repo has no gate (so an ungated repo costs one quick call). It clears the old verdict
before it starts, so an interrupted run leaves none at all. On a failure it prints the log's last
40 lines and the log's path: show them, **stop**, and leave the branch unmerged — the fix belongs
on the feature branch. On a pass it prints one line (*"preflight: passed (`<cmd>`)"*); keep it in
the promotion report so the report records that the gate ran.

Never run the gate yourself as `sh -c "$GATE"`: Claude Code's safety check cannot read inside a
`sh -c` string and may stop to ask, which an unattended promotion cannot answer (FJ-307).

The verdict is a **file**, not a shell variable, on purpose: the merge lives in a *later* fenced
block, which on a fresh-shell harness is a later shell, and a variable is gone by then — or worse,
re-bound to green by restating an earlier block. Nothing sets the file to `pass` except a gate that
passed. Every merge and `pr open` below asks the same question of it:

```
flight preflight check --worktree "$WT" --verdict "$SCRATCH/preflight-verdict-$SAFE_BRANCH"
```

It succeeds only for `pass` or `none` on the branch's **current** commit. Anything else — no
verdict, a failed gate, a verdict for an older commit, a lost `$SCRATCH` — fails and **says
which**, so a refusal is never mistaken for a promotion that quietly did nothing.

**There are three guarded sites, and the `pr` one is the site that matters.** Case 1 and Case 2
below are both `direct`-hop merges; `pr` is the commoner configuration, so a gate honoured only in
the `direct` cases is a gate most repos never actually have. A `direct` hop runs Step 4b before
the merge. A `pr` hop runs it before `pr open` — that hop does not push `$BRANCH` at all, it
requires the branch to be on origin already (see the source guard in the `pr` block, which tells
you to push first rather than pushing for you) — so a red gate never reaches CI or a reviewer. It
does not replace CI on a `pr` hop; it front-runs it.

**Case 1 — `<target>` is checked out in a worktree** (the usual case for `feature → stages[0]`,
where the main checkout sits on `develop`): merge in that worktree's path (usually `$MAIN`).

```
# Merge and push without touching your current (feature) worktree, and only when
# Step 4b's verdict allows this exact commit.
if flight preflight check --worktree "$WT" --verdict "$SCRATCH/preflight-verdict-$SAFE_BRANCH"; then
    git -C "$MAIN" merge --no-ff "$BRANCH" &&
        git -C "$MAIN" push
else
    echo "not merging, not pushing" >&2
fi
```

**Case 2 — `<target>` is NOT checked out in any worktree** (e.g. promoting to a `main` stage
that no worktree holds): use a throwaway worktree, then remove it. The `-$$` (PID) suffix keeps
the path unique so a crashed prior run can't collide.

Fork the throwaway worktree from **`origin/<target>`**, not from the local ref, so a stale local
`<target>` cannot be the merge base at all — then push explicitly to `<target>`:

```
git -C "$MAIN" fetch -q origin "<target>"
git -C "$MAIN" worktree add --detach "$SCRATCH/promote-<target>-$$" "origin/<target>"
if flight preflight check --worktree "$WT" --verdict "$SCRATCH/preflight-verdict-$SAFE_BRANCH"; then
    git -C "$SCRATCH/promote-<target>-$$" merge --no-ff "$BRANCH" &&
        git -C "$SCRATCH/promote-<target>-$$" push origin "HEAD:<target>"
else
    echo "not merging, not pushing" >&2
fi
git -C "$MAIN" worktree remove "$SCRATCH/promote-<target>-$$"
# Bring the (unchecked-out) local ref back in line with what you just pushed:
git -C "$MAIN" fetch -q origin "<target>:<target>"
```

Run Step 4a first even here: if the local `<target>` ref is **ahead of** `origin/<target>`,
forking from the remote would silently drop those commits — STOP and report instead.

> **Red flag:** Never run `git switch <target>` from inside the feature worktree — git will
> abort with "fatal: '<target>' is already checked out at …".

**`pr` hop:** open a PR into the target stage and watch CI. Assemble the body in a scratchpad
file (Summary + the `## Test plans` block + one issue line per resolved issue from `pr-reference`
below). The PR lives on the code forge, which may be public while an issue tracker is private:
**do not paste issue bodies, comments, work-ledger entries or tracker URLs into it** — describe
the change and write the test steps in your own words, and name issues only by the lines
`pr-reference` prints. Run the Step 3 **deferral scan** over that file before it is posted: every
"known gap" / "out of scope" item needs a verified-open issue, and an issue this PR resolves
doesn't count. Then:

Resolve whether the **target stage** closes issues (drives the PR keyword *and* Step 5). `<i>` is
the target stage's index:

```
LAST_IDX=$(( $(flight config '.code.stages | length') - 1 ))
CLOSES="$(flight config ".code.stages[<i>].closesIssues // null")"
if [ "$CLOSES" = "null" ]; then [ "<i>" -eq "$LAST_IDX" ] && CLOSES=true || CLOSES=false; fi
ISSUE_STATUS="$(flight config ".code.stages[<i>].issueStatus // empty")"
# One line per retained identity from Step 2:
"$ISSUE_IDENTITY" pr-reference --identity "$ISSUE" --closes "$CLOSES" >> "$SCRATCH/pr-body.md"
```

The forge acts on `Closes #N` against the PR's **own** repository, so `pr-reference` writes
`Closes #12` (closing stage) or `Ready #12` only when the issue's tracker *is* the code repository —
same backend, same api host, same owner/repo. For any other tracker it writes ``Tracks `GH-12` ``,
which no forge acts on (the backticks stop GitHub autolinking `GH-12` to the code repo's #12): a cross-tracker PR can never close the code repository's unrelated issue
12. Step 5 then updates the issue on its own tracker explicitly, whichever line was written.

The PR is built from the **pushed** branch tip, not your local working copy — so **run the Step
4b preflight gate here**, before `pr open`. A red gate stops the promotion with no PR opened;
there is no point spending a CI queue, or a reviewer, on a failure a local command just named.

Note what this hop does *not* do: it never pushes `$BRANCH`. The only pushes in this skill are
the two `direct`-hop sites above. A `pr` hop requires the branch to be on origin already — the
source guard below says "push first" rather than pushing for you — so on a red gate the branch
stays on origin exactly as it was, and what the gate prevents is the **PR**, not the push.

Before opening the PR, verify local `$BRANCH` isn't ahead of the remote — otherwise the PR (and
the CI you'd watch) silently omits your latest commit. That check and the gate's verdict both
stand in front of `pr open`, in the same block: a check that only prints, in a block of its own,
stops nothing in the next one ([skill-shell-blocks.md](../../references/skill-shell-blocks.md),
rule 2).

```
git -C "$WT" fetch -q origin "$BRANCH"
if [ "$(git -C "$WT" rev-parse HEAD)" != "$(git -C "$WT" rev-parse "origin/$BRANCH")" ]; then
    # Local is ahead of / diverged from origin/$BRANCH: the PR would be opened against a stale
    # remote tip. Push (or reconcile) first, then re-run this block.
    echo "local $BRANCH differs from origin/$BRANCH — push first; not opening the PR" >&2
elif flight preflight check --worktree "$WT" --verdict "$SCRATCH/preflight-verdict-$SAFE_BRANCH"; then
    PR="$(flight pr open --head "$BRANCH" --base <target> \
            --title "…" --body-file "$SCRATCH/pr-body.md" \
            --model <your-model-id>)"                      # → number⇥url; body gets signed
    PR_NUM="$(printf '%s' "$PR" | cut -f1)"
else
    echo "not opening the PR" >&2
fi
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
   --status-file "$SCRATCH/ls-ci-$SAFE_BRANCH.json"   # flattened: a raw $BRANCH has a slash in it
```

Read the verdict off the `status=` field of the last line, **not** off the exit code — `ci watch`
exits 0 on every terminal verdict and non-zero only on a timeout. There are four:

- `status=failure` — `ci log --pr "$PR_NUM"` (every failed run on the PR's head commit — the same
  commit `ci watch --pr` just judged), fix, push, re-watch.
- `status=success` — tell the user **"CI passed — ready to merge #$PR_NUM."** If `skipped=` is
  non-zero, say so as well (**"CI passed, N of M runs skipped"**): part of the suite did not run.
- `status=skipped` — **every** run was skipped, so CI verified *nothing*. This is not a pass and
  not a failure: say **"CI ran nothing for #$PR_NUM (all N runs skipped) — nothing was verified."**
  Don't merge on it, and don't treat it as a red either; it usually means a path filter matched
  nothing or a `needs:` dependency was skipped. The user decides whether that is acceptable here.
- `status=cancelled` — a run was stopped before it finished and none failed, so CI verified
  nothing for that run. It is not a red: `ci log` finds no failed job, so don't go hunting for one.
  The usual cause is a newer push to the branch, and a `--pr` watch says so on stderr
  (*"the head of PR #N moved to … during the watch"*). In that case, watch again: `ci watch --pr
  "$PR_NUM"` resolves the new head. If the head did not move, someone cancelled the run: say
  **"CI for #$PR_NUM was cancelled before it finished — nothing was verified"** and let the user
  decide whether to re-run it. Don't merge on it either way.

On a green verdict, merge only on the user's go-ahead (`pre-merge` gate) or
per your `post-merge-qa` policy. Use the `$STRATEGY` resolved in Step 1 — the stage's configured
strategy, defaulting to `merge`:

```
flight pr merge --number "$PR_NUM" --strategy "$STRATEGY"
```

## Step 5: Drive linked-issue lifecycle from the target stage

After the merge into `<target>` succeeds, the **target stage** decides what happens to each
resolved identity — the *same* rule at every hop, `direct` or `pr`. Reuse `CLOSES` / `ISSUE_STATUS`
from the resolution block in Step 4 (for a `direct` hop, which skips that `pr`-only block, compute
them now with the same snippet). For each identity retained in Step 2 — on **its own** tracker, via
`--tracker "$TRACKER" --number "$NUMBER"`, which maps the status role through that tracker's label
map and closes through that tracker's backend (for Jira, the native key):

- `ISSUE_STATUS` non-empty → set the stage's status atomically:
  ```
  flight issues set-status --tracker "$TRACKER" --number "$NUMBER" --status "$ISSUE_STATUS"
  ```
- `CLOSES` is `true` → close it; otherwise leave it **open** so a later promotion handles it:
  ```
  flight issues close --tracker "$TRACKER" --number "$NUMBER"
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
  commit; one merge commit otherwise), push. The merge happens in the checkout holding the
  lower stage, so the repo's push hooks run where its dependencies are installed. A dirty
  checkout is still used for a fast-forward that doesn't touch its dirty paths. Otherwise
  (the merge would touch a dirty path, or the stage isn't checked out) the merge happens in a
  throwaway worktree and is pushed from there; the row then says the local checkout is behind
  (it fast-forwards at the next freshness check). A refused push says why: origin really moved,
  the server refused it, or the repo's pre-push hook did. The row then quotes the push's last
  lines and gives the path of the full output. A hook that fails only in the throwaway (no
  installed dependencies there) usually just needs the dirty checkout committed or stashed
  before re-running.
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
- Writing `Closes #N` / `Ready #N` by hand for an issue on another tracker. The forge reads it as
  the code repository's issue N and closes an unrelated issue. Use `pr-reference`'s line.
- Re-resolving a bare issue number at promotion time. If the default tracker changed since the
  work started, `12` now means a different issue; the branch (or a qualified commit reference)
  is the identity.
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
- Merging a `direct` hop without running a configured `code.preflight`. On that hop there is no
  CI behind you: the gate you skipped was the only one, and what it would have caught lands on
  the stage instead. (Running it and then merging anyway is the same mistake, louder.)
- Running the preflight *before* the Step 4a freshness check, so a diverged target discards a
  test run you just paid for — or pointing `--worktree` anywhere but `$WT`, which gates the
  wrong tree.
- Skipping Step 4b because the repo has no gate. The guards need its verdict (`none <sha>`) and
  refuse without one — the refusal says so, and the fix is to run Step 4b.
- Running the gate by hand with `sh -c` instead of `flight preflight run`: an unattended session
  can be stopped by the safety prompt, and nothing writes the verdict the guards read.
- Hard-coding `--strategy squash` (or any strategy) instead of reading the target stage's
  `strategy` field. The default is `merge`, and a repo that wants otherwise says so in config.
- Skipping Step 6 after a stage → stage hop, or running it after a feature hop. Only a stage
  source has stages below it to level; forgetting it leaves `develop` one commit behind `qa`
  after every promotion, which is exactly the drift ADR 0002 removes.
- "Fixing" a `stopped` sync-down row by squashing, rebasing, or resetting the lower stage. The
  sync is a true merge or nothing; a conflict there means the stages carry different work and
  the user decides how to reconcile.
