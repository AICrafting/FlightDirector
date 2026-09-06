---
name: working-an-issue
description: Use when starting, progressing, or finishing work on a specific issue — "let's work on #N", "start issue #N", "I'll take #N", "this is ready to test", "merge #N", "close out #N". Drives the per-issue branch → status-label → test → merge → finish lifecycle. Enforces: never merge to the trunk branch without explicit user approval.
---

# Working an Issue

Before the first command, follow [runtime preflight](../../references/runtime.md).

The per-issue lifecycle: one branch per issue, status labels that mirror reality on the board,
an explicit human gate before merging, and a finishing record (summary, token cost, model) left
on the issue when it's done.

All issue actions go through the **flight dispatcher**; branch/merge are git:

```
flight <group> <verb> [--flag value …]
```

The dispatcher resolves coordinates, token, and label names from `.flightdirector/config.json` — you pass
**status roles** (`in-progress`, `to-test`, …) and it maps them to this repo's actual label
names. Read `stages[0]` (the first integration branch) via:

```
flight config '.code.stages[0].name'
```

Merge mechanics (strategy, gate) are owned by `promoting-a-branch` — do not read single-value
merge config fields or hand-merge here. Config + verbs:
[flight-setup.md](../../references/flight-setup.md),
[adapter-contract.md](../../references/adapter-contract.md).

## Red flags — STOP

- **Never merge to the trunk branch without explicit user approval.** Not when tests pass, not
  when it "obviously works", not to "save a round-trip." The user tests and says merge. Until
  then, the branch stays unmerged. This is the rule the whole skill exists to protect.
- **One branch, one worktree, per issue.** All work for an issue lives on its own branch in its
  own worktree under `.worktrees/` (already gitignored) — never commit an issue's work straight
  onto the trunk branch. Each issue's own worktree is what enables working several issues in
  parallel; never reuse one worktree for two issues.
- **Never let a worktree path resolve against `$PWD`.** Anchor every `git worktree` call with
  `-C "$ROOT"` (below). The shell's working directory persists between commands, so if you are
  still inside the *previous* issue's worktree, a relative `.worktrees/<N>-<slug>` creates the
  new worktree **nested inside that one** — git permits nested worktrees and says nothing.
- **Every git command is `git -C "$WT" …` (or `git -C "$ROOT" …`). A bare `git` command is a
  bug, even if you think you're in the right directory.** Bind the issue's worktree path to
  `$WT` once, right after the worktree is created (Step 1), and pass `-C "$WT"` on *every*
  invocation — `status`, `add`, `commit`, `diff`, `log`, `stash`, `rev-parse`. Your shell's
  working directory persists across tool calls and you `cd` around constantly (into a
  subdirectory, another repo, a script dir); a later bare `git commit` then lands wherever you
  happen to be. Best case it errors; worst case it succeeds against the **wrong repository or
  the wrong branch** — committing the issue's work onto the trunk in the main checkout, which is
  precisely the red line the one-worktree-per-issue model exists to prevent. The only bare `git`
  allowed is the one-time bootstrap that *discovers* `$ROOT`
  (`git rev-parse --git-common-dir`); everything after it is anchored.
- **`git -C "$WT" <cmd> <path>` resolves `<path>` relative to `$WT`, not to your current
  directory.** That is the behavior you want, but it differs from a bare `git add` run from a
  subdirectory — so always pass **repo-relative** paths (`flight/skills/foo/SKILL.md`, not
  `SKILL.md`) to `add`, `checkout`, `diff`, and friends. Note too that `-C` does not protect
  non-git tools: `cd`-dependent scripts, test runners, and relative paths in editors still need
  an explicit absolute path or a `cd "$WT" && …` of their own.
- **Keep the board honest.** Every lifecycle transition updates the status label, so the issue's
  state always matches reality. `issues set-status` is atomic — it adds the new status and
  removes the others in one call, so the board can never show two states. Don't do the work and
  forget the transition.
- **Never start an issue without reading its comments.** The body is a snapshot; the thread is
  where scope corrections, "actually do X instead", decisions, and prior work-ledger entries
  live. Run `issues comments --number N` *before* creating the worktree, and when a comment
  contradicts the body, **the later comment wins** — work to it and say so. This is not optional
  and not a "if there's time" step: skipping it is how an agent builds the wrong thing well.

## Lifecycle

### 1. Start work

- **Read the issue *and its comments* first — required, not optional** (see the red flag above).
  The body alone can be stale — clarifications, scope corrections, and decisions often live in
  the comments. Fetch both before you plan anything:
  ```
  flight issues get      --number N
  flight issues comments --number N
  ```
  Then **state what you read** before moving on — e.g. "read #N: body + 3 comments, latest
  2026-09-06 by dave" (or "no comments") — so the user can see the thread was consulted. If a
  comment contradicts the body, the later comment wins — work to that, and say so explicitly.
- Determine the issue number `N` and derive a short slug from its title (lowercase, hyphens, no
  special characters) — e.g. issue #42 "Add login page" → slug `add-login-page`.
- Pick `feature` vs `bug` from the issue's type label or content.
- Create a worktree off `stages[0]` (the first integration branch):

```
# MAIN repo root (parent of the common git dir) — worktree-safe, matches the dispatcher.
# NEVER let this path come from $PWD: the shell's cwd persists across calls, so if you
# are still inside a previous issue's worktree a relative ".worktrees/…" silently nests
# the new worktree under it (git allows nested worktrees and prints no warning).
ROOT="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"

# stages[0] is the first integration branch; fork the feature worktree from it.
BASE="$(flight config '.code.stages[0].name')"
git -C "$ROOT" worktree add -b "feature/<N>-<slug>" ".worktrees/<N>-<slug>" "$BASE"

# Bind the issue's worktree ONCE — every later git command is `git -C "$WT" …`.
WT="$ROOT/.worktrees/<N>-<slug>"

flight issues set-status --number N --status in-progress
```

Do the work inside `$WT`, and drive git there **by path, not by `cd`**:

```
git -C "$WT" status
git -C "$WT" add flight/skills/<skill>/SKILL.md      # paths are relative to $WT
git -C "$WT" commit -m "feat(#N): …"
git -C "$WT" log --oneline -3
git -C "$WT" show --no-patch --format=%G? HEAD       # signature check, still anchored
```

`$WT` stays valid no matter where the shell has wandered, so a `cd` into a subdirectory or
another repo mid-task cannot silently redirect a commit. If you ever find yourself typing a bare
`git`, stop and re-issue it with `-C "$WT"`.

### 2. Ready for testing

When the work is done and waiting on the user to verify, hand the board over and tell the user
it's ready to test, on which branch:

```
flight issues set-status --number N --status to-test
```

(One call — it drops `in-progress` and adds `to-test` atomically.)

### 3. The merge gate — wait for confirmation

**Do not merge until the user has tested and explicitly says to merge.** Leave the issue at
`to-test` and stop. If unsure whether you have approval, you don't — ask.

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
   flight issues comment --number N --body-file "$SCRATCH/done.md"
   ```
2. **Ensure and add the `model/<primary>` label** for the main model used — the one with the most
   tokens/cost in the log when available, else the model you ran. Normalize to the stable model
   family (`gpt-5.6-sol` → `sol`, `claude-opus-4.7` → `opus`). For an unknown family, lowercase
   and replace non-alphanumeric runs with hyphens rather than guessing. Create the label lazily;
   `labels ensure` preserves an existing label and safely handles parallel creators. Later
   episodes may add another `model/*`. See `model/*` in
   [default-labels.md](../../references/default-labels.md):
   ```
   flight labels ensure --name model/sol --color "#d97757" \
     --description "Issue was worked on using Sol"
   flight issues label-add --number N --label model/sol
   ```
3. **Promote the branch** `feature/<N>-<slug>` → `stages[0]` using `promoting-a-branch` (invoke
   the skill in this session). It applies the hop's merge strategy/gate **and** drives the
   issue's status/close from `stages[0]`'s `issueStatus`/`closesIssues` (Step 5 of that skill):
   a single-trunk repo's terminal `stages[0]` closes the issue; in a multi-stage pipeline it just
   sets the stage's status and the issue stays open until a closing stage. **Do not** set status
   or close the issue here — that is stage-driven now, and double-handling it makes the board lie.
4. **Remove the issue's worktree** once merged (anchored to `$ROOT`, so it works from anywhere —
   including from inside the worktree being removed):
   ```
   ROOT="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"
   git -C "$ROOT" worktree remove ".worktrees/<N>-<slug>"
   ```

## Common mistakes

- Merging because tests passed, without the user's explicit go-ahead. The gate is the user, not
  the test result.
- Doing the work but leaving the status at `in-progress` (or never setting it) — the board now
  lies. Transition every time.
- Promoting without leaving the work-ledger comment (summary / cost / tokens / model) — that
  per-episode record is the auditable point of the whole workflow; the merge is not the record.
- Manually closing or relabeling the issue on merge — `working-an-issue` no longer closes.
  Status and close are driven by the target stage in `promoting-a-branch` (Step 5). Setting them
  here too makes the board show a state the pipeline didn't ask for.
- **Orphaned worktrees** — if a promotion is abandoned, remove the worktree
  (`git -C "$ROOT" worktree remove --force ".worktrees/<N>-<slug>"`) rather than leaving it
  dangling. If you abandon the work earlier (before promotion), also clear the issue's status
  label (`issues clear-status --number N`) after removing the worktree so the board doesn't lie.
- Hand-merging instead of delegating to `promoting-a-branch` — the merge strategy and any gate
  checks live there, not here.
- Running a bare `git add`/`git commit`/`git status` because "I'm in the worktree." You may not
  be — the shell's cwd persists between tool calls. Anchor with `git -C "$WT"` every time; the
  recovery (notice, revert, redo with `-C`) costs far more than the eight characters.
