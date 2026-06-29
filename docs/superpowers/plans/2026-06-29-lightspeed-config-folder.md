# `.lightspeed/` config-folder reorg Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move lightspeed's per-repo config out of the repo root into a `.lightspeed/` folder — `config.json` (was `.lightspeed.json`), `secrets.json` (was `.lightspeed.secrets.json`), `agent-rules.md` (was `.lightspeed-agent-rules.md`) — as a hard cut, with no fallback to the old paths.

**Architecture:** The dispatcher's resolution *model* is unchanged (still resolves config at the main repo root, parent of `git rev-parse --git-common-dir`, then exports the same `LS_*` env). Only the two file *paths* move. Adapters are untouched (they never read config). The change is almost entirely a deterministic string rename of three path literals; the only non-mechanical bits are the dispatcher's offline verification and adding a `mkdir -p` before the rig/setup writes.

**Tech Stack:** bash (`lightspeed` dispatcher + rig scripts), Markdown (skills/docs), `sed` for the deterministic path swaps, `shellcheck`, the forgejo + github test rigs for live verification. No new dependency.

**The three path renames (used throughout):**
```
sed -E 's@\.lightspeed\.secrets\.json@.lightspeed/secrets.json@g'   # do this one first
sed -E 's@\.lightspeed\.json@.lightspeed/config.json@g'
sed -E 's@\.lightspeed-agent-rules\.md@.lightspeed/agent-rules.md@g'
```
(The `\.lightspeed\.json` pattern does **not** match inside `.lightspeed.secrets.json` — after `.lightspeed` comes `.secrets`, not `.json` — so the two are independent, but run secrets-first anyway.)

**Spec:** `docs/superpowers/specs/2026-06-29-lightspeed-config-folder-design.md`.

**Verification model:** No unit framework — `shellcheck -x` + offline dispatcher checks + the live rig smoke (forgejo 13/13, github 15/15). `docs/superpowers/` specs/plans keep the old names (historical) and are excluded from stale-ref checks.

**Phasing:** Task 1 (dispatcher) is the foundation and must land first. Tasks 2–4 update the rigs, skills, and docs. Task 5 is the live end-to-end verification. Do them in order.

`$SCRATCH` = the session scratchpad dir (temp scripts, never committed).

---

## Task 1: Dispatcher — resolve config in `.lightspeed/`

**Files:**
- Modify: `lightspeed/scripts/lightspeed`

- [ ] **Step 1: Apply the path renames to the dispatcher**

```bash
sed -i -E 's@\.lightspeed\.secrets\.json@.lightspeed/secrets.json@g; s@\.lightspeed\.json@.lightspeed/config.json@g' lightspeed/scripts/lightspeed
```
This updates: the `cfg`/`sec` path vars, both missing-config `die` messages, the `git ls-files --error-unmatch` argument + the tracked-secrets warning text, the `set code.backend … in …` message, and the header comment.

- [ ] **Step 2: Confirm the resulting lines are correct**

```bash
grep -nE 'cfg=|sec=|ls-files --error-unmatch|no \.lightspeed|in \.lightspeed' lightspeed/scripts/lightspeed
```
Expected (paths now under `.lightspeed/`):
```
cfg="$repo_root/.lightspeed/config.json"
sec="$repo_root/.lightspeed/secrets.json"
... die "no .lightspeed/config.json at repo root ($repo_root)"     (×2)
... ls-files --error-unmatch .lightspeed/secrets.json ...
... WARNING — .lightspeed/secrets.json is tracked by git ...
... "set code.backend or ${axis}.backend in .lightspeed/config.json"
```

- [ ] **Step 3: shellcheck**

Run: `shellcheck lightspeed/scripts/lightspeed`
Expected: no errors.

- [ ] **Step 4: Offline verification (new path resolves; old behavior preserved)**

```bash
cat > "$SCRATCH/ls-folder-check.sh" <<'EOF'
set -uo pipefail
DISP="$PWD/lightspeed/scripts/lightspeed"

# (a) config read from the new path
T="$(mktemp -d)"; ( cd "$T" && git init -q && mkdir -p .lightspeed \
  && printf '{"code":{"backend":"forgejo","owner":"o","repo":"r","api":"http://127.0.0.1:9/api/v1","stages":[{"name":"develop","merge":"direct"}]}}' > .lightspeed/config.json \
  && echo '{"code":{"token":"t"}}' > .lightspeed/secrets.json \
  && echo "config read: $("$DISP" config '.code.stages[0].name')" )   # expect: develop

# (b) missing config -> die names the new path
T2="$(mktemp -d)"; ( cd "$T2" && git init -q && "$DISP" config '.x' 2>&1 | head -1 )  # expect: no .lightspeed/config.json at repo root

# (c) worktree resolves config from the main root's .lightspeed/
( cd "$T" && git add .lightspeed/config.json && git -c user.email=a@b -c user.name=a commit -qm init \
  && git worktree add -q wt -b feat 2>/dev/null \
  && cd wt && echo "from worktree: $("$DISP" config '.code.stages[0].name')" )  # expect: develop

# (d) tracked secrets.json -> loud warning
T3="$(mktemp -d)"; cd "$T3"; git init -q; mkdir -p .lightspeed
printf '{"code":{"backend":"forgejo","owner":"o","repo":"r","api":"x","stages":[{"name":"d","merge":"direct"}]}}' > .lightspeed/config.json
echo '{"code":{"token":"t"}}' > .lightspeed/secrets.json
git add -A && git -c user.email=a@b -c user.name=a commit -qm init
out="$("$DISP" issues list 2>&1 || true)"
grep -qi 'secrets.json is tracked' <<<"$out" && echo "tracked-warning OK" || echo "tracked-warning MISSING"
EOF
bash "$SCRATCH/ls-folder-check.sh"
```
Run: the block above.
Expected: `config read: develop`; the (b) line contains `no .lightspeed/config.json at repo root`; `from worktree: develop`; `tracked-warning OK`.

- [ ] **Step 5: Commit**

```bash
git add lightspeed/scripts/lightspeed
git commit -m "dispatcher: resolve config/secrets in .lightspeed/ folder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Test rigs (forgejo + github) write/read `.lightspeed/`

**Files:**
- Modify: `test-rig/forgejo/up.sh`, `test-rig/forgejo/smoke.sh`, `test-rig/forgejo/smoke-worktree.sh`, `test-rig/forgejo/README.md`
- Modify: `test-rig/github/up.sh`, `test-rig/github/smoke.sh`, `test-rig/github/down.sh`, `test-rig/github/README.md`

- [ ] **Step 1: Apply the path renames across all rig files**

```bash
sed -i -E 's@\.lightspeed\.secrets\.json@.lightspeed/secrets.json@g; s@\.lightspeed\.json@.lightspeed/config.json@g' \
  test-rig/forgejo/up.sh test-rig/forgejo/smoke.sh test-rig/forgejo/smoke-worktree.sh test-rig/forgejo/README.md \
  test-rig/github/up.sh  test-rig/github/smoke.sh  test-rig/github/down.sh  test-rig/github/README.md
```

- [ ] **Step 2: Add `mkdir -p "$WORK/.lightspeed"` before the writes in each `up.sh`**

In `test-rig/forgejo/up.sh`, find the line that creates the workdir:
```bash
rm -rf "$WORK"; mkdir -p "$WORK"; git -C "$WORK" init -q
```
and change it to also create the folder:
```bash
rm -rf "$WORK"; mkdir -p "$WORK/.lightspeed"; git -C "$WORK" init -q
```
(`mkdir -p "$WORK/.lightspeed"` creates `$WORK` too.)

In `test-rig/github/up.sh`, find the same idiom (added earlier):
```bash
rm -rf "$WORK"; mkdir -p "$WORK"; git -C "$WORK" init -q
```
and change it identically to:
```bash
rm -rf "$WORK"; mkdir -p "$WORK/.lightspeed"; git -C "$WORK" init -q
```
If a rig's `up.sh` instead has a bare `mkdir -p "$WORK"` on the workdir-config line (no `git init`), change that to `mkdir -p "$WORK/.lightspeed"` and ensure a `git -C "$WORK" init -q` follows (the github fix added it; the forgejo one already has it). Verify by reading the relevant lines first.

- [ ] **Step 3: Confirm the write/read targets moved and the dirs are created**

```bash
echo "=== writes/reads now under .lightspeed/ ? ==="
grep -rn '\.lightspeed/config\.json\|\.lightspeed/secrets\.json' test-rig/forgejo test-rig/github
echo "=== mkdir creates the folder ? ==="
grep -n 'mkdir -p "\$WORK/\.lightspeed"' test-rig/forgejo/up.sh test-rig/github/up.sh
echo "=== no stale root-file refs left in rigs ? ==="
grep -rn '\.lightspeed\.json\|\.lightspeed\.secrets\.json' test-rig/ | grep -v '/\.work/' || echo "✓ none"
```
Expected: config/secrets reads+writes are all `.lightspeed/…`; both `up.sh` create `$WORK/.lightspeed`; no stale `.lightspeed.json`/`.lightspeed.secrets.json` left.

- [ ] **Step 4: shellcheck all rig scripts**

```bash
shellcheck test-rig/forgejo/up.sh test-rig/forgejo/smoke.sh test-rig/forgejo/smoke-worktree.sh \
           test-rig/github/up.sh  test-rig/github/smoke.sh  test-rig/github/down.sh && echo CLEAN
```
Expected: `CLEAN` (the github `down.sh` keeps its existing `# shellcheck disable=SC2046` directives; the github `smoke.sh` keeps its `SC2015` disable).

- [ ] **Step 5: Commit**

```bash
git add test-rig/forgejo test-rig/github
git commit -m "test rigs: write/read config in .work/.lightspeed/

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `setting-up-a-repo` + `queue-batches` skills

**Files:**
- Modify: `lightspeed/skills/setting-up-a-repo/SKILL.md`
- Modify: `lightspeed/skills/queue-batches/SKILL.md`

- [ ] **Step 1: Apply path renames to both skills**

```bash
sed -i -E 's@\.lightspeed\.secrets\.json@.lightspeed/secrets.json@g; s@\.lightspeed\.json@.lightspeed/config.json@g; s@\.lightspeed-agent-rules\.md@.lightspeed/agent-rules.md@g' \
  lightspeed/skills/setting-up-a-repo/SKILL.md lightspeed/skills/queue-batches/SKILL.md
```
This moves the setup skill's config/secrets references and the gitignore line (`.lightspeed/secrets.json`), and `queue-batches`'s `agentRulesFile` default (`.lightspeed/agent-rules.md`).

- [ ] **Step 2: Tell the setup skill to create the folder first**

In `lightspeed/skills/setting-up-a-repo/SKILL.md`, the gitignore-then-write step (Step 2) currently reads (after Step 1's sed):
```
1. Add `.lightspeed/secrets.json` **and** `.worktrees/` to `.gitignore` **first** (create
   `.gitignore` if needed). `.worktrees/` is where `working-an-issue` creates per-issue git
   worktrees — they must be ignored so they don't appear as untracked content in the repo.
2. Write `.lightspeed/secrets.json` at the repo root:
```
Insert a new first sub-step so the folder exists before any write. Change the numbered list to:
```
1. Create the config folder: `mkdir -p .lightspeed`.
2. Add `.lightspeed/secrets.json` **and** `.worktrees/` to `.gitignore` **first** (create
   `.gitignore` if needed). `.worktrees/` is where `working-an-issue` creates per-issue git
   worktrees — they must be ignored so they don't appear as untracked content in the repo.
3. Write `.lightspeed/secrets.json`:
```
Then, in **Step 4** of the skill ("Write the initial config"), the instruction now says "Write
`.lightspeed/config.json` at the repo root …" — change "at the repo root" to "in the `.lightspeed/`
folder (created in Step 2)" so the location is unambiguous.

- [ ] **Step 3: Verify**

```bash
echo "=== folder-create instruction present ? ==="
grep -n 'mkdir -p \.lightspeed' lightspeed/skills/setting-up-a-repo/SKILL.md
echo "=== agent-rules default moved ? ==="
grep -n '\.lightspeed/agent-rules\.md' lightspeed/skills/queue-batches/SKILL.md
echo "=== no stale refs in either skill ? ==="
grep -n '\.lightspeed\.json\|\.lightspeed\.secrets\.json\|\.lightspeed-agent-rules\.md' \
  lightspeed/skills/setting-up-a-repo/SKILL.md lightspeed/skills/queue-batches/SKILL.md || echo "✓ none"
```
Expected: the `mkdir -p .lightspeed` line is present; `queue-batches` references `.lightspeed/agent-rules.md`; no stale root-file references remain in either skill.

- [ ] **Step 4: Commit**

```bash
git add lightspeed/skills/setting-up-a-repo/SKILL.md lightspeed/skills/queue-batches/SKILL.md
git commit -m "skills: setting-up-a-repo writes .lightspeed/ folder; queue-batches agent-rules path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Docs + remaining prose references

**Files:**
- Modify: `lightspeed/references/lightspeed-setup.md`, `lightspeed/references/adapter-contract.md`
- Modify: `lightspeed/GUIDE.md`, `lightspeed/README.md`
- Modify: `lightspeed/skills/filing-issues/SKILL.md`, `lightspeed/skills/triaging-issues/SKILL.md`, `lightspeed/skills/promoting-a-branch/SKILL.md`, `lightspeed/skills/working-an-issue/SKILL.md`
- Modify: `.gitignore`

- [ ] **Step 1: Apply path renames across the docs + remaining skills + plugin gitignore**

```bash
sed -i -E 's@\.lightspeed\.secrets\.json@.lightspeed/secrets.json@g; s@\.lightspeed\.json@.lightspeed/config.json@g; s@\.lightspeed-agent-rules\.md@.lightspeed/agent-rules.md@g' \
  lightspeed/references/lightspeed-setup.md lightspeed/references/adapter-contract.md \
  lightspeed/GUIDE.md lightspeed/README.md \
  lightspeed/skills/filing-issues/SKILL.md lightspeed/skills/triaging-issues/SKILL.md \
  lightspeed/skills/promoting-a-branch/SKILL.md lightspeed/skills/working-an-issue/SKILL.md \
  .gitignore
```
This also updates the `### .lightspeed.json` / `### .lightspeed.secrets.json` section headings in
`lightspeed-setup.md` (→ `### .lightspeed/config.json` / `### .lightspeed/secrets.json`) and the
plugin repo's `.gitignore` line.

- [ ] **Step 2: Tidy the two `lightspeed-setup.md` section headings**

After the sed, the headings read `### .lightspeed/config.json — committable` and
`### .lightspeed/secrets.json — gitignored`. Read those two heading lines and the sentence
immediately under each; if either now says "at the repo root" about the file, change it to "in the
`.lightspeed/` folder" so the prose matches the new location. (If the prose doesn't mention "repo
root" for these, leave it.)

- [ ] **Step 3: Global stale-reference sweep (the whole operational tree)**

```bash
grep -rn '\.lightspeed\.json\|\.lightspeed\.secrets\.json\|\.lightspeed-agent-rules\.md' \
  lightspeed/ test-rig/ .gitignore 2>/dev/null \
  | grep -v '/external/' | grep -v '/\.work/' \
  && echo "REVIEW: stale root-file references remain (fix them)" \
  || echo "✓ no stale references anywhere operational"
```
Expected: `✓ no stale references anywhere operational`. (Only `docs/superpowers/` specs/plans keep the old names, and they're excluded.)

- [ ] **Step 4: Commit**

```bash
git add lightspeed/references lightspeed/GUIDE.md lightspeed/README.md \
  lightspeed/skills/filing-issues/SKILL.md lightspeed/skills/triaging-issues/SKILL.md \
  lightspeed/skills/promoting-a-branch/SKILL.md lightspeed/skills/working-an-issue/SKILL.md .gitignore
git commit -m "docs: reference .lightspeed/ folder paths

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Live rig verification (end-to-end on the new paths)

Proves the dispatcher resolves `.work/.lightspeed/config.json` and the full workflow runs. **The
github half needs `$LIGHTSPEED_GH_TOKEN` staged** (repo-root `.env` or `test-rig/github/.env`); if
absent, run the forgejo half + the shellcheck sweep and hand the github half back to the user.

**Files:** (none — verification only)

- [ ] **Step 1: Forgejo rig smoke (docker; no token needed)**

```bash
cd test-rig/forgejo && ./up.sh && ./smoke.sh; rc=$?; ./down.sh; cd - >/dev/null
echo "forgejo smoke rc=$rc"
```
Expected: `up.sh` provisions and writes `.work/.lightspeed/{config,secrets}.json`; `smoke.sh`
prints `ALL 13 CHECKS PASSED`; `forgejo smoke rc=0`.

- [ ] **Step 2: GitHub rig smoke (needs the token)**

```bash
set -a; [ -f .env ] && . ./.env; set +a   # load LIGHTSPEED_GH_TOKEN if present at repo root
if [ -n "${LIGHTSPEED_GH_TOKEN:-}" ]; then
  cd test-rig/github && ./up.sh && ./smoke.sh; rc=$?; ./down.sh; cd - >/dev/null
  echo "github smoke rc=$rc"
else
  echo "no token staged — github live run deferred to the user"
fi
```
Expected (if token present): `passed=15 failed=0`; `github smoke rc=0`; teardown leaves the repo
clean. If no token: report the forgejo result and that the github run is deferred.

- [ ] **Step 3: Confirm the plugin working tree is clean**

```bash
git status --short
```
Expected: clean (the rigs write only into gitignored `.work/`). No commit — verification only;
record the pass/fail counts in the task hand-off.

---

## Done when

- The dispatcher resolves `.lightspeed/config.json` + `.lightspeed/secrets.json`; offline checks
  (config read, missing-config die path, worktree resolution, tracked-secrets warning) pass.
- Both rigs write/read `.work/.lightspeed/`; all rig scripts + the dispatcher are shellcheck-clean.
- `setting-up-a-repo` creates `.lightspeed/` and writes the files there (gitignoring
  `.lightspeed/secrets.json` first); `queue-batches` defaults agent-rules to `.lightspeed/agent-rules.md`.
- No stale `.lightspeed.json` / `.lightspeed.secrets.json` / `.lightspeed-agent-rules.md` anywhere
  operational (only `docs/superpowers/` historical docs retain them).
- Live forgejo smoke 13/13 (and github 15/15 if a token was available, else deferred).
- Ready to merge `feature/lightspeed-config-folder` → `develop` via `finishing-a-development-branch`.
```
