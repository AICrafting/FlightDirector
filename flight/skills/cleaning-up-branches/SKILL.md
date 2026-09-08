---
name: cleaning-up-branches
description: Use when clearing out branches whose work has already shipped — "clean up the branches", "delete merged branches", "prune old feature branches", "what branches can go", "tidy up the worktrees", "origin is full of old feature branches". Finds feature/bugfix/release branches already merged into a stage, cross-checks each against its issue, previews them, and deletes the local ref, the remote ref, and the leftover worktree only on your go-ahead.
---

# Cleaning Up Branches

Before the first command, follow [runtime preflight](../../references/runtime.md).

`working-an-issue` and `promoting-branches` remove an issue's **worktree** when it merges;
nothing removes the **branch**. So every worked issue leaves a `feature/<N>-<slug>` on origin
and usually a local ref, and `release/*` fold branches pile up the same way. This skill finds
the ones whose work has demonstrably landed and — after a preview and your go-ahead — deletes
them.

All backend access is through the dispatcher; the pipeline and the candidate patterns live in
`.flightdirector/config.json`. See [flight-setup.md](../../references/flight-setup.md) and
[adapter-contract.md](../../references/adapter-contract.md).

## Red flags — STOP

- **Deleting a branch is a red-line git write.** It needs the same explicit go-ahead a merge
  needs. Show the preview table, wait for the user to say go, and delete **only what the table
  listed**. Never fold "find them" and "delete them" into one uninterrupted run.
- **`git branch -d`, never `-D`.** `-d` is git's own independent merged check, and it is the
  last line of defence behind our verdict. If git refuses, our verdict was wrong — report the
  refusal and move on; do not reach for `-D` to make the refusal go away.
- **`git worktree remove`, never `--force`.** A worktree git refuses to remove is dirty or
  locked, which means it holds work nobody has looked at. That is a finding to report, not an
  obstacle to clear.
- **Remote deletion is opt-in, every time.** `prune` touches origin only under `--remote`, and
  only after the user has agreed to *that* specifically. A local ref is one `git fetch` from
  coming back; a deleted remote branch is gone for everyone.
- **An issue whose status disagrees with the branch is a board-lies signal, not a cleanup
  target.** If the branch says merged into `develop` but the issue is still `status/in
  progress` (or open with no status at all), something in the workflow was skipped. Skip the
  branch, flag it, and let the user decide — never "fix" it by deleting the evidence.
- **Every git command is `git -C "$MAIN" …`. A bare `git` command is a bug, even if you think
  you're in the right directory.** This skill runs against the *main* checkout while the
  session may be sitting in any linked worktree, and it deletes things. Bind `$MAIN` in Step 1
  and anchor everything after it. `flight branches` anchors itself the same way, so it behaves
  identically from a worktree — but your own inspection commands do not.
- **Never touch a stage branch, `archived/*`, or a branch checked out outside `.worktrees/`.**
  `flight branches` already refuses all three; don't work around it with hand-rolled `git
  branch -d` calls.

## Step 1: Bind the checkout and read the pipeline

The `git rev-parse --git-common-dir` below is the single permitted bare `git` — the bootstrap
that discovers the path. Everything after it uses `-C`.

```
# $MAIN — the main checkout (root of the shared git object store). Branch refs and the
# worktree list are shared, so this is the one place cleanup happens.
MAIN="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"

flight config '.code.stages'                    # the pipeline these branches merged into
flight config '.code.branches.patterns // ["feature/*","bugfix/*","release/*"]'
```

`code.branches.patterns` names which branches are even candidates. Absent, the defaults above
apply. A repo with another convention (`feat/*`, `fix/*`) sets the key rather than having you
pass `--pattern` every time.

## Step 2: Refresh the picture, then list candidates

A stale remote-tracking picture is the one way this goes wrong in the dangerous direction, so
`flight branches list` runs `git fetch --prune origin` itself before it looks at anything. Let
it — pass `--no-fetch` only when you are deliberately offline, and say so in the report.

```
flight branches list                            # every configured stage
flight branches list --merged-into develop      # or scope it to one stage
```

Each row is `branch⇥where⇥merged-into⇥pr⇥issue⇥worktree`:

| Column | Meaning |
|---|---|
| `branch` | the branch name |
| `where` | `local`, `remote`, or `local+remote` |
| `merged-into` | the stage its work landed in |
| `pr` | the merged PR number when the evidence came from the backend, else `-` |
| `issue` | the `#N` parsed out of `<prefix>/<N>-<slug>`, else `-` |
| `worktree` | the `.worktrees/` path still holding it, else `-` |

**Merged** means one of two things, and the `pr` column says which:

1. The branch tip is an **ancestor** of a stage — a `direct` hop, or a `pr` hop merged with
   `merge`. This is the common case and needs no backend call.
2. The backend reports a **merged PR whose head was this branch**, based into a configured
   stage (`pr list --state merged --head <branch>`). A `squash` or `rebase` hop rewrites the
   commits, so the tip is *never* an ancestor even though the work shipped; without this
   fallback every squash-merged branch would look unmerged forever.

Anything else is simply absent from the list. Unmerged branches are not this skill's business.

## Step 3: Cross-check each candidate against its issue

A branch can be merged while its issue was never moved along — a promotion that half-ran, a
hand-merge, a status label set by hand. The branch is then *evidence* of a workflow gap, and
deleting it destroys that evidence. So for every row with an issue number, confirm the issue
is **at or past** the `issueStatus` of the stage it merged into, or **closed**.

Resolve the accepted set once, with a bounded number of calls rather than one per branch. For
the merged stage at index `<i>` and every stage after it, read the status role and its label
name, then list what carries it:

```
flight config '.code.stages[<i>].issueStatus // empty'      # e.g. to-test
flight config '.labels.status["to-test"]'                   # e.g. "status/to test"

flight issues list --state closed --limit 200               # closed → past everything
flight issues list --state open --label "status/to test" --limit 200
flight issues list --state open --label "status/qa"    --limit 200   # …and each later stage
```

Then judge each row:

- Issue is **closed**, or **open carrying the merged stage's status or any later stage's** →
  the branch is a genuine leftover. Keep it in the delete set.
- Issue is **open with an earlier status** (`status/in progress`, `status/blocked`) or **no
  status at all** → **skip it and flag it.** Say plainly which issue and what it says, e.g.
  *"`feature/71-…` is merged into develop but #71 is still `status/in progress` — the promotion
  never relabelled it. Skipping; fix the board first."*
- Issue number is present but the issue **doesn't exist** (renumbered repo, hand-named branch)
  → skip and flag.
- **No issue number** (`-`) — a `release/*` fold branch, or a hand-named branch. There is
  nothing to cross-check, so say so and let the user decide that row on its own.

This step is the whole reason the skill exists rather than a one-liner. `flight branches` can
tell you what git and the backend believe; only this comparison notices when they disagree.

## Step 4: Preview, then wait

Show one table of what would be deleted and one list of what was skipped and why. `prune` with
none of `--local` / `--remote` / `--worktrees` is exactly this preview — it deletes nothing and
says so on stderr:

```
flight branches prune                           # preview only; nothing is written
```

Present it, then **stop and ask**. Make three things explicit in the question, because they are
three different amounts of damage:

- how many **local** refs go,
- how many **remote** refs go (name this separately — it is the irreversible one),
- how many **worktrees** get removed, and their paths.

Do not proceed on an ambiguous answer. "Yeah clean it up" is a go-ahead for the local refs and
worktrees; deleting on origin needs the user to have agreed to the remote specifically.

## Step 5: Delete what was agreed

`prune` deletes only the classes you name, and only the branches you name. Pass the reviewed
set explicitly with `--branch` (repeatable) so a branch that appeared between the preview and
the go-ahead cannot ride along:

```
flight branches prune --branch feature/71-widget --branch feature/74-gadget \
    --worktrees --local
```

Add `--remote` only if the user agreed to the remote:

```
flight branches prune --branch feature/71-widget --remote
```

Order is fixed and not yours to change: **worktree → local ref → remote ref**. Git refuses to
delete a branch that is checked out anywhere, so the worktree has to go first; `prune` does
this for you, and reports `skip` with the reason when it can't.

Each action prints one TSV line — `action⇥branch⇥detail`:

| Action | Meaning |
|---|---|
| `remove-worktree` | the `.worktrees/` entry was removed |
| `delete-local` | `git branch -d` succeeded |
| `delete-remote` | `git push origin --delete` succeeded |
| `would-*` | preview only (a bare `prune`, or `--dry-run`); nothing was written |
| `skip` | deliberately left alone; the detail says why |

`prune` exits non-zero if anything was skipped for a *failure* (a dirty worktree, a `git branch
-d` refusal, a rejected push). Read that as "report it", not "retry harder".

## Step 6: Report

Say what went and what stayed:

- deleted: branch, which stage it had merged into, and which of local/remote/worktree went;
- skipped for a board mismatch: the branch, the issue, and what the issue actually says — this
  is the useful output, so don't bury it;
- skipped for a git refusal: the branch and the exact reason, plus what the user would have to
  do by hand;
- anything with no issue number that the user chose to keep.

If the board-mismatch list is non-empty, name the pattern rather than just the rows — several
issues stuck at `status/in progress` behind merged branches usually means one promotion run
died halfway, and that is worth an issue of its own.

## Common mistakes

- Running the preview and the deletion as one uninterrupted step. The go-ahead is the point.
- Deleting on origin because "clean up the branches" sounded like it covered everything.
  `--remote` is a separate consent; without it the branches come back on the next clone and
  nothing is lost.
- Reaching for `git branch -D` when `-d` refuses. The refusal *is* the signal — it means git
  disagrees that the work is merged, which is precisely the case where deleting is unsafe.
- `git worktree remove --force` on a worktree that wouldn't come off cleanly. That silently
  discards uncommitted work; report the path instead.
- Skipping Step 3 because the ancestry check "already proves" the work merged. It proves the
  *code* merged; it says nothing about whether the issue was ever moved along, and a merged
  branch behind a `status/in progress` issue is a bug report about the workflow.
- Treating a branch with no issue number as a free deletion. `release/*` fold branches often
  are safe, but "no cross-check was possible" is something the user should hear, not something
  to quietly resolve in favour of deleting.
- Running a bare `git branch -d` / `git push origin --delete` instead of `flight branches
  prune`. The protections (stage names, `archived/*`, checkouts outside `.worktrees/`, no-force)
  live in the verb; hand-rolling the command opts out of all of them.
- Pruning against a stale picture. Let `list` do its `fetch --prune`; `--no-fetch` is for a
  deliberately offline run, and it belongs in the report when you use it.
