# Batch-promote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote several first-hop feature branches in one command — grouped by zone / explicit issues / all — honoring the first hop's merge strategy (direct → N merges; pr → one PR per group).

**Architecture:** A small **tested bash helper** (`lightspeed/scripts/batch-manifest`) owns the per-run manifest that records each queue-batches run's issue→zone grouping (local, gitignored). `queue-batches` writes a manifest at dispatch; a new **`promoting-branches` skill** reads it (zone selection only), resolves groups, and drives per-hop promotion by reusing `promoting-a-branch`'s mechanics. Manifest maintenance (consume-on-promote + self-heal) is unified into one `heal --live` operation.

**Tech Stack:** bash + `jq` (already a dispatcher dependency), the lightspeed dispatcher, git worktrees, Forgejo/GitHub via adapters. Tests: `scripts/tests/*.test.sh` run by `scripts/runTests.sh` + CI `.forgejo/workflows/tests.yml`.

**Spec:** `docs/superpowers/specs/2026-07-01-batch-promote-design.md`

---

## File structure

- **Create** `lightspeed/scripts/batch-manifest` — manifest helper (subcommands `write`, `groups`, `heal`). Executed directly; local file logic; **not** a dispatcher verb (dispatcher is backend-only).
- **Create** `scripts/tests/batch-manifest.test.sh` — unit tests for the helper (sandbox via `BATCH_MANIFEST_ROOT`).
- **Create** `lightspeed/skills/promoting-branches/SKILL.md` — the batch-promote skill (orchestration prose).
- **Modify** `lightspeed/skills/queue-batches/SKILL.md` — write the manifest at dispatch (Section 3); point the handback (Section 5) at batch-promote.
- **Modify** `.gitignore` — ignore `.lightspeed/batches/`.
- **Modify** `.forgejo/workflows/tests.yml` — add `jq` to the CI test image.
- **Register** the new skill in the plugin's skills list if one exists (verify in Task 7).

### Manifest format

```jsonc
// .lightspeed/batches/<run-id>.json   (run-id = UTC timestamp, e.g. 2026-07-01T14-22-05Z)
{ "runId": "2026-07-01T14-22-05Z", "zones": { "lightspeed": [18, 93, 12], "docs": [40, 41] } }
```

### Helper interface (locked here; later tasks depend on it)

- `batch-manifest write --run-id <id> --zone <name> --issues "<n n n>" [--zone <name> --issues "<n n n>"]...`
  → writes `.lightspeed/batches/<id>.json`.
- `batch-manifest groups` → prints, one line per zone across **all** manifests (same-named zones merged, issues unioned & sorted): `<zone>\t<n,n,n>`. Empty output if no manifests.
- `batch-manifest heal --live "<n n n>"` → in every manifest keep only issues in the live set, drop empty zones, delete manifests left with no zones. Realizes both "consume on promote" (a promoted issue leaves the to-test/live set) and "self-heal on read".

Root resolution: `BATCH_MANIFEST_ROOT` env override, else the repo root (parent of the git common dir). Tests set `BATCH_MANIFEST_ROOT`.

---

## Task 1: Manifest helper — skeleton + `write` + gitignore

**Files:**
- Create: `lightspeed/scripts/batch-manifest`
- Create: `scripts/tests/batch-manifest.test.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Add the gitignore entry**

Add to `.gitignore` under the "Git worktrees" block:

```
# lightspeed queue-batches run manifests (transient local state)
.lightspeed/batches/
```

- [ ] **Step 2: Write the failing test for `write`**

Create `scripts/tests/batch-manifest.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for lightspeed/scripts/batch-manifest.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/lightspeed/scripts/batch-manifest"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
          else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export BATCH_MANIFEST_ROOT="$SANDBOX"
DIR="$SANDBOX/.lightspeed/batches"

# --- write ---
"$BM" write --run-id RUN1 --zone lightspeed --issues "18 93 12" --zone docs --issues "40 41"
check "write creates the manifest file" "$([ -f "$DIR/RUN1.json" ] && echo 1 || echo 0)"
check "write records zone lightspeed issues" \
  "$([ "$(jq -c '.zones.lightspeed' "$DIR/RUN1.json")" = "[18,93,12]" ] && echo 1 || echo 0)"
check "write records zone docs issues" \
  "$([ "$(jq -c '.zones.docs' "$DIR/RUN1.json")" = "[40,41]" ] && echo 1 || echo 0)"
check "write records runId" \
  "$([ "$(jq -r '.runId' "$DIR/RUN1.json")" = "RUN1" ] && echo 1 || echo 0)"

printf '\033[1m────────────────────────────\033[0m\n'
printf 'Passed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash scripts/tests/batch-manifest.test.sh`
Expected: FAIL — `batch-manifest` does not exist (`No such file or directory`).

- [ ] **Step 4: Implement the skeleton + `write`**

Create `lightspeed/scripts/batch-manifest`:

```bash
#!/usr/bin/env bash
# Manage per-run queue-batches manifests under .lightspeed/batches/.
# A manifest records a run's issue→zone grouping so batch-promote can honor
# "promote each zone" even when queue-batches inferred the zones. Local,
# transient, gitignored state.
set -euo pipefail

ROOT="${BATCH_MANIFEST_ROOT:-$(cd "$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")" && pwd)}"
DIR="$ROOT/.lightspeed/batches"

die() { printf 'batch-manifest: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
write)
	run_id=""; zones='{}'; cur=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--run-id) run_id="$2"; shift 2;;
			--zone)   cur="$2"; shift 2;;
			--issues)
				[ -n "$cur" ] || die "--issues given before --zone"
				# shellcheck disable=SC2086
				arr="$(printf '%s\n' $2 | jq -R 'select(length>0)|tonumber' | jq -s '.')"
				zones="$(printf '%s' "$zones" | jq --arg z "$cur" --argjson a "$arr" '.[$z]=$a')"
				cur=""; shift 2;;
			*) die "unknown argument: $1";;
		esac
	done
	[ -n "$run_id" ] || die "--run-id is required"
	mkdir -p "$DIR"
	jq -n --arg r "$run_id" --argjson z "$zones" '{runId:$r, zones:$z}' > "$DIR/$run_id.json"
	;;
*)
	die "unknown command: '$cmd' (expected: write|groups|heal)"
	;;
esac
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash scripts/tests/batch-manifest.test.sh`
Expected: PASS (4/4).

- [ ] **Step 6: Commit**

```bash
git add lightspeed/scripts/batch-manifest scripts/tests/batch-manifest.test.sh .gitignore
git commit -S -m "batch-manifest: write subcommand + gitignore .lightspeed/batches/ (#27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
"
```

---

## Task 2: Manifest helper — `groups`

**Files:**
- Modify: `lightspeed/scripts/batch-manifest`
- Modify: `scripts/tests/batch-manifest.test.sh`

- [ ] **Step 1: Add the failing test**

Append before the summary block in `scripts/tests/batch-manifest.test.sh`:

```bash
# --- groups: merges same-named zones across manifests, unions + sorts ---
"$BM" write --run-id RUN2 --zone lightspeed --issues "12 7" --zone rig --issues "50"
groups_out="$("$BM" groups | sort)"
check "groups lists lightspeed union sorted (7,12,18,93)" \
  "$(printf '%s\n' "$groups_out" | grep -qP '^lightspeed\t7,12,18,93$' && echo 1 || echo 0)"
check "groups lists docs (40,41)" \
  "$(printf '%s\n' "$groups_out" | grep -qP '^docs\t40,41$' && echo 1 || echo 0)"
check "groups lists rig (50)" \
  "$(printf '%s\n' "$groups_out" | grep -qP '^rig\t50$' && echo 1 || echo 0)"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/tests/batch-manifest.test.sh`
Expected: FAIL — `groups` hits the `*)` branch → `unknown command: 'groups'`.

- [ ] **Step 3: Implement `groups`**

In `lightspeed/scripts/batch-manifest`, add a case above the `*)` branch:

```bash
groups)
	[ -d "$DIR" ] || exit 0
	set -- "$DIR"/*.json
	[ -e "$1" ] || exit 0
	jq -rs '
		(map(.zones // {})
		 | reduce .[] as $z ({};
		     reduce ($z | keys_unsorted[]) as $k (.;
		       .[$k] = ((.[$k] // []) + $z[$k] | unique))))
		| to_entries[]
		| "\(.key)\t\(.value | map(tostring) | join(","))"
	' "$@"
	;;
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/tests/batch-manifest.test.sh`
Expected: PASS (7/7).

- [ ] **Step 5: Commit**

```bash
git add lightspeed/scripts/batch-manifest scripts/tests/batch-manifest.test.sh
git commit -S -m "batch-manifest: groups subcommand (merge zones across manifests) (#27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
"
```

---

## Task 3: Manifest helper — `heal`

**Files:**
- Modify: `lightspeed/scripts/batch-manifest`
- Modify: `scripts/tests/batch-manifest.test.sh`

- [ ] **Step 1: Add the failing test**

Append before the summary block:

```bash
# --- heal: keep only live issues; drop empty zones; delete empty manifests ---
# Live set omits 18,93,12 (promoted) and 7 — leaves lightspeed=[] in both manifests,
# docs=[40,41], rig=[50]. RUN1 loses lightspeed but keeps docs; RUN2 loses both zones → deleted.
"$BM" heal --live "40 41 50"
check "heal deletes a manifest with no zones left (RUN2)" \
  "$([ ! -f "$DIR/RUN2.json" ] && echo 1 || echo 0)"
check "heal keeps RUN1 (docs survives)" \
  "$([ -f "$DIR/RUN1.json" ] && echo 1 || echo 0)"
check "heal drops emptied zone lightspeed from RUN1" \
  "$([ "$(jq -c '.zones.lightspeed // "gone"' "$DIR/RUN1.json")" = '"gone"' ] && echo 1 || echo 0)"
check "heal keeps docs in RUN1" \
  "$([ "$(jq -c '.zones.docs' "$DIR/RUN1.json")" = "[40,41]" ] && echo 1 || echo 0)"

# Healing against an empty live set removes everything.
"$BM" heal --live ""
check "heal with empty live set clears all manifests" \
  "$([ -z "$(ls -A "$DIR" 2>/dev/null)" ] && echo 1 || echo 0)"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/tests/batch-manifest.test.sh`
Expected: FAIL — `unknown command: 'heal'`.

- [ ] **Step 3: Implement `heal`**

Add a case above the `*)` branch in `lightspeed/scripts/batch-manifest`:

```bash
heal)
	live=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--live) live="$2"; shift 2;;
			*) die "unknown argument: $1";;
		esac
	done
	[ -d "$DIR" ] || exit 0
	# shellcheck disable=SC2086
	live_json="$(printf '%s\n' $live | jq -R 'select(length>0)|tonumber' | jq -s '.')"
	for f in "$DIR"/*.json; do
		[ -e "$f" ] || continue
		new="$(jq --argjson live "$live_json" '
			.zones |= ( with_entries(.value |= map(select(. as $i | $live | index($i))))
			          | with_entries(select(.value | length > 0)) )
		' "$f")"
		if [ "$(printf '%s' "$new" | jq '.zones | length')" -eq 0 ]; then
			rm -f "$f"
		else
			printf '%s\n' "$new" > "$f"
		fi
	done
	;;
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/tests/batch-manifest.test.sh`
Expected: PASS (12/12).

- [ ] **Step 5: Commit**

```bash
git add lightspeed/scripts/batch-manifest scripts/tests/batch-manifest.test.sh
git commit -S -m "batch-manifest: heal subcommand (consume-on-promote + self-heal) (#27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
"
```

---

## Task 4: Executable bit + CI has `jq`

**Files:**
- Modify: `.forgejo/workflows/tests.yml`
- (index) `lightspeed/scripts/batch-manifest`, `scripts/tests/batch-manifest.test.sh`

- [ ] **Step 1: Commit the exec bit (core.fileMode is false — chmod won't stick)**

```bash
git update-index --chmod=+x lightspeed/scripts/batch-manifest scripts/tests/batch-manifest.test.sh
git ls-files -s lightspeed/scripts/batch-manifest   # expect 100755
```

- [ ] **Step 2: Add `jq` to the CI test image**

In `.forgejo/workflows/tests.yml`, change the setup line to include `jq`:

```yaml
      - name: Setup tools
        run: |
          apk add --update npm bash gawk git coreutils jq
```

- [ ] **Step 3: Verify locally**

Run: `shellcheck lightspeed/scripts/batch-manifest scripts/tests/batch-manifest.test.sh && bash scripts/runTests.sh`
Expected: shellcheck clean; runTests reports all tests pass (bump-version + batch-manifest).

- [ ] **Step 4: Commit**

```bash
git add .forgejo/workflows/tests.yml lightspeed/scripts/batch-manifest scripts/tests/batch-manifest.test.sh
git commit -S -m "batch-manifest: commit exec bit; add jq to CI test image (#27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
"
```

---

## Task 5: queue-batches writes the manifest at dispatch

**Files:**
- Modify: `lightspeed/skills/queue-batches/SKILL.md` (Section 3 "Dispatch")

This is a skill-doc change (no unit test — verification is that the instruction is present and correct).

- [ ] **Step 1: Add the run-id + manifest-write instruction to Section 3**

In `lightspeed/skills/queue-batches/SKILL.md`, in the `## 3. Dispatch` "Resolve once" block, after the `mkdir -p "$SCRATCH/queue-status"` line, add:

```bash
# A run id for this batch; also names the manifest that records issue→zone
# grouping so `promoting-branches` can honor "promote each zone" later.
RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
```

Then, still in Section 3, add a step immediately **after** the per-zone loop (after all zones' `ISSUES` are known) — insert this paragraph after the "Per zone:" bullet list:

```markdown
Once every zone's issue set is fixed, record the run manifest (one call, all zones) so
batch promotion can reconstruct the grouping — this survives even when zones were *inferred*
(no `code.zones`), which nothing else captures:

​```bash
"$CLAUDE_PLUGIN_ROOT/scripts/batch-manifest" write --run-id "$RUN_ID" \
  --zone <zone-a> --issues "<zone-a issue numbers>" \
  --zone <zone-b> --issues "<zone-b issue numbers>"   # …one --zone/--issues pair per zone
​```
```

(Replace the zero-width-space-guarded fences with real triple backticks when editing.)

- [ ] **Step 2: Verify the instruction is present**

Run: `grep -n "batch-manifest\" write --run-id" lightspeed/skills/queue-batches/SKILL.md`
Expected: one match in Section 3.

- [ ] **Step 3: Commit**

```bash
git add lightspeed/skills/queue-batches/SKILL.md
git commit -S -m "queue-batches: write a per-run issue→zone manifest at dispatch (#27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
"
```

---

## Task 6: The `promoting-branches` skill

**Files:**
- Create: `lightspeed/skills/promoting-branches/SKILL.md`

Skill prose (no unit test). It must mirror the voice/structure of `promoting-a-branch` (front-matter `name`/`description`, a red-flags section, numbered steps, common-mistakes). Create the file with this content:

````markdown
---
name: promoting-branches
description: Use when promoting several first-hop feature branches at once — "promote each zone", "promote the first zone", "promote issues 18, 93, 12", "promote all to-test", "batch promote", "ship the batch". Promotes a selected group of feature branches into stages[0], honoring that hop's merge strategy (direct → N merges; pr → one PR per group). For a single branch use promoting-a-branch.
---

# Promoting Branches (batch)

Promote several **first-hop** feature branches (typically the worktrees a `queue-batches` run left
at `to-test`) in one go, instead of M serial `promoting-a-branch` invocations — without breaking
the one-issue-one-branch invariant. Each issue keeps its own branch; a spoken selection resolves to
**groups**, and each group is promoted honoring `stages[0]`'s merge strategy.

All backend access is through the dispatcher; pipeline + zones live in `.lightspeed/config.json`.
Per-hop mechanics (merge/sign/PR/CI) are owned by `promoting-a-branch` — reuse them, don't
reinvent. Manifest state is managed by `lightspeed/scripts/batch-manifest`.

## Red flags — STOP

- **First hop only.** This promotes `feature → stages[0]`. Promoting `stages[i] → stages[i+1]` is a
  single-branch operation — use `promoting-a-branch`.
- **Never merge to a trunk stage without the hop's gate satisfied.** The user invoking batch-promote
  is the go-ahead for the whole selection; a `pr` hop still waits for CI before merging each PR.
- **Continue, don't abort.** A conflicting branch/group is skipped and reported — it must not block
  the clean ones.

## Step 1: Resolve the hop

```bash
DISP="$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"
BASE="$("$DISP" config '.code.stages[0].name')"
MERGE="$("$DISP" config '.code.stages[0].merge // "direct"')"   # direct | pr
```

`BASE` is the first-hop target; `MERGE` decides direct-merge vs one-PR-per-group.

## Step 2: Find candidate branches

Candidates are local `feature/*` branches whose linked issue is at `to-test`:

```bash
# to-test issue numbers (role → this repo's label resolved by the dispatcher)
"$DISP" issues list --state open --limit 100   # then keep those whose labels include the to-test status
# local feature branches:
git for-each-ref --format='%(refname:short)' refs/heads/feature
```

Match each `feature/<N>-<slug>` to its issue `<N>`; keep those at `to-test` and whose worktree exists
(`.worktrees/<N>-<slug>`). This is the LIVE set.

## Step 3: Resolve the selection into groups

- **"promote all to-test"** → one group = all candidates.
- **"promote issues A, B, C"** → one group = those candidate branches (stateless; no manifest).
- **"promote each zone" / "the first zone"** → read the manifest:
  ```bash
  LIVE="<space-separated candidate issue numbers>"
  "$CLAUDE_PLUGIN_ROOT/scripts/batch-manifest" heal --live "$LIVE"   # self-heal + consume before reading
  "$CLAUDE_PLUGIN_ROOT/scripts/batch-manifest" groups                # zone<TAB>n,n,n per line
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
MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
for each branch feature/<N>-<slug> in the group:
    git -C "$MAIN" merge --no-ff "feature/<N>-<slug>" -m "Merge feature/<N>-<slug> into $BASE (#<N>)"
    # if the merge commit signs badly (%G? = B), re-sign: git -C "$MAIN" commit --amend --no-edit -S
    # on conflict: git -C "$MAIN" merge --abort; record SKIPPED(<N>, conflict); continue
git -C "$MAIN" push   # once, after the group's merges
```

**If `MERGE` = pr** — one PR per group via an integration branch:

```bash
INT="batch/<zone-or-run>-<short>"
git -C "$MAIN" worktree add -b "$INT" "$SCRATCH/int-<zone>" "$BASE"
for each branch in the group:
    git -C "$SCRATCH/int-<zone>" merge --no-ff "feature/<N>-<slug>" \
      || { git -C "$SCRATCH/int-<zone>" merge --abort; record SKIPPED(<N>, conflict); }
git -C "$SCRATCH/int-<zone>" push -u origin "$INT"
# Assemble the PR body: Summary + a per-issue test plan (halt the group if a resolved issue has no
# writable plan) + one $KEYWORD #N line per included issue (Closes if stages[0] closesIssues, else Ready).
PR="$("$DISP" pr open --head "$INT" --base "$BASE" --title "Batch: <zone> (#<n>, #<n>, …)" --body-file "$SCRATCH/pr-<zone>.md")"
# watch CI ("$DISP" ci watch …); on failure record the group FAILED and move on; on success merge on the gate:
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
# 2. model label:
"$DISP" issues label-add --number <N> --label model/<primary>
# 3. Stage-driven status/close (do NOT hard-code):
IS="$("$DISP" config '.code.stages[0].issueStatus // empty')"; [ -n "$IS" ] && "$DISP" issues set-status --number <N> --status "$IS"
LAST=$(( $("$DISP" config '.code.stages | length') - 1 )); CL="$("$DISP" config '.code.stages[0].closesIssues // null')"
[ "$CL" = null ] && { [ 0 -eq "$LAST" ] && CL=true || CL=false; }; [ "$CL" = true ] && "$DISP" issues close --number <N>
# 4. remove the worktree:
git worktree remove ".worktrees/<N>-<slug>"
```

Then **consume the manifest** for what was promoted:

```bash
LIVE_AFTER="<issue numbers still at to-test>"
"$CLAUDE_PLUGIN_ROOT/scripts/batch-manifest" heal --live "$LIVE_AFTER"
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
````

- [ ] **Step 1: Create the file** with the content above.

- [ ] **Step 2: Verify front-matter + shellcheck of embedded intent**

Run: `head -4 lightspeed/skills/promoting-branches/SKILL.md`
Expected: valid front-matter with `name: promoting-branches`.

- [ ] **Step 3: Commit**

```bash
git add lightspeed/skills/promoting-branches/SKILL.md
git commit -S -m "Add promoting-branches skill (batch first-hop promotion) (#27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
"
```

---

## Task 7: Register the skill + point queue-batches handback at it

**Files:**
- Modify: `lightspeed/skills/queue-batches/SKILL.md` (Section 5 handback)
- Verify/modify: plugin skill registry if one exists

- [ ] **Step 1: Check whether skills are registered anywhere**

Run: `grep -rn "promoting-a-branch" lightspeed/.claude-plugin/ lightspeed/README.md lightspeed/GUIDE.md 2>/dev/null`
If a manifest/marketplace/README lists skills, add `promoting-branches` alongside `promoting-a-branch` in the same form. If nothing lists skills (skills are auto-discovered by directory), no change needed.

- [ ] **Step 2: Update the queue-batches handback (Section 5)**

In `lightspeed/skills/queue-batches/SKILL.md` `## 5. Completion & ship`, replace the serial-only handback blockquote with one that offers batch-promote first:

```markdown
> Ship the batch with `promoting-branches`: say "promote each zone" (one PR per zone on a pr hop, or
> all branches merged on a direct hop), "promote the first zone", or "promote issues <…>". It honors
> `stages[0]`'s merge strategy and cleans up the run manifest as issues promote. For a single branch,
> or to hand-pick, use `promoting-a-branch` one at a time.
```

- [ ] **Step 3: Verify**

Run: `grep -n "promoting-branches" lightspeed/skills/queue-batches/SKILL.md`
Expected: at least one match (Section 5), plus the Section 3 manifest write from Task 5.

- [ ] **Step 4: Commit**

```bash
git add lightspeed/skills/queue-batches/SKILL.md lightspeed/.claude-plugin/ lightspeed/README.md lightspeed/GUIDE.md 2>/dev/null
git commit -S -m "queue-batches: hand off to promoting-branches; register skill (#27)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
"
```

---

## Task 8: Manual integration verification (dogfood)

Skill prose can't be unit-tested; the manifest helper already is. Verify the end-to-end behavior by dogfooding on a throwaway set of issues — **not** an automated test.

- [ ] **Step 1: Direct-hop path (this repo)**

- Create 2–3 trivial throwaway issues, run a small `queue-batches` (e.g. `1x2` or hand-make 2 feature branches at `to-test`).
- Confirm `.lightspeed/batches/<run-id>.json` exists with the right issue→zone map.
- Invoke `promoting-branches`: "promote all to-test".
- Expected: each branch `merge --no-ff`'d into `develop`; each issue → `to-test` (stays open, develop non-terminal); worktrees removed; the manifest file gone (heal emptied it).

- [ ] **Step 2: Pr-hop path (simulated)**

- In a scratch clone/rig configured with a single `pr` `stages[0]`, repeat with two zones and "promote each zone".
- Expected: one PR per zone combining that zone's branches; CI watched; merged on the gate; manifest consumed.

- [ ] **Step 3: Failure path**

- Make two branches that touch the same line (guaranteed conflict), "promote all to-test".
- Expected: first promotes, second is skipped with a conflict note; its issue stays `to-test`; it remains in the manifest; summary reports 1 promoted / 1 skipped.

- [ ] **Step 4: Record results** in the issue #27 work-ledger when the branch is promoted.

---

## Self-review notes (author)

- **Spec coverage:** groups model (Tasks 6), direct + pr per-hop (Task 6), selection modes incl. stateless explicit/all (Task 6 Step 3), manifest write (Task 5) / groups+heal (Tasks 2–3) / two roles + self-heal unified into `heal` (Task 3), continue-and-report (Task 6 Steps 4/6, Task 8 Step 3), per-issue bookkeeping + stage-driven lifecycle (Task 6 Step 5), gitignore (Task 1), CI jq + exec bit (Task 4), queue-batches handback (Task 7), testing via unit + rig (Tasks 1–3, 8). All spec sections mapped.
- **Simplification vs spec:** the spec's separate "consume on promote" (prune) and "self-heal on read" are implemented by a single `heal --live` (a promoted issue leaves the live set, so heal drops it). Behavior ("manifests only shrink; nothing lingers") is preserved.
- **Type/name consistency:** helper path `lightspeed/scripts/batch-manifest`; subcommands `write`/`groups`/`heal`; manifest shape `{runId, zones}`; skill dir `lightspeed/skills/promoting-branches`. Used consistently across tasks.
