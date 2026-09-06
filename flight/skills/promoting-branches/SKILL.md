---
name: promoting-branches
description: Use when promoting several first-hop feature branches at once — "promote each zone", "promote the first zone", "promote issues 18, 93, 12", "promote all to-test", "batch promote", "ship the batch". Promotes a selected group of feature branches into stages[0], honoring that hop's merge strategy (direct → N merges; pr → one PR per group). For a single branch use promoting-a-branch.
---

# Promoting Branches (batch)

Before the first command, follow [runtime preflight](../../references/runtime.md).

Promote several **first-hop** feature branches (typically the worktrees a `queue-batches` run left
at `to-test`) in one go, instead of M serial `promoting-a-branch` invocations — without breaking
the one-issue-one-branch invariant. Each issue keeps its own branch; a spoken selection resolves to
**groups**, and each group is promoted honoring `stages[0]`'s merge strategy.

All backend access is through the dispatcher; pipeline + zones live in `.flightdirector/config.json`.
Per-hop mechanics (merge/sign/PR/CI) are owned by `promoting-a-branch` — reuse them, don't
reinvent. Manifest state is managed by the `batch-manifest` command.

## Red flags — STOP

- **First hop only.** This promotes `feature → stages[0]`. Promoting `stages[i] → stages[i+1]` is a
  single-branch operation — use `promoting-a-branch`.
- **Never merge to a trunk stage without the hop's gate satisfied.** The user invoking batch-promote
  is the go-ahead for the whole selection; a `pr` hop still waits for CI before merging each PR.
- **Continue, don't abort.** A conflicting branch/group is skipped and reported — it must not block
  the clean ones.
- **Every git command is `git -C "$MAIN" …` (or `-C` the integration/feature worktree). A bare
  `git` command is a bug, even if you think you're in the right directory.** A batch promote
  walks through M feature worktrees plus the checkout holding `BASE`, and the shell's working
  directory persists across tool calls — a bare `git merge` or `git worktree remove` mid-loop
  acts on whichever directory you last landed in. Bind `$MAIN` once in Step 1 and anchor
  everything after it; paths passed to an anchored command resolve relative to that `-C`
  directory, not to your current one.
- **Never build an integration worktree on an unfetched `BASE`.** Fetch and compare before every
  `worktree add` off `stages[0]` (Step 4). Local ahead of / diverged from `origin/$BASE` → STOP
  and report; never `git pull` to reconcile it.
- **Fetch `BASE` before the first merge and re-check before the push.** A batch promote merges a
  whole group into a *local* `BASE` and pushes once at the end — the workload most likely to race
  a parallel agent or another machine. Behind → fast-forward and say so; **ahead or diverged →
  STOP** the group, do not `git pull`, and report. A stale base means every merge in the group
  was computed against the wrong tree.

## Step 1: Resolve the hop

```bash
DISP=flight
# $MAIN — the main checkout (root of the shared git object store); it usually holds BASE.
# This `git rev-parse` is the single permitted bare git: it bootstraps the path that every
# later command anchors to with -C.
MAIN="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"

BASE="$("$DISP" config '.code.stages[0].name')"
MERGE="$("$DISP" config '.code.stages[0].merge // "direct"')"   # direct | pr
```

`BASE` is the first-hop target; `MERGE` decides direct-merge vs one-PR-per-group.

## Step 2: Find candidate branches

Candidates are local `feature/*` branches whose linked issue is at `to-test`:

```bash
# Resolve the to-test *role* to this repo's label name (as triaging-issues does),
# then keep issues whose labels column carries it:
TT="$("$DISP" config '.labels.status["to-test"] // "to-test"')"
"$DISP" issues list --state open --limit 100   # keep rows whose labels column contains "$TT"
# local feature branches:
git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads/feature
```

Match each `feature/<N>-<slug>` to its issue `<N>`; keep those at `to-test` and whose worktree exists
(`.worktrees/<N>-<slug>`). This is the LIVE set.

## Step 3: Resolve the selection into groups

- **"promote all to-test"** → one group = all candidates.
- **"promote issues A, B, C"** → one group = those candidate branches (stateless; no manifest).
- **"promote each zone" / "the first zone"** → read the manifest:
  ```bash
  LIVE="<space-separated candidate issue numbers>"
  batch-manifest heal --live "$LIVE"   # self-heal + consume before reading
  batch-manifest groups                # zone<TAB>n,n,n per line
  ```
  "each zone" → one group per printed zone; "the first zone" → the first (if several manifests make
  this ambiguous, ask which). A candidate branch mapping to **no** zone or **multiple** zones is
  listed and left out of zone groups — promote it explicitly.

Present the resolved groups (and which branches) and proceed.

## Step 4: Promote each group

Reuse `promoting-a-branch` mechanics per branch/PR. For each group:

**If `MERGE` = direct** — merge every branch in the group into `BASE`, one at a time, in the
checkout that holds `BASE` (usually the main repo root `MAIN`):

```bash
# $MAIN was bound in Step 1 — reuse it; do not re-derive it from $PWD.
# MAIN holds stages[0] in the usual case. If stages[0] is NOT checked out in any
# worktree, use promoting-a-branch Step 4 "Case 2" (a throwaway worktree) instead.

# --- Upstream freshness check (promoting-a-branch Step 4a) — BEFORE the first merge ---
git -C "$MAIN" fetch -q origin "$BASE"
LOCAL="$(git -C "$MAIN" rev-parse "$BASE")"
REMOTE="$(git -C "$MAIN" rev-parse "origin/$BASE")"
MB="$(git -C "$MAIN" merge-base "$BASE" "origin/$BASE")"
#   LOCAL = REMOTE  → up to date, proceed
#   LOCAL = MB      → behind; git -C "$MAIN" merge --ff-only "origin/$BASE", say so, proceed
#   REMOTE = MB     → ahead (unpushed commits on the stage) → STOP, report, do not pull
#   otherwise       → diverged → STOP, report, do not auto-reconcile
# No origin / fetch fails (offline): warn, continue, and mark BASE unverified in the report.

for each branch feature/<N>-<slug> in the group:
    git -C "$MAIN" merge --no-ff "feature/<N>-<slug>" -m "Merge feature/<N>-<slug> into $BASE (#<N>)"
    # if the merge commit signs badly (%G? = B), re-sign: git -C "$MAIN" commit --amend --no-edit -S
    # on conflict: git -C "$MAIN" merge --abort; record SKIPPED(<N>, conflict); continue
# --- Re-check freshness immediately before the push: the group's merges took time, and a
#     sibling promote or another machine may have moved origin/$BASE meanwhile. Same four
#     states as above; behind → the push is a non-fast-forward, so fast-forward is not
#     possible with merges already stacked on top — STOP and report rather than pulling.
git -C "$MAIN" fetch -q origin "$BASE"
[ "$(git -C "$MAIN" rev-parse "origin/$BASE")" = \
  "$(git -C "$MAIN" merge-base "$BASE" "origin/$BASE")" ] || {
    echo "origin/$BASE moved during the batch — STOP and report; do not pull" >&2; }
git -C "$MAIN" push   # once, after the group's merges
```

**If `MERGE` = pr** — one PR per group via an integration branch:

```bash
INT="batch/<zone-or-run>-<short>"
# Build the integration branch on the CURRENT tip of BASE, never a stale local ref.
# Fetch and compare first (same three cases as working-an-issue Step 1):
#   level    → fork from "$BASE"
#   behind   → fork from "origin/$BASE" and say how far behind local was
#   ahead/diverged → STOP; report it, do not pull or reconcile
#   offline / no origin → warn, fork from local "$BASE", mark the base UNVERIFIED in the report
git -C "$MAIN" fetch -q origin "$BASE" || echo "base $BASE UNVERIFIED (fetch failed)" >&2
git -C "$MAIN" worktree add -b "$INT" "$SCRATCH/int-<zone>" "<the ref the check selected>"
for each branch in the group:
    git -C "$SCRATCH/int-<zone>" merge --no-ff "feature/<N>-<slug>" \
      || { git -C "$SCRATCH/int-<zone>" merge --abort; record SKIPPED(<N>, conflict); }
git -C "$SCRATCH/int-<zone>" push -u origin "$INT"
# Assemble the PR body: Summary + a per-issue test plan — read each issue's body AND comments first
# ("$DISP" issues get / issues comments --number <N>; the thread carries scope changes and the work
# ledger, and the plan must test what was actually built) — halt the group if a resolved issue has no
# writable plan; then one $KEYWORD #N line per included issue (Closes if stages[0] closesIssues, else Ready).
PR="$("$DISP" pr open --head "$INT" --base "$BASE" --title "Batch: <zone> (#<n>, #<n>, …)" --body-file "$SCRATCH/pr-<zone>.md")"
# watch CI ("$DISP" ci watch --pr "<pr#>" …); on failure record the group FAILED and move on; on success merge on the gate:
"$DISP" pr merge --number "<pr#>" --strategy "$("$DISP" config '.code.stages[0].strategy // "merge"')"
git -C "$MAIN" worktree remove "$SCRATCH/int-<zone>"
```

## Step 5: Per-issue bookkeeping + lifecycle (per promoted issue)

Identical to `working-an-issue` Step 4 / `promoting-a-branch` Step 5, for each **successfully
promoted** `#N`:

```bash
# 1. Ensure a work-ledger comment exists (queue-batches branches already have one from done-<N>.md;
#    otherwise write a short finishing record and post it):
"$DISP" issues comment --number <N> --body-file "$SCRATCH/done-<N>.md"
# 2. lazily ensure + add the normalized model-family label:
"$DISP" labels ensure --name model/<primary> --color "#d97757" \
  --description "Issue was worked on using <Primary>"
"$DISP" issues label-add --number <N> --label model/<primary>
# 3. Stage-driven status/close (do NOT hard-code):
IS="$("$DISP" config '.code.stages[0].issueStatus // empty')"; [ -n "$IS" ] && "$DISP" issues set-status --number <N> --status "$IS"
LAST=$(( $("$DISP" config '.code.stages | length') - 1 )); CL="$("$DISP" config '.code.stages[0].closesIssues // null')"
[ "$CL" = "null" ] && { [ 0 -eq "$LAST" ] && CL=true || CL=false; }; [ "$CL" = true ] && "$DISP" issues close --number <N>
# 4. remove the worktree (anchored — never bare, you may be standing inside it):
git -C "$MAIN" worktree remove ".worktrees/<N>-<slug>"
```

Then **consume the manifest** for what was promoted:

```bash
LIVE_AFTER="<issue numbers still at to-test>"
batch-manifest heal --live "$LIVE_AFTER"
```

## Step 6: Report

Print a summary: promoted (per group, with SHAs / PR numbers), and skipped/failed with reason
(conflict, CI, no test plan). Skipped issues stay at `to-test`, unmerged, and remain in their
manifest for a re-run.

## Common mistakes

- Treating a `pr` hop like a direct one (or vice-versa) — read `stages[0].merge`.
- Skipping manifest `heal` after promotion — promoted issues would linger. Heal after every group.
- Using `Closes #N` when `stages[0]` does not close issues — use `Ready #N`.
- Aborting the whole run on one conflict. Skip + report; never block the clean branches.
- Reinventing merge/sign/CI logic instead of reusing `promoting-a-branch`.
- Running a bare `git merge` / `git push` / `git worktree remove` inside the per-branch loop.
  You move between worktrees constantly here; anchor every command with `-C "$MAIN"` (or the
  integration worktree's path) so it can never act on the wrong one.
- Creating the integration worktree off a `BASE` nobody fetched — the whole batch is then built
  on stale code and every PR carries the drift.
- Merging a whole group into a `BASE` nobody fetched, then discovering at the single end-of-run
  push that origin moved — now M merge commits sit on a diverged local branch.
- `git pull`-ing to rescue a rejected push. Stop and report; the user reconciles a diverged
  stage branch, not the agent.
