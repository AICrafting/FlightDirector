# Flight — User Guide

Run your whole issue-and-code workflow — file, triage, work, promote — from inside Claude Code
or Codex, without tabbing over to your forge's web UI. This guide covers **why** you'd want
it, **how to install** it, and **how to use** it, with a full worked example.

> New to the plugin? Start here. For the at-a-glance skill list and the config schema, see the
> [README](README.md), [flight-setup.md](references/flight-setup.md),
> [adapter-contract.md](references/adapter-contract.md), and — for per-backend config,
> token-creation URLs, and minimum scopes — [backends.md](references/backends.md).

---

## Why flight?

If you develop with Claude Code or Codex against a repo on **Forgejo/Gitea, GitHub, or GitLab**,
your issues and your code already live in two places you keep switching between. flight pulls
the whole lifecycle into the session:

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
  behind a backend-agnostic contract — the backend is one field in your config. Forgejo/Gitea,
  GitHub, and GitLab have full parity (issues, labels, PRs/MRs, CI); Jira can serve the issues
  axis alongside a git host. See [backends.md](references/backends.md) for the current list.
  Your only secret is a **per-repo, least-privilege** API token.

---

## What you need

- **Claude Code or Codex** (the same package supplies skills to both harnesses).
- **`curl`** and **`jq`** on your `PATH`.
- A repo you can push to on a **supported backend** — Forgejo/Gitea (self-hosted), GitHub, or
  GitLab (gitlab.com or self-managed). Issues can optionally live in Jira instead.
- A **per-repo, least-privilege API token** for that backend. Scope it to the one repository and
  to just what the skills call — never an all-orgs admin token. (Why per-repo? A misfire then
  fails with a hard `403` instead of writing to the wrong place.) Where to create it and the
  minimum scopes, per backend:

  | Backend | Create the token at | Minimum |
  |---|---|---|
  | Forgejo/Gitea | *Settings → Applications → Generate New Token*, restricted to the repo | `write:repository` + `write:issue` (no `write:misc`) |
  | GitHub | a fine-grained PAT scoped to the repo | Contents, Issues, Pull requests: read/write; Actions: read (for `ci`) |
  | GitLab | a project access token | `api` scope |
  | Jira (issues only) | an Atlassian API token | least privilege via the account's project role |

  Full details, including classic-token equivalents and fine-grained GitLab permissions, are in
  [backends.md](references/backends.md).

---

## Install in Claude Code

1. Add the `flightdirector` marketplace (hosted at <https://github.com/AICrafting/FlightDirector>),
   then install the plugin:

   ```
   /plugin marketplace add https://github.com/AICrafting/FlightDirector.git
   /plugin install flight@flightdirector
   ```

   The GitHub shorthand `/plugin marketplace add AICrafting/FlightDirector` is equivalent.

2. That's it — no server to run. The skills activate automatically when you say things that match
   them (see the workflow below).

## Install in Codex

1. Add the same marketplace, then install the plugin — from the shell:

   ```
   codex plugin marketplace add https://github.com/AICrafting/FlightDirector.git
   codex plugin add flight@flightdirector
   ```

   or interactively: open `/plugins` inside Codex, switch to the `flightdirector` marketplace
   tab, and install *Flight*. (`codex plugin marketplace add AICrafting/FlightDirector` and a
   local checkout path both work as the source too.)

2. **Start a new session** — bundled skills become available at session start, not mid-session.

3. Invoke skills by name with `$filing-issues`, `$working-an-issue`, `$queue-batches`, …, or just
   describe what you want — the same natural-language triggers work in both harnesses.

Allow the configured forge hostname when Codex requests network permission. Parallel queues
(`queue-batches`) require Codex multi-agent support; every other workflow runs without it.

---

## First-time setup (once per repo)

From inside the repo, tell Claude:

> **"set up flight for this repo"**  (or *"bootstrap labels"*)

That triggers **`setting-up-a-repo`**, which walks you through setup:

1. **Coordinates** — it reads your git remote to detect the backend (Forgejo/Gitea, GitHub, or
   GitLab), propose the `owner/repo` and the API base, and asks you to confirm.
2. **Token** — it asks for the per-repo token, adds `.flightdirector/secrets*` **and**
   `.worktrees/` to your `.gitignore`, and writes the token to the gitignored secrets file.
3. **Pipeline preset** — it asks which stage pipeline you want:
   - **(a) Simple** — `develop → main`
   - **(b) Multi-stage** — `develop → qa → main`
   - **(c) Advanced** — a custom ordered set of stages, or hand-edit afterward.
4. **Labels** — it reconciles a default label taxonomy against what your repo already has,
   *adopting your existing names* (if you already call a state `status/qa`, it keeps that),
   shows you a plan, and creates only what's missing.

When it's done you'll have two files in the `.flightdirector/` folder: a committable **`.flightdirector/config.json`**
(coordinates, the `stages` pipeline, and your label names) and a gitignored
**`.flightdirector/secrets.json`** (the token). Every other skill reads `.flightdirector/config.json`, so they
all speak your repo's conventions.

---

## The workflow at a glance

| You say… | Skill | What happens |
|---|---|---|
| `/issue …`, "file an issue", "log a bug" | **filing-issues** | De-dupe check → draft → label → create |
| "what should I work on?", "any quick wins?" | **triaging-issues** | A filtered pick-list of workable issues |
| "let's work on #N", "this is ready to test", "merge #N" | **working-an-issue** | Worktree → status labels → human merge gate → finish |
| "promote this", "promote develop to main" | **promoting-a-branch** | Advance the branch one stage (direct merge or PR + CI) |
| "promote each zone", "promote issues 18, 93, 12", "batch promote" | **promoting-branches** | Promote a selected group of first-hop feature branches into `stages[0]` at once (direct → N merges; pr → one PR per group) |
| `/queue-batches NxM`, "work N issues in parallel", "batch these" | **queue-batches** | Dispatch N background agents × M issues each; isolated worktrees (zones), stop at to-test, then a batch hand-off to promoting-branches |
| "set up flight", "bootstrap labels" | **setting-up-a-repo** | First-run setup (above) |

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
stopping at the to-test gate; you then ship the batch with **promoting-branches** (or hand-pick
branches one at a time with promoting-a-branch).

---

## Where your config lives

- **`.flightdirector/config.json`** (commit it) — backend + coordinates, the `stages` pipeline, and your
  role→label-name map. See [flight-setup.md](references/flight-setup.md) for the schema.
- **`.flightdirector/secrets.json`** (gitignored) — your API token(s). If flight ever finds this
  file tracked by git, it warns you on every run.

Want a different pipeline later? Edit `code.stages` in `.flightdirector/config.json` — e.g. add a `qa`
stage between `develop` and `main`. The skills pick it up immediately. For worked setups at 1, 2, 3,
and 4 hops — with contrasting `direct`/`pr`, merge-strategy, and issue-status configs, plus how
batch-promote differs by first-hop strategy — see
[example-flows.md](references/example-flows.md).

---

## Tips

- **Issues elsewhere than code?** `.flightdirector/config.json` has two axes — `code` and `issues` — so you
  can point issues at a different repo (or, in future, a different backend) while code stays put.
  By default `issues` inherits `code`.
- **The merge gate is real.** If you want something merged, say so explicitly — "merge #N" /
  "promote …". Claude will leave work at *ready-to-test* and stop otherwise.
- **Re-running setup is safe.** `setting-up-a-repo` is idempotent — it only adds what's
  missing and never renames or deletes your existing labels.
