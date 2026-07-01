# lightspeed — User Guide

Run your whole issue-and-code workflow — file, triage, work, promote — from inside a Claude
Code session, without tabbing over to your forge's web UI. This guide covers **why** you'd want
it, **how to install** it, and **how to use** it, with a full worked example.

> New to the plugin? Start here. For the at-a-glance skill list and the config schema, see the
> [README](README.md), [lightspeed-setup.md](references/lightspeed-setup.md), and
> [adapter-contract.md](references/adapter-contract.md).

---

## Why lightspeed?

If you develop with Claude Code against a self-hosted **Forgejo** repo, your issues and your
code already live in two places you keep switching between. lightspeed pulls the whole lifecycle
into the session:

- **File issues without leaving your work.** `/issue the export button doesn't disable mid-download`
  becomes a well-formed, **de-duplicated**, labeled issue — drafted from what you actually
  discussed in the session, not a one-line stub.
- **Always know what to pick up next.** Ask "what should I work on?" and get a filtered pick-list
  of genuinely workable issues (things already in progress, in review, or in QA are hidden).
- **An opinionated lifecycle with a human gate.** Each issue runs through branch → in-progress →
  ready-to-test → merge → done, and **Claude never merges without your explicit go-ahead.**
- **Parallel work via git worktrees.** Each issue is developed in its own
  `.worktrees/<N>-<slug>` worktree, so you can have several in flight without stashing or
  branch-juggling.
- **A promotion pipeline that matches how you ship.** Define your stages once
  (`feature → develop → qa → main`), and the same "promote" command advances a branch one hop —
  direct-merging where you want speed, opening a PR + watching CI where you want a gate.
- **No MCP server, no vendor lock-in.** Everything runs through a small `curl` + `jq` adapter
  behind a backend-agnostic contract (Forgejo today; other backends can slot in later). Your
  only secret is a **per-repo, least-privilege** API token.

---

## What you need

- **Claude Code** (the plugin runs as Claude Code skills).
- **`curl`** and **`jq`** on your `PATH`.
- A **Forgejo** instance and a repo you can push to.
- A **per-repo API token** with just the two scopes the skills use: `write:repository` and
  `write:issue` (`write:issue` also covers labels). Create one in Forgejo under
  *Settings → Applications → Generate New Token* — scope it to what you need, not an all-orgs
  admin token. These two work with a token restricted to a single repository; don't add
  `write:misc` (the skills don't use it, and Forgejo won't allow it on a single-repo token).
  (Why per-repo? A misfire then fails with a hard `403` instead of writing to the wrong place.)

---

## Install

1. Add the marketplace that ships lightspeed, then install the plugin:

   ```
   /plugin marketplace add <this-repo> (eg: https://hostname/owner/repo.git [.git is required]) 
   /plugin install lightspeed@cerebralgardens
   ```

2. That's it — no server to run. The skills activate automatically when you say things that match
   them (see the workflow below).

---

## First-time setup (once per repo)

From inside the repo, tell Claude:

> **"set up lightspeed for this repo"**  (or *"bootstrap labels"*)

That triggers **`setting-up-a-repo`**, which walks you through setup:

1. **Coordinates** — it reads your git remote to propose the `owner/repo` and the API base, and
   asks you to confirm.
2. **Token** — it asks for the per-repo token, adds `.lightspeed/secrets.json` **and**
   `.worktrees/` to your `.gitignore`, and writes the token to the gitignored secrets file.
3. **Pipeline preset** — it asks which stage pipeline you want:
   - **(a) Simple** — `develop → main`
   - **(b) Multi-stage** — `develop → qa → main`
   - **(c) Advanced** — a custom ordered set of stages, or hand-edit afterward.
4. **Labels** — it reconciles a default label taxonomy against what your repo already has,
   *adopting your existing names* (if you already call a state `status/qa`, it keeps that),
   shows you a plan, and creates only what's missing.

When it's done you'll have two files in the `.lightspeed/` folder: a committable **`.lightspeed/config.json`**
(coordinates, the `stages` pipeline, and your label names) and a gitignored
**`.lightspeed/secrets.json`** (the token). Every other skill reads `.lightspeed/config.json`, so they
all speak your repo's conventions.

---

## The workflow at a glance

| You say… | Skill | What happens |
|---|---|---|
| `/issue …`, "file an issue", "log a bug" | **filing-issues** | De-dupe check → draft → label → create |
| "what should I work on?", "any quick wins?" | **triaging-issues** | A filtered pick-list of workable issues |
| "let's work on #N", "this is ready to test", "merge #N" | **working-an-issue** | Worktree → status labels → human merge gate → finish |
| "promote this", "promote develop to main" | **promoting-a-branch** | Advance the branch one stage (direct merge or PR + CI) |
| `/queue-batches NxM`, "work N issues in parallel", "batch these" | **queue-batches** | Dispatch N background agents × M issues each; isolated worktrees (zones), stop at to-test, then a serial promoting-a-branch hand-off |
| "set up lightspeed", "bootstrap labels" | **setting-up-a-repo** | First-run setup (above) |

You never type the underlying commands — you talk to Claude, and the skills drive the forge for
you.

---

## A worked example

Say you're mid-session and notice a bug. Here's the whole lifecycle.

### 1. File it

> **You:** `/issue the export button stays clickable while a download is already running`

**filing-issues** scans the conversation for specifics, checks open issues so it doesn't create a
duplicate, drafts a clear title + body, suggests 1–3 labels, and creates the issue:

> **Claude:** *Created #42: "Disable the export button while a download is in progress" — labeled `bug`, `ux`.*

### 2. Decide what to do next

> **You:** "what should I work on?"

**triaging-issues** lists the open, *workable* issues (anything already in progress, in review, or
in QA is filtered out) so you can pick:

> **Claude:** *Quick wins: #42 export button (bug, ux), #38 tooltip clipping (ux). Larger: #31 bulk export. Recommend #42 — small and user-visible.*

### 3. Work it

> **You:** "let's work on #42"

**working-an-issue** creates a dedicated worktree off your first stage and flips the board:

- `git worktree add .worktrees/42-export-button -b feature/42-export-button develop`
- sets the issue to **`status/in progress`**

You and Claude make the change inside that worktree. Because it's a separate worktree, you could
start a *second* issue in parallel without disturbing this one.

> **You:** "this is ready to test"

It moves the issue to **`status/to test`** and tells you which branch to check. You test it.

> **You:** "looks good, merge #42"

This is the **gate** — Claude only proceeds now that you've said so. It leaves a **work-ledger**
record on the issue (a summary + token cost + which model did the work — one entry per chunk of
work, so later follow-ups and QA each add their own), adds the `model/…` label, hands the merge to
**promoting-a-branch** (feature → `develop`), and removes the worktree. It does **not** close
**#42** here: an issue's status label and whether it closes are driven by the **stage** it lands
in (see step 4).

### 4. Promote toward release

Later, with several issues integrated on `develop`, you ship them upward:

> **You:** "promote develop to main"

**promoting-a-branch** advances one hop. If that hop is a PR stage, it drafts a **test plan for
each resolved issue** (and stops if it can't write one — usually a sign the feature isn't
reachable), opens the pull request, and **watches CI**, telling you when it's green and ready to
merge. As the branch advances, **promoting-a-branch** sets each stage's configured `issueStatus`
on the linked issues and closes them only when they reach a stage that closes — the terminal stage
(`main`) by default, adjustable per stage with `closesIssues`. So a linked issue stays open and
visible (e.g. `status/to test`, then `status/qa`) as it climbs the pipeline, and closes when it
lands in the final stage.

**Choosing how a PR merges.** On a `pr` hop you can pick the merge strategy — tell Claude
"promote to main, squash" (or pass `--strategy`):

- `merge` *(default)* — a merge commit; keeps the branch's individual commits on the target.
- `squash` — collapses the whole branch into a single commit on the target.
- `rebase` — replays the branch's commits onto the target with no merge commit.

If you don't say, it's `merge`. (This applies to `pr` hops only — a `direct` hop like
feature → `develop` always merges with `--no-ff` and has no strategy option.)

That's the full loop: **file → triage → work (in a worktree, behind a merge gate) → promote up
the pipeline** — all without leaving the session.

When you have several independent issues to tackle at once, `/queue-batches NxM` scales this loop
horizontally: N background agents each work M issues sequentially in isolated worktrees (zones),
stopping at the to-test gate; you then ship the branches serially via promoting-a-branch.

---

## Where your config lives

- **`.lightspeed/config.json`** (commit it) — backend + coordinates, the `stages` pipeline, and your
  role→label-name map. See [lightspeed-setup.md](references/lightspeed-setup.md) for the schema.
- **`.lightspeed/secrets.json`** (gitignored) — your API token(s). If lightspeed ever finds this
  file tracked by git, it warns you on every run.

Want a different pipeline later? Edit `code.stages` in `.lightspeed/config.json` — e.g. add a `qa`
stage between `develop` and `main`. The skills pick it up immediately.

---

## Tips

- **Issues elsewhere than code?** `.lightspeed/config.json` has two axes — `code` and `issues` — so you
  can point issues at a different repo (or, in future, a different backend) while code stays put.
  By default `issues` inherits `code`.
- **The merge gate is real.** If you want something merged, say so explicitly — "merge #N" /
  "promote …". Claude will leave work at *ready-to-test* and stop otherwise.
- **Re-running setup is safe.** `setting-up-a-repo` is idempotent — it only adds what's
  missing and never renames or deletes your existing labels.
