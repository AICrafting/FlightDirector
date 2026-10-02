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
- **A configured `code.preflight` runs per branch, before that branch's merge — never once on
  `BASE` after the group.** A gate run after M merges have stacked on the stage can only report a
  failure it is too late to act on: backing it out means resetting a stage, which this skill
  never does. Per branch, a red gate is a skip (`SKIPPED(<DISPLAY>, preflight)`) and the clean branches
  still ship.
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
PREFLIGHT="$("$DISP" config '.code.preflight // empty')"        # repo gate; empty = not configured
```

`BASE` is the first-hop target; `MERGE` decides direct-merge vs one-PR-per-group. `PREFLIGHT` is
the repo's own check command ([flight-setup.md](../../references/flight-setup.md) → *Repo
preflight gate*); when it is empty every preflight step below is skipped and the run behaves
exactly as it did before the key existed.

## Step 2: Find candidate branches

Candidates are local `feature/*` branches whose linked issue is at `to-test` **on its own
tracker**. A repo may have several named issue trackers, two of them can both have an issue 12,
and each spells its status labels its own way — so every branch is resolved to its retained
identity first (`$ISSUE_IDENTITY` is the helper from
[runtime preflight](../../references/runtime.md)), and each tracker is asked about its own issues:

```bash
for B in $(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads/feature); do
  ISSUE="$("$ISSUE_IDENTITY" from-branch --branch "$B")"; RC=$?
  # RC 3 → the branch names no issue: not a candidate. RC 4 → a legacy feature/<N>-… branch
  # whose tracker cannot be recovered: list it as UNBOUND and ask the user which tracker it
  # belongs to (rerun from-branch with --tracker REF; the answer is retained). Never assume
  # the current default tracker.
  [ "$RC" = 0 ] || continue
  TRACKER="$(jq -r .tracker <<<"$ISSUE")"; NUMBER="$(jq -r .number <<<"$ISSUE")"
  QUALIFIED="$(jq -r .qualified <<<"$ISSUE")"; PREFIX="$(jq -r .branchPrefix <<<"$ISSUE")"
  DISPLAY="$(jq -r .display <<<"$ISSUE")"   # #12 with one tracker, FJ-12 with several — for messages and reports
  # …keep B, ISSUE and the fields above together for this candidate.
done

# Once per tracker that appears above — its OWN to-test label, from its own label map:
TT="$("$DISP" issues tracker --tracker "$TRACKER" | jq -r '.labels.status["to-test"] // empty')"
# Empty → that tracker has no to-test label to find candidates by: say so, and ask the user to
# name its branches explicitly — never fall back to a guessed "to-test".
# --limit 100 is a ceiling the adapter pages up to; if it warns on stderr that it is showing
# 100 of more, raise it and re-list, or the LIVE set silently loses candidates.
"$DISP" issues list --tracker "$TRACKER" --state open --label "$TT" --limit 100   # native ids, col 1
```

Keep a branch when its native `NUMBER` is in its **own** tracker's to-test rows and its worktree
exists (`.worktrees/<branch name after feature/>` — `.worktrees/fj-12-<slug>`, or
`.worktrees/12-<slug>` for a legacy branch). This is the LIVE set, keyed by `QUALIFIED`, so two
trackers' issue 12 stay two candidates.

## Step 3: Resolve the selection into groups

- **"promote all to-test"** → one group = all candidates.
- **"promote issues A, B, C"** → one group = those candidate branches (stateless; no manifest).
  Match what the user said by qualified id (`FJ-18`, `GH-12`); a bare `18` means the current
  default tracker's issue 18 — when more than one tracker has a candidate numbered 18, ask.
- **"promote each zone" / "the first zone"** → read the manifest:
  ```bash
  LIVE="<space-separated candidate qualified identities>"
  batch-manifest heal --live "$LIVE"   # self-heal + consume before reading
  batch-manifest groups                # zone<TAB>REF-n,REF-n per line
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

for each candidate (branch "$B", identity fields from Step 2) in the group:
    # $B is feature/<prefix>-<slug> (legacy: feature/<N>-<slug>); its worktree is .worktrees/${B#feature/}.
    # Repo gate, per branch, in that branch's own worktree — before its merge, so a failure
    # costs a skip rather than a merge commit nobody can take back off the stage.
    if [ -n "$PREFLIGHT" ]; then
        ( cd "$MAIN/.worktrees/${B#feature/}" && sh -c "$PREFLIGHT" ) \
          >"$SCRATCH/preflight-$QUALIFIED.log" 2>&1 \
          || { tail -40 "$SCRATCH/preflight-$QUALIFIED.log"; record SKIPPED($DISPLAY, preflight); continue; }
    fi
    # The merge message names the issue by its qualified id — never a bare #N, which the forge
    # would read as the code repository's own issue N.
    git -C "$MAIN" merge --no-ff "$B" -m "Merge $B into $BASE ($DISPLAY)"
    # if the merge commit signs badly (%G? = B), re-sign: git -C "$MAIN" commit --amend --no-edit -S
    # on conflict: git -C "$MAIN" merge --abort; record SKIPPED($DISPLAY, conflict); continue
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
for each candidate (branch "$B") in the group:
    git -C "$SCRATCH/int-<zone>" merge --no-ff "$B" \
      || { git -C "$SCRATCH/int-<zone>" merge --abort; record SKIPPED($DISPLAY, conflict); }
# Repo gate on the assembled group, in the integration worktree, before the push: the branches
# are merged here but nothing is on origin yet, so a red gate costs a re-run, not a revert.
# The verdict must GUARD the push — a comment saying "stop" stops nothing, and an unguarded
# push here is the red-reaches-a-reviewer outcome this gate exists to prevent.
if [ -n "$PREFLIGHT" ]; then
    ( cd "$SCRATCH/int-<zone>" && sh -c "$PREFLIGHT" ) >"$SCRATCH/preflight-<zone>.log" 2>&1 \
      || { tail -40 "$SCRATCH/preflight-<zone>.log"; record FAILED(<zone>, preflight)
           # Take the branch as well as the worktree. $INT was never pushed, so there is no
           # PR for cleaning-up-branches to collect it behind — a bare `worktree remove`
           # strands a local batch/* ref forever. It also frees the name: if <short> derives
           # from the zone rather than the run, the re-promote after the group is fixed would
           # otherwise hit `worktree add -b "$INT"` with "branch already exists" and halt.
           git -C "$MAIN" worktree remove --force "$SCRATCH/int-<zone>"
           git -C "$MAIN" branch -D "$INT"
           continue; }   # next GROUP: no push, no PR. Red gate = skipped, same as a conflict.
fi
git -C "$SCRATCH/int-<zone>" push -u origin "$INT"
# Decide stage closure before assembling the PR body; this value also drives
# the explicit tracker lifecycle updates in Step 5.
LAST=$(( $("$DISP" config '.code.stages | length') - 1 ))
CL="$("$DISP" config '.code.stages[0].closesIssues // null')"
[ "$CL" = "null" ] && { [ 0 -eq "$LAST" ] && CL=true || CL=false; }
# Assemble the PR body: Summary + a per-issue test plan — read each retained issue's
# body AND comments (issues get / issues comments --tracker "$TRACKER" --number "$NUMBER")
# first: the thread carries scope changes and the work ledger. Halt the group if a resolved
# issue has no writable plan. The code PR may be public while a tracker is private: write the
# summary and test steps in your own words and never paste issue bodies, comments, ledger
# entries or tracker URLs into it. Name each issue ONLY with its pr-reference line:
"$ISSUE_IDENTITY" pr-reference --identity "$ISSUE" --closes "$CL" >> "$SCRATCH/pr-<zone>.md"
#   → `Closes #12` / `Ready #12` only when the issue lives in the code repository itself (same
#     backend, api host, owner/repo); `Tracks GH-12` for any other tracker, so the PR can never
#     close the code repository's unrelated issue 12. Step 5 drives every issue explicitly.
# Same two guards as promoting-a-branch Step 3, per issue in the group:
#   - the `- no user surface` hatch is for an INHERENTLY absent surface (infra/migration/refactor),
#     never a surface you merely couldn't reach — obstructed means write the real plan, drive the
#     precondition as a step, and file a successor issue for the fixture.
#   - scan the assembled body for deferrals. The test is SEMANTIC, not textual: anything the body
#     records as deliberately not done ("known gaps", "out of scope", "TODO", "future work", "punted",
#     "follow-up", ...) counts, however phrased — those are examples, not a list to grep for. Each
#     needs an issue, named by its qualified id, verified open (IFS=$'\t' read -r _ _ STATE <<<"$("$DISP" issues get --number "FJ-31")"
#     then [ "$STATE" = open ] — state is field 3, normalized across backends, #205), filed right
#     then if absent. An issue this PR resolves does NOT count as the tracker, even on a Ready #N
#     hop where it stays open for now. Halt the group otherwise.
PR="$("$DISP" pr open --head "$INT" --base "$BASE" --title "Batch: <zone> (FJ-18, GH-12, …)" --body-file "$SCRATCH/pr-<zone>.md" --model <your-model-id>)"
# watch CI ("$DISP" ci watch --pr "<pr#>" …). Read the `status=` on the last line, NOT the exit code —
# it exits 0 on any terminal verdict. status=failure → record the group FAILED ("$DISP" ci log --pr "<pr#>"
# shows why) and move on;
# status=skipped → nothing ran, so the group is NOT verified: report that to the user and leave the PR
# open rather than treating not-failed as passed; status=success → merge on the gate, using stages[0]'s
# configured strategy (default "merge" — never hard-code one):
"$DISP" pr merge --number "<pr#>" --strategy "$("$DISP" config '.code.stages[0].strategy // "merge"')"
git -C "$MAIN" worktree remove "$SCRATCH/int-<zone>"
# The integration branch itself is left standing, local and on origin. `batch/*` is one of
# `flight branches`' default patterns, so `cleaning-up-branches` finds it once its PR is
# merged — don't hand-delete it here.
```

## Step 5: Per-issue bookkeeping + lifecycle (per promoted issue)

Identical to `working-an-issue` Step 4 / `promoting-a-branch` Step 5, for each **successfully
promoted** retained identity:

```bash
# Every call names the issue's OWN tracker: --tracker "$TRACKER" --number "$NUMBER" from Step 2.
# 1. Ensure a work-ledger comment exists (queue-batches branches already have one from
#    done-<prefix>.md; otherwise write a short finishing record and post it):
"$DISP" issues comment --tracker "$TRACKER" --number "$NUMBER" --body-file "$SCRATCH/done-$PREFIX.md" --model <your-model-id>
# 2. Ask the dispatcher for the stable family, then lazily ensure + add it.
#    A tool/service id returns non-zero and is skipped:
PRIMARY_MODEL=<model-id-from-ledger>
if FAMILY="$("$DISP" labels model-family --id "$PRIMARY_MODEL")"; then
  "$DISP" labels ensure --tracker "$TRACKER" --model "$PRIMARY_MODEL"
  "$DISP" issues label-add --tracker "$TRACKER" --number "$NUMBER" --label "model/$FAMILY"
fi
# 3. Stage-driven status/close (do NOT hard-code):
IS="$("$DISP" config '.code.stages[0].issueStatus // empty')"; [ -n "$IS" ] && "$DISP" issues set-status --tracker "$TRACKER" --number "$NUMBER" --status "$IS"
LAST=$(( $("$DISP" config '.code.stages | length') - 1 )); CL="$("$DISP" config '.code.stages[0].closesIssues // null')"
[ "$CL" = "null" ] && { [ 0 -eq "$LAST" ] && CL=true || CL=false; }; [ "$CL" = true ] && "$DISP" issues close --tracker "$TRACKER" --number "$NUMBER"
# 4. remove the worktree (anchored — never bare, you may be standing inside it):
git -C "$MAIN" worktree remove ".worktrees/${B#feature/}"
```

Then **consume the manifest** for exactly what was promoted — by qualified identity, not by label:

```bash
batch-manifest consume --issues "<the qualified identities promoted in this run>"
```

Don't derive this from "issues still at to-test": when `stages[0].issueStatus` is itself
`to-test` (the default multi-stage preset) a just-promoted issue is *still* labelled to-test, so
a label-based `heal --live` keeps everything and the manifest never drains. `heal --live` is for
the self-heal case in Step 3 (entries whose branches/worktrees vanished outside the workflow);
`consume --issues` is for the issues you just merged.

## Step 6: Report

Print a summary: promoted (per group, with SHAs / PR numbers), and skipped/failed with reason
(conflict, preflight, CI, no test plan). Skipped issues stay at `to-test`, unmerged, and remain
in their manifest for a re-run. A preflight skip names the log path so the user can read the
failure without re-running the gate.

## Common mistakes

- Treating a `pr` hop like a direct one (or vice-versa) — read `stages[0].merge`.
- Skipping manifest `heal` after promotion — promoted issues would linger. Heal after every group.
- Using `Closes #N` when `stages[0]` does not close issues — use `Ready #N`. And never write either
  by hand for another tracker's issue: `pr-reference` decides, and says `Tracks GH-12` instead.
- Matching branches, manifest zones or to-test rows by bare number. Two trackers can both have
  an issue 12; compare qualified ids, and read each tracker's own to-test label.
- Aborting the whole run on one conflict. Skip + report; never block the clean branches.
- Running `code.preflight` once on `BASE` after a direct group's merges instead of per branch
  before each one. It gives you a verdict you cannot act on: the only fix is unwinding a stage,
  and it tells you nothing about *which* branch broke the gate.
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
