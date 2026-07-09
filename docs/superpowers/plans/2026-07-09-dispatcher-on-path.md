# Dispatcher on PATH via `bin/` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make lightspeed skills invoke the dispatcher as a bare `lightspeed`/`batch-manifest` command via the plugin's `bin/` dir (auto-added to PATH), eliminating the unsupported `$CLAUDE_PLUGIN_ROOT` dependency that fails in real projects (issue #45).

**Architecture:** Ship `lightspeed/bin/lightspeed` and `lightspeed/bin/batch-manifest` as thin `exec` wrappers to the existing `scripts/*` entrypoints (preserving adapter resolution). Rewrite all skill + doc invocations from `"$CLAUDE_PLUGIN_ROOT/scripts/<tool>"` to the bare command `<tool>`.

**Tech Stack:** Bash; markdown skills/docs. No new deps.

## Global Constraints

- Work happens in the worktree `.worktrees/45-dispatcher-on-path` (branch `feature/45-dispatcher-on-path`). All paths below are repo-relative to that worktree.
- Repo has `core.fileMode=false` — `chmod +x` does not persist in git. Persist the exec bit with `git update-index --chmod=+x <file>` (per the repo's exec-bit convention).
- The dev marketplace install is a **symlink** to the repo's `lightspeed/`, and `<install>/bin` is already on PATH — so new `bin/` files are callable in-session without reinstall.
- Do **not** touch `scripts/` or `adapters/` logic, or the dispatcher's config/token resolution.
- Leave historical material under `docs/**/plans/` and `docs/**/specs/` unchanged.
- Commit messages end with the repo's `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.

---

## File Structure

- Create: `lightspeed/bin/lightspeed` — PATH entrypoint; `exec`s `../scripts/lightspeed`.
- Create: `lightspeed/bin/batch-manifest` — PATH entrypoint; `exec`s `../scripts/batch-manifest`.
- Modify: 7 skills under `lightspeed/skills/*/SKILL.md` — bare-command invocations.
- Modify: `lightspeed/references/adapter-contract.md`, `lightspeed/references/lightspeed-setup.md`, `lightspeed/README.md` — bare-command invocations + Invocation prose.

---

## Task 1: `bin/` wrappers — the PATH entrypoints

**Files:**
- Create: `lightspeed/bin/lightspeed`
- Create: `lightspeed/bin/batch-manifest`

**Interfaces:**
- Consumes: existing `lightspeed/scripts/lightspeed` and `lightspeed/scripts/batch-manifest` (unchanged).
- Produces: two commands on PATH — `lightspeed <group> <verb> …` and `batch-manifest …` — behaving identically to the `scripts/` versions, with adapter resolution intact (dispatcher `$0` stays `…/scripts/lightspeed`).

- [ ] **Step 1: Reproduce the bug (RED) — the old pattern fails without the env var**

Run (from the worktree root):
```bash
env -u CLAUDE_PLUGIN_ROOT bash -c '"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues list --state open --limit 1'
```
Expected: FAIL — `exit 127`, `no such file or directory: /scripts/lightspeed`.

- [ ] **Step 2: Write `bin/lightspeed`**

Create `lightspeed/bin/lightspeed`:
```bash
#!/usr/bin/env bash
# PATH entrypoint for the lightspeed dispatcher (plugin bin/ is auto-added to PATH).
# Delegates to the real dispatcher so adapter resolution (relative to scripts/) is unchanged.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/../scripts/lightspeed" "$@"
```

- [ ] **Step 3: Write `bin/batch-manifest`**

Create `lightspeed/bin/batch-manifest`:
```bash
#!/usr/bin/env bash
# PATH entrypoint for the batch-manifest helper (plugin bin/ is auto-added to PATH).
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/../scripts/batch-manifest" "$@"
```

- [ ] **Step 4: Make both executable (on disk + persisted in git)**

Run:
```bash
chmod +x lightspeed/bin/lightspeed lightspeed/bin/batch-manifest
git add lightspeed/bin/lightspeed lightspeed/bin/batch-manifest
git update-index --chmod=+x lightspeed/bin/lightspeed lightspeed/bin/batch-manifest
git ls-files -s lightspeed/bin
```
Expected: both files listed with mode `100755`.

- [ ] **Step 5: Verify the wrapper behaves identically + adapters resolve (GREEN, unit)**

Run:
```bash
lightspeed/bin/lightspeed config '.code.stages[0].name'
```
Expected: prints `develop` (same as `lightspeed/scripts/lightspeed config …`).

Run (exercises an adapter through the wrapper):
```bash
lightspeed/bin/lightspeed issues list --state open --limit 1
```
Expected: a normal issue line (e.g. `44⇥…`), proving `adapters/` resolved relative to `scripts/`, not `bin/`.

- [ ] **Step 6: Verify bare command on PATH works WITHOUT the env var (GREEN, the bug)**

Run (fresh shell, env var explicitly unset):
```bash
env -u CLAUDE_PLUGIN_ROOT bash -lc 'command -v lightspeed && lightspeed issues list --state open --limit 1'
```
Expected: `command -v lightspeed` resolves to the install `bin/lightspeed` (symlinked to the repo), and the list succeeds — the exact call that failed in Step 1 now works as a bare command.

- [ ] **Step 7: Verify from a worktree cwd (cwd/PATH-independence)**

Run:
```bash
( cd .worktrees/45-dispatcher-on-path && env -u CLAUDE_PLUGIN_ROOT lightspeed config '.code.stages[0].name' )
```
Expected: prints `develop` — dispatcher finds the main repo's `.lightspeed/` via git-common-dir even though the worktree has none, and PATH is unaffected by cwd.

- [ ] **Step 8: Commit**

```bash
git add lightspeed/bin
git commit -m "feat(#45): add bin/ PATH entrypoints for dispatcher and batch-manifest

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Rewrite the 7 skills to bare commands

**Files:**
- Modify: `lightspeed/skills/working-an-issue/SKILL.md` (9)
- Modify: `lightspeed/skills/filing-issues/SKILL.md` (9)
- Modify: `lightspeed/skills/promoting-a-branch/SKILL.md` (11)
- Modify: `lightspeed/skills/promoting-branches/SKILL.md` (4)
- Modify: `lightspeed/skills/queue-batches/SKILL.md` (5)
- Modify: `lightspeed/skills/setting-up-a-repo/SKILL.md` (3)
- Modify: `lightspeed/skills/triaging-issues/SKILL.md` (2)

**Interfaces:**
- Consumes: the `lightspeed`/`batch-manifest` commands from Task 1.
- Produces: skills that invoke `lightspeed <group> <verb> …` and `batch-manifest …` with no `$CLAUDE_PLUGIN_ROOT`.

- [ ] **Step 1: Replace the two invocation tokens across all skills**

Run:
```bash
grep -rl 'CLAUDE_PLUGIN_ROOT' lightspeed/skills/ | while read -r f; do
  sed -i \
    -e 's#"\$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"#lightspeed#g' \
    -e 's#"\$CLAUDE_PLUGIN_ROOT/scripts/batch-manifest"#batch-manifest#g' \
    "$f"
done
```

- [ ] **Step 2: Verify no token survives and the results read correctly**

Run:
```bash
grep -rn 'CLAUDE_PLUGIN_ROOT' lightspeed/skills/ ; echo "exit=$?"
```
Expected: no matches, `exit=1`.

Run (spot-check the rewritten forms are sensible):
```bash
grep -rn -E '^\s*(BASE=.*)?(lightspeed|batch-manifest) ' lightspeed/skills/working-an-issue/SKILL.md | head
```
Expected: lines like `lightspeed issues get      --number N`, `BASE="$(lightspeed config '.code.stages[0].name')"` — bare commands, quoting intact.

- [ ] **Step 3: Commit**

```bash
git add lightspeed/skills
git commit -m "refactor(#45): skills call dispatcher as bare command via PATH

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Rewrite the 3 docs + Invocation prose, then final acceptance

**Files:**
- Modify: `lightspeed/references/adapter-contract.md` (2 + Invocation prose)
- Modify: `lightspeed/references/lightspeed-setup.md` (1)
- Modify: `lightspeed/README.md` (1)

**Interfaces:**
- Consumes: nothing new.
- Produces: docs whose invocation contract matches the code (bare command on PATH).

- [ ] **Step 1: Replace the invocation tokens in the three docs**

Run:
```bash
for f in lightspeed/references/adapter-contract.md lightspeed/references/lightspeed-setup.md lightspeed/README.md; do
  sed -i \
    -e 's#"\$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"#lightspeed#g' \
    -e 's#"\$CLAUDE_PLUGIN_ROOT/scripts/batch-manifest"#batch-manifest#g' \
    "$f"
done
```

- [ ] **Step 2: Rewrite the Invocation prose in `adapter-contract.md`**

Open `lightspeed/references/adapter-contract.md`, find the "## Invocation" section. Replace the sentence that reads (approximately):

> Skills call the dispatcher, never an adapter directly, resolving the plugin path via `$CLAUDE_PLUGIN_ROOT`:

with:

> Skills call the dispatcher, never an adapter directly. The plugin ships `bin/lightspeed` (and `bin/batch-manifest`); Claude Code adds the plugin's `bin/` directory to the Bash tool's `PATH`, so skills invoke it as a bare command — no `$CLAUDE_PLUGIN_ROOT` needed:

Ensure the adjacent code fence now reads:
```
lightspeed <group> <verb> [--flag value …]
```

- [ ] **Step 3: Scan the other two docs for stale plugin-path prose**

Run:
```bash
grep -n -iE 'CLAUDE_PLUGIN_ROOT|plugin path|scripts/lightspeed' lightspeed/references/lightspeed-setup.md lightspeed/README.md
```
Expected: no `CLAUDE_PLUGIN_ROOT`. If any surrounding prose still says "resolve the plugin path" or references `scripts/lightspeed`, reword it to "call the `lightspeed` command (on PATH via the plugin's `bin/`)". Make the minimal edit needed for correctness.

- [ ] **Step 4: Final grep gate across the whole plugin (acceptance)**

Run:
```bash
grep -rn 'CLAUDE_PLUGIN_ROOT' lightspeed/ ; echo "exit=$?"
```
Expected: no matches, `exit=1` (all skills + references + README clean; `scripts/`/`adapters/` never referenced it).

- [ ] **Step 5: End-to-end acceptance — a skill's calls work as bare commands with no env var**

Run (simulates a real project: env var unset, invoking the patterns a skill now prescribes):
```bash
env -u CLAUDE_PLUGIN_ROOT bash -lc '
  set -e
  lightspeed labels list >/dev/null && echo "labels ok"
  lightspeed issues list --state open --limit 1 >/dev/null && echo "issues ok"
'
```
Expected: `labels ok` and `issues ok` — both dispatcher paths that failed in the original report now succeed.

- [ ] **Step 6: Commit**

```bash
git add lightspeed/references lightspeed/README.md
git commit -m "docs(#45): document bare-command dispatcher invocation on PATH

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- `bin/` wrappers (spec §Design.1) → Task 1.
- Rewrite 42 `lightspeed` + 4 `batch-manifest` invocations (spec §Design.2) → Task 2 (skills) + Task 3 (docs).
- Invocation-contract doc update (spec §Design.3) → Task 3 Steps 2–3.
- Exec bit under `core.fileMode=false` (spec §Design.1) → Task 1 Step 4.
- Verification: unit (T1 S5), bare-command-on-PATH (T1 S6), worktree-independence (T1 S7), grep gate (T3 S4), real-behavior (T3 S5) → cover spec §Testing 1–5.

**Placeholder scan:** none — all steps carry exact commands, file contents, and expected output. The one prose edit (T3 S2) quotes the exact before/after text.

**Type consistency:** command names `lightspeed` and `batch-manifest` are used identically in the wrappers (Task 1), skills (Task 2), and docs (Task 3). Replacement tokens are identical across Task 2 and Task 3 sed commands.
