# Stage-Driven Issue Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a linked issue's open/closed state and status label a function of its stage position in the pipeline, via two optional per-stage config fields, instead of hard-closing at the first merge.

**Architecture:** Two new optional fields on each `code.stages[*]` entry — `issueStatus` (a status role set atomically on entering the stage) and `closesIssues` (boolean; defaults to "true iff terminal stage", overridable). `promoting-a-branch` becomes the single owner of issue status/close transitions for every hop; `working-an-issue` stops closing and keeps only a per-episode work-ledger comment. No dispatcher or adapter code changes — the generic `config` jq verb already reads the new fields, and `set-status`/`close` already exist.

**Tech Stack:** Bash dispatcher (`scripts/lightspeed`, generic `config` jq passthrough), Markdown skill files, Forgejo/GitHub adapters (unchanged).

**Spec:** `docs/superpowers/specs/2026-06-30-promotion-gate-lifecycle-design.md`

---

## File structure

All changes are to Markdown skill/reference files. No code files change.

- `lightspeed/references/lightspeed-setup.md` — config schema: document the two new fields.
- `lightspeed/skills/promoting-a-branch/SKILL.md` — owns stage-driven status/close + PR keyword rule.
- `lightspeed/skills/working-an-issue/SKILL.md` — stop closing; per-episode ledger only.
- `lightspeed/skills/setting-up-a-repo/SKILL.md` — presets seed `issueStatus`; correct the gate/lifecycle wording.

Why no code changes: `scripts/lightspeed config <jq-filter>` runs `jq -r "$filter" config.json` verbatim (verified at `scripts/lightspeed:43-48`), so `.code.stages[i].issueStatus` and `.code.stages[i].closesIssues` are already readable. The `issues set-status` and `issues close` verbs already exist (exercised by `test-rig/forgejo/smoke.sh:44-82`).

---

### Task 1: Document the two new fields in the config reference

**Files:**
- Modify: `lightspeed/references/lightspeed-setup.md:30-34` (example) and `:55-61` (stages bullet)

- [ ] **Step 1: Verify the dispatcher already reads the new fields (no code change needed)**

Create a throwaway 3-hop config and confirm the exact read paths the skills will use resolve correctly, including the terminal-default logic done in shell.

```bash
SB="$(mktemp -d)"; mkdir -p "$SB/repo/.lightspeed"
cat > "$SB/repo/.lightspeed/config.json" <<'JSON'
{ "code": { "backend": "forgejo", "owner": "a", "repo": "b", "api": "https://x/api/v1",
  "stages": [
    { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
    { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
    { "name": "main",    "merge": "pr" } ] } }
JSON
git -C "$SB/repo" init -q
DISP="$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"   # or ./lightspeed/scripts/lightspeed from repo root
( cd "$SB/repo"
  echo "develop.issueStatus = $("$DISP" config '.code.stages[0].issueStatus // empty')"
  echo "main.issueStatus    = $("$DISP" config '.code.stages[2].issueStatus // empty')"
  echo "main.closesIssues   = $("$DISP" config '.code.stages[2].closesIssues // null')"
  echo "stage count         = $("$DISP" config '.code.stages | length')" )
```

Expected output:
```
develop.issueStatus = to-test
main.issueStatus    =
main.closesIssues   = null
stage count         = 3
```
This confirms: present fields read back; absent `closesIssues` reads `null` (skills resolve `null` → terminal-default in shell); `length` gives the terminal index. No dispatcher change is required. Clean up: `rm -rf "$SB"`.

- [ ] **Step 2: Update the config example to include `issueStatus`**

In `lightspeed/references/lightspeed-setup.md`, replace the `stages` block at lines 30-34:

```jsonc
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main",    "merge": "pr" }
    ]
```

- [ ] **Step 3: Document the two fields after the `stages` bullet**

In the same file, immediately after the `stages` bullet (the one ending "...and `promoting-a-branch` (one hop at a time)."), insert two new bullets:

```markdown
- **`issueStatus`** (per stage, optional) — a **status role name** (a key in `labels.status`).
  On *entering* this stage, `promoting-a-branch` runs the atomic `issues set-status --status
  <role>` (adds the new status, drops the others in one call — the board can never show two
  states). Omit to leave the issue's status untouched on entry to this stage.
- **`closesIssues`** (per stage, optional, boolean) — **defaults to "true iff this is the
  terminal (last) stage."** Set explicitly to override: `false` on the terminal stage keeps
  issues open after the final stage; `true` on a non-terminal stage closes issues early at that
  stage (e.g. close at `develop`, treat `main` as a pure release cut). The `gate` field is
  orthogonal — it governs merge policy, not issue lifecycle.
```

- [ ] **Step 4: Verify the file still reads coherently**

Run: `sed -n '25,62p' lightspeed/references/lightspeed-setup.md`
Expected: the example shows `issueStatus` on develop/qa; the two new bullets appear after the `stages` bullet; no duplicated or orphaned lines.

- [ ] **Step 5: Commit**

```bash
git add lightspeed/references/lightspeed-setup.md
git commit -m "docs: document per-stage issueStatus + closesIssues config fields (#7)"
```

---

### Task 2: Make `promoting-a-branch` the owner of stage-driven status/close

**Files:**
- Modify: `lightspeed/skills/promoting-a-branch/SKILL.md` — red flags (24-26), Step 4 PR body (106-113), Step 5 (131-143), common mistakes (150)

- [ ] **Step 1: Add the terminal/close resolution to Step 4 (needed by `pr` hops for the keyword)**

In `lightspeed/skills/promoting-a-branch/SKILL.md`, at the start of the **`pr` hop** portion of Step 4 (just before the `PR=...` open command at line ~110), insert a shared resolution block:

````markdown
Resolve whether the **target stage** closes issues (drives the PR keyword *and* Step 5). `<i>` is
the target stage's index:

```
LAST_IDX=$(( $("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config '.code.stages | length') - 1 ))
CLOSES="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config ".code.stages[<i>].closesIssues // null")"
if [ "$CLOSES" = "null" ]; then [ "<i>" -eq "$LAST_IDX" ] && CLOSES=true || CLOSES=false; fi
ISSUE_STATUS="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" config ".code.stages[<i>].issueStatus // empty")"
# PR issue keyword: Closes only if the target stage closes issues, else Ready (keeps issue open).
KEYWORD=Ready; [ "$CLOSES" = true ] && KEYWORD=Closes
```
````

- [ ] **Step 2: Use the derived keyword in the PR body**

In Step 4, change the PR body assembly instruction so the issue lines use `$KEYWORD #N` instead of the hardcoded `Ready #N`. Replace the parenthetical at line ~107 ("(Summary + the `## Test plans` block + `Ready #N` lines)") with:

```markdown
(Summary + the `## Test plans` block + `$KEYWORD #N` lines — `Closes` when the target stage
closes issues, else `Ready`).
```

- [ ] **Step 3: Replace Step 5 with one stage-driven rule for all hops**

Replace the entire Step 5 section (lines 131-143, from "## Step 5: Nudge linked issues per the gate" through the closing of the `post-merge-qa` bullet) with:

````markdown
## Step 5: Drive linked-issue lifecycle from the target stage

After the merge into `<target>` succeeds, the **target stage** decides what happens to each
resolved `#N` — the *same* rule at every hop, `direct` or `pr`. Reuse `CLOSES` / `ISSUE_STATUS`
from Step 1 of the hop (for a `direct` hop that skipped Step 1, resolve them now with the same
block). For each resolved `#N`:

- `ISSUE_STATUS` non-empty → set the stage's status atomically:
  ```
  "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues set-status --number N --status "$ISSUE_STATUS"
  ```
- `CLOSES` is `true` → close it; otherwise leave it **open** so a later promotion handles it:
  ```
  "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues close --number N
  ```

This is the whole lifecycle: an issue's status and open/closed state follow its stage position.
The terminal stage (or any stage with `closesIssues: true`) closes; every earlier stage just
relabels and keeps it open. `working-an-issue` no longer closes at the first hop — it leaves a
work-ledger comment and delegates the status/close to this step.
````

- [ ] **Step 4: Update the Red flags bullet about the keyword**

Replace the second red-flag bullet (lines 24-26, "Never promote to a trunk stage without the hop's gate satisfied...") with:

```markdown
- **Never promote to a trunk stage without the hop's gate satisfied.** A `pre-merge` hop needs
  the user's go-ahead; a `post-merge-qa` hop merges then verifies. The gate governs *merging*;
  issue close/relabel is governed separately by the target stage's `closesIssues`/`issueStatus`
  (Step 5). A `pr` hop uses `Closes #N` only when the target stage closes issues, else `Ready #N`.
```

- [ ] **Step 5: Update the Common mistakes bullet about `Closes`**

Replace the "Using `Closes #N` on a `post-merge-qa` hop..." bullet (line ~150) with:

```markdown
- Using `Closes #N` when promoting into a stage that does **not** close issues (a non-terminal
  stage, or one with `closesIssues: false`) — that auto-closes before later verification. Use
  `Ready #N`; `Closes #N` is only for a stage whose effective `closesIssues` is true.
```

- [ ] **Step 6: Verify the skill is self-consistent**

Run: `grep -n 'CLOSES\|ISSUE_STATUS\|KEYWORD\|closesIssues\|issueStatus\|Ready\|Closes\|post-merge-qa' lightspeed/skills/promoting-a-branch/SKILL.md`
Expected: `CLOSES`/`ISSUE_STATUS`/`KEYWORD` are each *defined* (Step 1 block) before any use; Step 5 references them; no remaining text claims `post-merge-qa` itself keeps issues open (lifecycle now flows from `closesIssues`).

- [ ] **Step 7: Commit**

```bash
git add lightspeed/skills/promoting-a-branch/SKILL.md
git commit -m "promoting-a-branch: stage-driven issue status/close + PR keyword from target stage (#7)"
```

---

### Task 3: Make `working-an-issue` stop closing; keep a per-episode ledger

**Files:**
- Modify: `lightspeed/skills/working-an-issue/SKILL.md` — Step 4 (88-123), Common mistakes (125-138)

- [ ] **Step 1: Rewrite Step 4 to remove close/clear-status and frame the ledger as per-episode**

Replace the entire "### 4. On approved merge — finish the issue" section (lines 88-123, through the worktree-removal block) with:

````markdown
### 4. On approved merge — record the work and promote

Only after explicit approval:

1. **Comment a work-ledger entry.** Each completed chunk of work leaves its *own* record — the
   issue's comment thread is a running ledger (initial code, later follow-up code, and QA each
   append their own entry). Write it to a scratchpad file and pass `--body-file`:
   - A summary of the work done in **this** episode.
   - **Token cost, token counts, and model(s).** Preferred source: a `prompt_log.jsonl` in the
     repo root, if maintained (each line has `session_id`, `model`, token counts, `cost_usd`).
     Filter to this work's `session_id`(s), sum `cost_usd`/tokens, read `model`. If no such log
     exists, fall back to a rough estimate and the model you know you're running. (The log is
     optional and personal — gitignored, not shipped by this plugin.)
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues comment --number N --body-file "$SCRATCH/done.md"
   ```
2. **Add the `model/<primary>` label** for the main model used (e.g. `model/opus`) — the one with
   the most tokens/cost in the log when available, else the model you ran. Idempotent; later
   episodes may add another `model/*`. See `model/*` in
   [default-labels.md](../../references/default-labels.md):
   ```
   "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues label-add --number N --label model/opus
   ```
3. **Promote the branch** `feature/<N>-<slug>` → `stages[0]` using `promoting-a-branch` (invoke
   the skill in this session). It applies the hop's merge strategy/gate **and** drives the
   issue's status/close from `stages[0]`'s `issueStatus`/`closesIssues` (Step 5 of that skill):
   a single-trunk repo's terminal `stages[0]` closes the issue; in a multi-stage pipeline it just
   sets the stage's status and the issue stays open until a closing stage. **Do not** set status
   or close the issue here — that is stage-driven now, and double-handling it makes the board lie.
4. **Remove the issue's worktree** once merged (run from the repo root, not inside the worktree):
   ```
   git worktree remove ".worktrees/<N>-<slug>"
   ```
````

- [ ] **Step 2: Update Common mistakes to match**

In the "## Common mistakes" section, replace the "Closing the issue but forgetting the finishing
comment..." bullet (line ~132) with:

```markdown
- Promoting without leaving the work-ledger comment (summary / cost / tokens / model) — that
  per-episode record is the auditable point of the whole workflow; the merge is not the record.
- Manually closing or relabeling the issue on merge — `working-an-issue` no longer closes.
  Status and close are driven by the target stage in `promoting-a-branch` (Step 5). Setting them
  here too makes the board show a state the pipeline didn't ask for.
```

- [ ] **Step 3: Check the skill no longer instructs a close**

Run: `grep -n 'issues close\|clear-status\|close the issue\|Close the issue' lightspeed/skills/working-an-issue/SKILL.md`
Expected: no remaining instruction for `working-an-issue` to run `issues close` or `clear-status` on merge. (References that *describe* promoting-a-branch closing are fine.)

- [ ] **Step 4: Commit**

```bash
git add lightspeed/skills/working-an-issue/SKILL.md
git commit -m "working-an-issue: stop closing on merge; per-episode work-ledger only (#7)"
```

---

### Task 4: Seed `issueStatus` in `setting-up-a-repo` presets and fix the lifecycle wording

**Files:**
- Modify: `lightspeed/skills/setting-up-a-repo/SKILL.md` — preset (b) (77-86), defaults (92-97), Step 4 example (104-121)

- [ ] **Step 1: Add `issueStatus` to preset (b) and correct its description**

Replace preset (b) (lines 77-86) with:

````markdown
**(b) Multi-stage — `develop → qa → main`**
Same as (a) but an intermediate `qa` branch sits between integration and production. Each stage
carries an `issueStatus` so the board mirrors the issue's position; issues stay open until the
terminal stage (`main`), where they close:
```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
  { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
  { "name": "main",    "merge": "pr" }
]
```
````

- [ ] **Step 2: Fix the "Defaults explained" gate/lifecycle bullet**

Replace the `gate:` bullet (lines 95-96) with two bullets that separate gate from lifecycle:

```markdown
- `gate: "pre-merge"` runs checks before merging; `gate: "post-merge-qa"` merges then verifies in
  that environment. The gate governs *merging only*.
- `issueStatus` (per stage, optional) sets the issue's status label on entering that stage;
  `closesIssues` (per stage, optional) overrides the default close point, which is the terminal
  stage. Together they drive issue lifecycle independently of `gate`. See
  [lightspeed-setup.md](../../references/lightspeed-setup.md).
```

- [ ] **Step 3: Add `issueStatus` to the Step 4 example config**

In the Step 4 example (lines 107-111), replace the `stages` block with:

```json
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main",    "merge": "pr" }
    ],
```

- [ ] **Step 4: Verify presets and example agree**

Run: `grep -n 'issueStatus\|closesIssues\|post-merge-qa\|Ready #N' lightspeed/skills/setting-up-a-repo/SKILL.md`
Expected: `issueStatus` appears in preset (b) and the Step 4 example; no surviving claim that the `gate` (rather than `issueStatus`/`closesIssues`) is what keeps an issue open. Preset (a) single-trunk is unchanged (its terminal `main` closes by default — correct).

- [ ] **Step 5: Commit**

```bash
git add lightspeed/skills/setting-up-a-repo/SKILL.md
git commit -m "setting-up-a-repo: seed issueStatus in presets; separate gate from issue lifecycle (#7)"
```

---

### Task 5: Final cross-skill consistency pass

**Files:** none modified unless a gap is found.

- [ ] **Step 1: Confirm the close/relabel story is told once and consistently**

Run:
```bash
grep -rn 'issues close\|set-status\|closesIssues\|issueStatus\|Ready #N\|Closes #N\|post-merge-qa' \
  lightspeed/skills/working-an-issue/SKILL.md \
  lightspeed/skills/promoting-a-branch/SKILL.md \
  lightspeed/skills/setting-up-a-repo/SKILL.md \
  lightspeed/references/lightspeed-setup.md
```
Verify: (1) only `promoting-a-branch` runs `issues close`/`set-status` for lifecycle; (2)
`working-an-issue` only `comment`s + `label-add`s + promotes; (3) `Closes #N` is gated on the
target stage closing issues everywhere it appears; (4) the two fields are defined identically in
the reference and used the same way in the skills. Fix any drift inline and amend the relevant
commit.

- [ ] **Step 2: Re-run the Task 1 dispatcher read check end-to-end**

Re-run the throwaway-config block from Task 1 Step 1 and confirm the same expected output. This
proves the read paths the edited skills now depend on still resolve with no code change.

- [ ] **Step 3: No-op commit guard**

Run: `git status --short`
Expected: clean (all changes already committed in Tasks 1-4). If anything is staged from a
consistency fix, commit it:
```bash
git commit -am "docs: cross-skill consistency for stage-driven issue lifecycle (#7)"
```

---

## Notes for the implementer

- These are **instruction-file edits**, not code. "Verification" steps run the dispatcher's
  generic `config` verb and grep the edited Markdown — there is no unit-test harness for skill
  prose. Do not add pytest or fabricate code tests.
- The live `test-rig/forgejo/smoke.sh` already covers `set-status` and `close` (lines 44-82); it
  needs **no** change because the verbs and their behavior are unchanged — only *which skill calls
  them, and when* changes.
- `<i>` in the `promoting-a-branch` snippets is the target stage's index resolved in that skill's
  Step 1 ("If `BRANCH` is one of the stage names at index `i`, the target is stage `i+1`..."). Keep
  it a literal substitution point, consistent with how the rest of that skill is written.
