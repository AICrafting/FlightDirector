# Worktrees + Stages Pipeline + promoting-a-branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make lightspeed worktree-safe, replace the single trunk/merge/gate config with an ordered **stages pipeline**, and add a **promoting-a-branch** skill that advances the current branch one stage at a time.

**Architecture:** Three coupled changes that all touch the dispatcher + config + `working-an-issue`, so they land together. (1) The dispatcher resolves config/secrets at the **main repo root** (parent of `git rev-parse --git-common-dir`) so a linked worktree — whose gitignored `.lightspeed.secrets.json` doesn't exist locally — still works, and gains a `config` passthrough so skills can read config from anywhere. (2) `code.stages` becomes an ordered list of `{name, merge, gate?}`; `stages[0]` is the first integration branch (feature branches fork from it). (3) `working-an-issue` runs each issue in a `.worktrees/<N>-<slug>` worktree and delegates the actual merge to `promoting-a-branch`, which does one hop (current branch → next stage) applying that hop's merge strategy and gate.

**Tech Stack:** bash + `curl` + `jq` (dispatcher/adapters), Markdown SKILL.md files, the `test-rig/forgejo` disposable Forgejo (15) for live verification. No new language or dependency.

**Verification model:** This repo has no unit-test framework; its established pattern is `shellcheck -x` + offline dispatcher checks + the rig smoke script. Tasks use that pattern: bash changes get an offline or rig-based check with exact expected output; SKILL.md changes get a `shellcheck`-clean command audit plus a scripted rig walkthrough of the verbs they invoke.

**Phasing:** Phase 1 (Tasks 1–3) is the foundation and is independently committable/testable. Phase 2 (Tasks 4–6) builds the skills on top. Do them in order.

---

## Phase 1 — Foundation

### Task 1: Dispatcher resolves config/secrets at the main repo root + `config` passthrough

**Files:**
- Modify: `lightspeed/scripts/lightspeed:30-40` (repo-root resolution + early `config` handling)

- [ ] **Step 1: Write the failing check (worktree resolution)**

Create a temporary offline check script in the scratchpad (not committed):

```bash
cat > /tmp/ls-wt-check.sh <<'EOF'
set -euo pipefail
DISP="$PWD/lightspeed/scripts/lightspeed"
T="$(mktemp -d)"; cd "$T"; git init -q
cat > .lightspeed.json <<'JSON'
{ "code": { "backend":"forgejo","owner":"o","repo":"r","api":"http://127.0.0.1:9/api/v1",
            "stages":[{"name":"develop","merge":"direct"}] } }
JSON
echo '{ "code": { "token":"t" } }' > .lightspeed.secrets.json
git add .lightspeed.json && git -c user.email=a@b -c user.name=a commit -qm init
# A linked worktree will NOT have the gitignored secrets file:
git worktree add -q wt -b feat 2>/dev/null
cd wt
echo "config from worktree:"; "$DISP" config '.code.stages[0].name'   # expect: develop
EOF
bash /tmp/ls-wt-check.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash /tmp/ls-wt-check.sh`
Expected: FAIL — either `unknown group 'config'` or `no .lightspeed.json at repo root (<worktree>)` (current dispatcher uses `--show-toplevel` and has no `config` group).

- [ ] **Step 3: Implement main-root resolution + `config` group**

Replace `lightspeed/scripts/lightspeed:30-40` (the `command -v jq` line through the secrets-tracked warning block) with:

```bash
command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

# Resolve the MAIN repo root — parent of the common git dir — so this works the
# same from the main checkout and from a linked worktree (whose gitignored
# .lightspeed.secrets.json does not exist locally). Falls back to cwd outside a repo.
if cdir="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  cdir="$(cd "$cdir" && pwd)"          # absolutize (valid relative to cwd)
  repo_root="$(dirname "$cdir")"
else
  repo_root="$(pwd)"
fi
cfg="$repo_root/.lightspeed.json"
sec="$repo_root/.lightspeed.secrets.json"

# `lightspeed config <jq-filter>` — read the resolved config from anywhere (incl. a worktree).
if [ "$group" = "config" ]; then
  [ -f "$cfg" ] || die "no .lightspeed.json at repo root ($repo_root)"
  jq -r "$verb" "$cfg"
  exit 0
fi

[ -f "$cfg" ] || die "no .lightspeed.json at repo root ($repo_root)"

# Loud, every-run warning if the secrets file is tracked by git (it holds a token).
if [ -f "$sec" ] && git -C "$repo_root" ls-files --error-unmatch .lightspeed.secrets.json >/dev/null 2>&1; then
  echo "lightspeed: WARNING — .lightspeed.secrets.json is tracked by git; it must be gitignored (it contains a token)." >&2
fi
```

Note: `group`/`verb` are already parsed above this block (`group="$1"; verb="$2"; shift 2`). The `config` filter arrives as `verb`, e.g. `lightspeed config '.code.stages[0].name'`.

- [ ] **Step 4: Run the check to verify it passes**

Run: `shellcheck lightspeed/scripts/lightspeed && bash /tmp/ls-wt-check.sh`
Expected: shellcheck clean; final line prints `develop` (config read from inside the worktree, secrets resolved at main root).

- [ ] **Step 5: Regression — normal (non-worktree) path still works**

Run the existing offline dispatcher checks:
```bash
DISP="$PWD/lightspeed/scripts/lightspeed"
T="$(mktemp -d)"; ( cd "$T" && git init -q && \
  printf '{"code":{"backend":"forgejo","owner":"o","repo":"r","api":"http://127.0.0.1:9/api/v1","stages":[{"name":"main","merge":"pr"}]}}' > .lightspeed.json && \
  echo '{"code":{"token":"t"}}' > .lightspeed.secrets.json && \
  "$DISP" issues list 2>&1 | tail -1 )
```
Expected: reaches the adapter and fails at curl (`forgejo/issues: GET …: curl failed`) — i.e. config/secrets resolved fine from the main checkout.

- [ ] **Step 6: Commit**

```bash
git add lightspeed/scripts/lightspeed
git commit -m "Dispatcher: resolve config/secrets at main repo root; add config passthrough

Worktree-safe — a linked worktree has no local (gitignored) secrets file, so
resolve via the parent of git-common-dir, which is the main checkout in both
cases. Add 'lightspeed config <jq-filter>' so skills can read config anywhere."
```

---

### Task 2: Stages pipeline config

**Files:**
- Modify: `lightspeed/scripts/lightspeed:51` (derive `LS_TRUNK` from `stages[0]`)
- Modify: `lightspeed/references/lightspeed-setup.md` (schema: stages, deprecate trunk/merge/gate)
- Modify: `test-rig/forgejo/up.sh` (write a stages config)

- [ ] **Step 1: Write the failing check (LS_TRUNK from stages)**

```bash
cat > /tmp/ls-trunk-check.sh <<'EOF'
set -euo pipefail
DISP="$PWD/lightspeed/scripts/lightspeed"
T="$(mktemp -d)"; cd "$T"; git init -q
cat > .lightspeed.json <<'JSON'
{ "code": { "backend":"forgejo","owner":"o","repo":"r","api":"http://127.0.0.1:9/api/v1",
            "stages":[{"name":"develop","merge":"direct"},{"name":"main","merge":"pr"}] } }
JSON
echo '{ "code": { "token":"t" } }' > .lightspeed.secrets.json
# pr open with no --base must default base to stages[0]=develop; we can see it in the error path
"$DISP" pr open --head feat --title x 2>&1 | tail -1
EOF
bash /tmp/ls-trunk-check.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash /tmp/ls-trunk-check.sh`
Expected: FAIL — `pr open: --base required (and no code.trunkBranch configured)` (current dispatcher derives `LS_TRUNK` from `code.trunkBranch`, which is absent in a stages config).

- [ ] **Step 3: Derive LS_TRUNK from stages[0] (with legacy fallback)**

Replace `lightspeed/scripts/lightspeed:51`:

```bash
LS_TRUNK="$(jq -r '(.code.trunkBranch) // (.code.stages[0].name) // empty' "$cfg")"
```

(Keeps `trunkBranch` working if present, else uses the first stage. The `pr` adapter is unchanged — it still reads `LS_TRUNK` for the base default.)

- [ ] **Step 4: Run the check to verify it passes**

Run: `shellcheck lightspeed/scripts/lightspeed && bash /tmp/ls-trunk-check.sh`
Expected: clean; last line is the curl failure for `POST /pulls` (base resolved to `develop`, so it got past arg validation to the API call).

- [ ] **Step 5: Update the setup reference schema**

In `lightspeed/references/lightspeed-setup.md`, replace the `gate` / `mergeStrategy` / `trunkBranch` fields in the `.lightspeed.json` example and bullets with the stages model:

```jsonc
"code": {
  "backend": "forgejo", "owner": "…", "repo": "…", "api": "https://…/api/v1",
  "stages": [
    { "name": "develop", "merge": "direct", "gate": "pre-merge" },
    { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa" },
    { "name": "main",    "merge": "pr" }
  ]
}
```

Add bullets:
- **`stages`** — ordered promotion pipeline. `stages[0]` is the first integration branch; feature branches fork from it. Each hop carries its own `merge` (`direct`|`pr`) and optional `gate` (`pre-merge`|`post-merge-qa`, default `pre-merge`). Consumed by `working-an-issue` (uses `stages[0]`) and `promoting-a-branch` (one hop at a time).
- Note: `trunkBranch`/`mergeStrategy`/`gate` (single-value) are superseded by `stages`; `trunkBranch` is still read as a fallback for `stages[0]`.

- [ ] **Step 6: Update the rig to write a stages config**

In `test-rig/forgejo/up.sh`, change the `jq -n … > "$WORK/.lightspeed.json"` block so `code` uses `stages` instead of `trunkBranch`:

```bash
jq -n --arg api "$API" --arg owner "$USER" --arg repo "$REPO" '{
  code: { backend:"forgejo", owner:$owner, repo:$repo, api:$api,
          stages:[ { name:"main", merge:"pr" } ] },
  labels: { status: {
    "in-progress":"status/in progress", "to-test":"status/to test", "blocked":"status/blocked"
  } }
}' > "$WORK/.lightspeed.json"
```

- [ ] **Step 7: Re-verify the rig smoke on the stages config**

Run: `./test-rig/forgejo/down.sh && ./test-rig/forgejo/up.sh && ./test-rig/forgejo/smoke.sh`
Expected: `✓ ALL 13 CHECKS PASSED` (pr open now resolves base from `stages[0]=main`).

- [ ] **Step 8: Commit**

```bash
git add lightspeed/scripts/lightspeed lightspeed/references/lightspeed-setup.md test-rig/forgejo/up.sh
git commit -m "Config: stages pipeline supersedes trunkBranch/mergeStrategy/gate

code.stages is an ordered [{name,merge,gate?}] list; stages[0] is the first
integration branch. Dispatcher derives LS_TRUNK from stages[0] (trunkBranch
still honored as a fallback). Setup reference + rig config updated."
```

---

### Task 3: Rig — permanent worktree-resolution check

**Files:**
- Create: `test-rig/forgejo/smoke-worktree.sh`

- [ ] **Step 1: Write the check script**

Create `test-rig/forgejo/smoke-worktree.sh` (mode +x):

```bash
#!/usr/bin/env bash
# Prove the dispatcher resolves config/secrets from inside a linked worktree
# (where the gitignored secrets file does NOT exist). Requires ./up.sh first.
set -uo pipefail
RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../lightspeed/scripts/lightspeed"
[ -f "$WORK/.lightspeed.json" ] || { echo "run ./up.sh first" >&2; exit 1; }

# Make WORK a real commit so we can add a worktree, then run the dispatcher from it.
git -C "$WORK" add -A >/dev/null 2>&1 || true
git -C "$WORK" -c user.email=rig@x -c user.name=rig commit -qm rig 2>/dev/null || true
rm -rf "$WORK/wt"; git -C "$WORK" worktree add -q wt -b wt-test
got="$( ( cd "$WORK/wt" && "$DISP" config '.code.stages[0].name' ) )"
git -C "$WORK" worktree remove --force wt 2>/dev/null || true

if [ -n "$got" ]; then printf '\033[32m✓ config read from worktree: %s\033[0m\n' "$got"
else printf '\033[31m✗ dispatcher could not resolve config from the worktree\033[0m\n'; exit 1; fi
```

- [ ] **Step 2: Make executable + shellcheck**

Run: `chmod +x test-rig/forgejo/smoke-worktree.sh && shellcheck test-rig/forgejo/smoke-worktree.sh`
Expected: clean.

- [ ] **Step 3: Run against the live rig**

Run: `./test-rig/forgejo/smoke-worktree.sh`
Expected: `✓ config read from worktree: main`

- [ ] **Step 4: Commit**

```bash
git add test-rig/forgejo/smoke-worktree.sh
git commit -m "Rig: add worktree config-resolution check"
```

---

## Phase 2 — Skills

### Task 4: Default labels — add `review` and `qa` status roles

**Files:**
- Modify: `lightspeed/references/default-labels.md` (add two status roles)

- [ ] **Step 1: Add the roles**

In `lightspeed/references/default-labels.md`, in the `status/*` section, add two roles used by the promotion gate:
- role `review` → `status/review` (color `#5319e7`, "In an open PR awaiting review")
- role `qa` → `status/qa` (color `#0e8a16`, "Merged, awaiting real-world verification")

Keep existing roles (`in-progress`, `to-test`, `blocked`, `deferred`) unchanged. Record the role→name mapping convention so `bootstrapping-labels` seeds them and `.lightspeed.json` `labels.status` can carry `"review"`/`"qa"`.

- [ ] **Step 2: Verify the data file is internally consistent**

Run: `grep -nE 'status/(review|qa)' lightspeed/references/default-labels.md`
Expected: both new rows present.

- [ ] **Step 3: Commit**

```bash
git add lightspeed/references/default-labels.md
git commit -m "Default labels: add status/review and status/qa roles for promotion gates"
```

---

### Task 5: `working-an-issue` — worktrees + stages[0] + delegate the merge

**Files:**
- Modify: `lightspeed/skills/working-an-issue/SKILL.md` (Start, Ready, merge-delegation)

**Seam:** `working-an-issue` owns the *issue* (worktree, status labels, finishing record, close). It no longer performs the branch merge itself — it **delegates to `promoting-a-branch`** for the `feature → stages[0]` hop, then records the outcome on the issue.

- [ ] **Step 1: Rewrite "Start work" to use a worktree off `stages[0]`**

Replace the Step 1 command block with:

```
# stages[0] is the first integration branch; fork the feature worktree from it.
BASE="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.stages[0].name')"
git worktree add ".worktrees/<N>-<slug>" -b "feature/<N>-<slug>" "$BASE"
# Do the work inside .worktrees/<N>-<slug>.
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues set-status --number N --status in-progress
```

Add a red flag: **Each issue gets its own worktree under `.worktrees/` (already gitignored)** — that's what enables working several issues in parallel. Never reuse one worktree for two issues.

- [ ] **Step 2: Keep "Ready for testing" as-is**

No change — still `issues set-status --number N --status to-test`. Verify the file still references it.

- [ ] **Step 3: Rewrite "On approved merge" to delegate + finish + clean up the worktree**

Replace merge step 1 ("Merge per the configured `mergeStrategy`") with:

```
1. **Promote the branch** feature → `stages[0]` using `promoting-a-branch` (it applies
   the hop's merge strategy and gate). Do not hand-merge here.
```

After the existing finishing actions (clear-status / comment / model label / close), append a cleanup step:

```
6. **Remove the issue's worktree** once merged:
   git worktree remove ".worktrees/<N>-<slug>"
```

Add a red flag: **Orphaned worktrees** — if a promotion is abandoned, remove the worktree (`git worktree remove --force …`) rather than leaving it dangling.

Also update the intro line that mentions reading `mergeStrategy`/`trunkBranch`: it now reads `stages[0]` (via `lightspeed config`) and leaves merge mechanics to `promoting-a-branch`.

- [ ] **Step 4: Audit the skill's commands run cleanly**

Run a command audit against the live rig (the verbs the skill uses must all exist and succeed):
```bash
DISP="$PWD/lightspeed/scripts/lightspeed"; WORK="$PWD/test-rig/forgejo/.work"
run(){ ( cd "$WORK" && "$DISP" "$@" ); }
run config '.code.stages[0].name'                 # expect: main
N=$(run issues create --title "WOI worktree test" --body x); echo "#$N"
run issues set-status --number "$N" --status in-progress
run issues set-status --number "$N" --status to-test
run issues clear-status --number "$N"
run issues close --number "$N"
echo "all working-an-issue verbs OK"
```
Expected: prints `main`, an issue number, then `all working-an-issue verbs OK` with no errors.

- [ ] **Step 5: Commit**

```bash
git add lightspeed/skills/working-an-issue/SKILL.md
git commit -m "working-an-issue: per-issue worktrees + delegate merge to promoting-a-branch

Start forks a .worktrees/<N>-<slug> worktree off stages[0]; finish delegates
the feature→stages[0] merge to promoting-a-branch, then records the outcome on
the issue and removes the worktree."
```

---

### Task 6: `promoting-a-branch` — new skill

**Files:**
- Create: `lightspeed/skills/promoting-a-branch/SKILL.md`

**Behavior:** one hop per invocation. Determine the current branch's stage (a feature branch → source is "feature", target `stages[0]`; on `stages[i].name` → target `stages[i+1].name`; or explicit `--to`). Apply that hop's `merge` and `gate`. For `pr` hops: draft a test-plan-with-halt block, open the PR, watch CI. Nudge linked issues' status per the gate.

- [ ] **Step 1: Write the SKILL.md**

Create `lightspeed/skills/promoting-a-branch/SKILL.md`:

```markdown
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

**`direct` hop:** local git merge into the target stage, then push.

```
git switch <target> && git merge --no-ff <branch> && git push && git switch -
```

**`pr` hop:** open a PR into the target stage and watch CI. Assemble the body in a scratchpad
file (Summary + the `## Test plans` block + `Ready #N` lines), then:

```
PR="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" pr open --head "$BRANCH" --base <target> \
        --title "…" --body-file "$SCRATCH/pr-body.md")"   # → number⇥url
```

Then watch CI in the background and surface state via Monitor:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" ci watch --sha "$(git rev-parse HEAD)" \
   --status-file /tmp/ls-ci/$BRANCH.json
```

On failure: `ci log --failed "$BRANCH"`, fix, push, re-watch. On success: tell the user
**"CI passed — ready to merge #<PR>."** Merge only on the user's go-ahead (`pre-merge` gate) or
per your `post-merge-qa` policy:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" pr merge --number <PR> --strategy squash
```

## Step 5: Nudge linked issues per the gate

- **`pre-merge`** — the issues were verified before merge; `working-an-issue` handles their
  finishing record/close. Nothing to do here beyond the merge.
- **`post-merge-qa`** — the PR used `Ready #N` (issues stay open). On merge, move each to the
  `qa` status so it's verified in the promoted stage:
  ```
  "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues set-status --number N --status qa
  ```
  When a later promotion carries those issues to the final stage and QA passes, close them
  (`issues close`).

## Common mistakes

- Promoting more than one hop at a time. One stage per invocation.
- Opening a `pr` hop without test plans for the resolved issues (the halt exists for a reason).
- Using `Closes #N` on a `post-merge-qa` hop — that auto-closes before verification. Use
  `Ready #N`.
- Hand-merging in `working-an-issue` instead of letting this skill own the hop.
```

- [ ] **Step 2: Command audit against the rig (direct + pr hops)**

Drive the verbs the skill uses on the live rig to prove they work end-to-end:

```bash
DISP="$PWD/lightspeed/scripts/lightspeed"; WORK="$PWD/test-rig/forgejo/.work"
run(){ ( cd "$WORK" && "$DISP" "$@" ); }
run config '.code.stages'                                  # pipeline reads
BR="promote-smoke-$$"
curl -fsS -H "Authorization: token $(jq -r .code.token "$WORK/.lightspeed.secrets.json")" \
  -X POST -H 'Content-Type: application/json' \
  -d "$(jq -n --arg br "$BR" '{content:"aGk=",message:"x",branch:"main",new_branch:$br}')" \
  "$(jq -r .code.api "$WORK/.lightspeed.json")/repos/rig/widget/contents/${BR}.txt" >/dev/null
PR="$(run pr open --head "$BR" --base main --title "promote smoke")"; echo "PR: $PR"
run pr merge --number "$(printf '%s' "$PR" | cut -f1)" --strategy squash && echo "pr hop OK"
```
Expected: prints the stages JSON, a `number⇥url` PR line, then `pr hop OK`.

- [ ] **Step 3: Commit**

```bash
git add lightspeed/skills/promoting-a-branch/SKILL.md
git commit -m "Add promoting-a-branch skill (one-hop stage advancement)

Advances the current branch one stage up code.stages, applying the hop's
merge strategy and gate. pr hops draft a test-plan-with-halt block, open a
PR, and watch CI; post-merge-qa hops use Ready #N and move issues to qa."
```

---

### Task 7: Wire the new skill into README + marketplace

**Files:**
- Modify: `lightspeed/README.md` (skills table row)
- Modify: `lightspeed/.claude-plugin/plugin.json` (keywords, optional)

- [ ] **Step 1: Add the skill to the README table**

Add a row to the skills table in `lightspeed/README.md`:

```
| `promoting-a-branch` | "promote this", "promote to qa", "open a PR for this branch", "this branch is ready" | Advances the current branch one stage up the pipeline (feature → develop → qa → main), with the hop's merge strategy, gate, test-plan halt, and CI watch |
```

Update the intro line "Four skills" → "Five skills".

- [ ] **Step 2: Verify links/format**

Run: `grep -c '| `.*` |' lightspeed/README.md` (table rows present) and visually confirm the new row.

- [ ] **Step 3: Commit**

```bash
git add lightspeed/README.md lightspeed/.claude-plugin/plugin.json
git commit -m "Document promoting-a-branch in the plugin README"
```

---

## Self-Review

**Spec coverage:**
- Worktree-safe config/secrets resolution → Task 1. ✓
- `lightspeed config` helper for skills → Task 1. ✓
- Stages pipeline config + LS_TRUNK derivation → Task 2. ✓
- Worktree resolution proven in the rig → Task 3. ✓
- Status roles for the promotion gate → Task 4. ✓
- `working-an-issue` worktrees + merge delegation → Task 5. ✓
- `promoting-a-branch` one-hop skill (test-plan halt, CI watch, gate) → Task 6. ✓
- Discoverability (README) → Task 7. ✓

**Type/name consistency:** `code.stages[].{name,merge,gate}`, role names `review`/`qa`, `lightspeed config '<jq-filter>'`, `LS_TRUNK` derivation, and `.worktrees/<N>-<slug>` are used identically across tasks.

**Open follow-ups (out of scope, noted not silently dropped):**
- A `worktreeDir` config knob (defaults to `.worktrees` as a convention here).
- Full `ci log` host-access implementation (still the API-summary MVP).
- A live multi-hop promotion walkthrough (develop→qa→main) once a repo actually defines >1 stage; the rig config uses a single `main` stage.
```
