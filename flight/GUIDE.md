# Flight — User Guide

Run your whole issue-and-code workflow — file, triage, work, promote — from inside Claude Code
or Codex, without tabbing over to your forge's web UI. This guide covers **why** you'd want
it, **how to install** it, and **how to use** it, with a full worked example.

> New to the plugin? Start here. For the at-a-glance skill list and the config schema, see the
> [README](README.md), [flight-setup.md](references/flight-setup.md),
> [adapter-contract.md](references/adapter-contract.md), and — for per-backend config,
> token-creation URLs, and minimum scopes — [backends.md](references/backends.md). Building a
> tool on top of flight? The `--json` contract is [json-output.md](references/json-output.md).

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
  `.worktrees/<ref>-<N>-<slug>` worktree (e.g. `.worktrees/fj-42-export-button`), so you can
  have several in flight without stashing or branch-juggling.
- **A promotion pipeline that matches how you ship.** Define your stages once
  (`feature → develop → qa → main`), and the same "promote" command advances a branch one hop —
  direct-merging where you want speed, opening a PR + watching CI where you want a gate.
- **No MCP server, no vendor lock-in.** Everything runs through a small `curl` + `jq` adapter
  behind a backend-agnostic contract — the backend is one field in your config. Forgejo/Gitea,
  GitHub, and GitLab have full parity (issues, labels, PRs/MRs, CI); Jira can be an issue
  tracker alongside a git host, and one repo can have several trackers (a private backlog and a
  public intake, say). See [backends.md](references/backends.md) for the current list.
  Your only secrets are **per-repo, least-privilege** API tokens.

---

## What you need

- **Claude Code or Codex** (the same package supplies skills to both harnesses).
- **Linux, macOS, or Windows.** Stock macOS (bash 3.2, BSD tools) and Windows via Git Bash /
  MSYS both work as shipped and are tested in CI on every change, alongside Linux. On Windows a
  native `jq.exe` from winget, scoop or choco is fine; keep `/usr/bin` ahead of `System32` on
  `PATH`, which an interactive Git Bash already does.
- **`curl`** and **`jq`** on your `PATH` (plus **`python3`**, standard library only, if you turn
  on the optional [cost ledger](#cost-ledger-optional)).
- A repo you can push to on a **supported backend** — Forgejo/Gitea (self-hosted), GitHub, or
  GitLab (gitlab.com or self-managed). Issues can live on the same repo, in another repo, in
  Jira — or in several of those at once.
- A **per-repo, least-privilege API token** for that backend. Scope it to the one repository and
  to just what the skills call — never an all-orgs admin token. (Why per-repo? A misfire then
  fails with a hard `403` instead of writing to the wrong place, and an agent steered by a
  prompt injection in an issue or comment can't reach your other repos. That's also why GitHub
  uses its own token rather than your `gh` CLI login; see
  [backends.md](references/backends.md#github-full-parity).) Where to create it and the
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

1. **Coordinates** — it reads your git remote to detect the code backend (Forgejo/Gitea, GitHub,
   or GitLab), propose the `owner/repo` and the API base, and asks you to confirm.
2. **Token** — it asks for the per-repo token, adds `.flightdirector/secrets*`,
   `.flightdirector/config.local.json`, `.flightdirector/batches/` **and** `.worktrees/` to your
   `.gitignore`, writes the token to the gitignored secrets file, and verifies it with
   `flight auth check` (identity, repo access, per-capability permissions, expiry).
3. **Pipeline preset** — it asks which stage pipeline you want:
   - **(a) Simple** — `develop → main`
   - **(b) Multi-stage** — `develop → qa → main`
   - **(c) Advanced** — a custom ordered set of stages, or hand-edit afterward.
4. **Preferences** — the worker models for parallel batches, in order of preference (one per
   harness if you use both Claude Code and Codex); whether to turn on the
   prompt ledger (see [Cost ledger](#cost-ledger-optional)); and whether flight should run a
   **check command** before it merges (see [the preflight gate](#4-promote-toward-release)).
   Every answer is recorded, "no" included, so a re-run asks only what's new.
5. **The issue tracker** — it hands over to **`add-an-issue-tracker`**, which sets up where your
   issues live: usually this same repo (sharing the token), or another repo or a Jira project
   with its own token. The tracker gets a short, permanent **ref** — `FJ`, `GH`, `GL`, or the
   Jira project key — that appears in issue ids (`FJ-42`) and branch names, and becomes the
   **default** tracker, so a plain `#42` means it. It asks whether newly filed issues get a
   **starting status** such as `status/new` (see [File it](#1-file-it)), then reconciles the
   default label taxonomy against what the tracker already has, *adopting your existing names*
   (if you already call a state `status/qa`, it keeps that), shows you a plan, and creates only
   what's missing.

When it's done you'll have two files in the `.flightdirector/` folder: a committable **`.flightdirector/config.json`**
(code coordinates, the `stages` pipeline, and your trackers with their label names) and a
gitignored **`.flightdirector/secrets.json`** (the tokens). Every other skill reads `.flightdirector/config.json`, so they
all speak your repo's conventions. A third, optional file — a gitignored
**`.flightdirector/config.local.json`** — holds per-machine overrides; see
[Where your config lives](#where-your-config-lives).

**More than one tracker?** Say *"add another tracker"* or *"connect Jira"* at any time and
**`add-an-issue-tracker`** adds it beside the first — its own ref, token and labels — without
touching the others; the default only changes if you ask. Then `GH-12` or `KAN-7` names an issue
on that tracker, `#12` still means the default, and `flight issues list --all-trackers` lists every
tracker at once.

**Copying an issue to another tracker.** Say *"copy GH-3 into Forgejo"*, and
**`copying-an-issue`** checks the target for an existing copy, shows a preview, and copies it. Or
run it yourself:

```
flight issues copy --from GH-3 --to FJ --dry-run      # preview
flight issues copy --from GH-3 --to FJ                # copy (prints e.g. FJ-271)
flight issues resync --from GH-3 --to FJ              # later: bring over new comments
```

Body, comments, labels and status come along unless you pass `--no-body`, `--no-comments`,
`--no-labels` or `--no-status`. Nothing names the source on the copy unless you add `--footer`
or `--back-link`, which matters when copying from a private tracker to a public one.

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
| "clean up the branches", "delete merged branches", "what branches can go" | **cleaning-up-branches** | Find branches already merged into a stage, cross-check their issues, then delete refs + worktrees on your go-ahead |
| "set up flight", "bootstrap labels" | **setting-up-a-repo** | First-run setup (above); re-run after an upgrade to answer new questions |
| "add an issue tracker", "connect Jira", "track issues on GitHub too" | **add-an-issue-tracker** | Add or complete one named tracker — ref, credential, starting status, labels — keeping the default |
| "copy GH-3 into Forgejo", "resync the copy" | **copying-an-issue** | Duplicate scan → dry-run preview → copy to another tracker; later, bring over new comments |

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

If you opted into a **starting status** at setup, the new issue also gets that label
(`status/new`, or whatever you named it), so "what hasn't anyone looked at yet?" is a label
query rather than a guess. It is an ordinary status: the first status change — normally when
work starts — replaces it. Issues filed outside flight don't get it, and `--no-status` skips it
for one issue.

### 2. Decide what to do next

> **You:** "what should I work on?"

**triaging-issues** lists the open, *workable* issues (anything already in progress, in review, or
in QA is filtered out) so you can pick:

> **Claude:** *Quick wins: #42 export button (bug, ux), #38 tooltip clipping (ux). Larger: #31 bulk export. Recommend #42 — small and user-visible.*

### 3. Work it

> **You:** "let's work on #42"

**working-an-issue** creates a dedicated worktree off your first stage and flips the board:

- `git worktree add .worktrees/42-export-button -b feature/42-export-button develop`. With
  more than one issue tracker the branch carries the tracker's ref, `feature/fj-42-…`, so the
  same number on another tracker can never share a branch.
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

**What you'll see on the tracker.** Everything flight writes there — the issue body it filed, the
work-ledger comment, the PR description — ends with a small signature, so you can always tell
what came through the workflow and from which version:

```
---
🤖 via FlightDirector:flight@0.15.0 with Fable/5.1
```

The `with …` part names the model the skill was running (it passes its own id as `--model`);
the plugin version comes from the installed package. Editing a body re-signs it rather than
stacking a second line. Don't want it? Set `"signature": { "enabled": false }` under `code` in
`.flightdirector/config.json`, or add `--no-signature` to one call.

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

Closing there isn't compulsory. If your real release happens somewhere flight can't see — a
deployment approval, an environment promotion, a change window after the last branch merges —
set `"closesIssues": false` on that final stage and give it an `issueStatus`. The issue then
stays open in its last status until you (or the agent, once you say it shipped) close it. See
[example-flows.md](references/example-flows.md) → *"when the last branch isn't the last step"*.

**The preflight gate (optional).** A `direct` hop — usually `feature → develop` — has no CI
behind it, so without anything else the only check before that merge is you saying "promote".
If you give flight your repo's check command, it runs it first:

```jsonc
"code": { "preflight": "./scripts/run-checks.sh" }
```

**promoting-a-branch** runs it from the branch's worktree just before the merge (or before
opening the PR, on a `pr` hop). Only the exit code counts: zero carries on, anything else stops
the promotion and shows you the failing output. **promoting-branches** depends on the hop: on a
`direct` hop it runs it per branch, so one red branch is skipped while the clean ones still
ship; on a `pr` hop it runs it once on each group's assembled integration branch, and a red
result holds back that whole group (nothing pushed, no PR) while the other groups carry on.
**queue-batches** runs it for each issue once a zone finishes. It's a local gate, not a CI
replacement — a `pr` hop still watches CI afterwards. Leave it out and nothing changes. Write
the command so it works from any worktree, not just your main checkout; details in
[flight-setup.md](references/flight-setup.md#repo-preflight-gate-optional).

**Choosing how a PR merges.** On a `pr` hop you can pick the merge strategy — tell Claude
"promote to main, squash" (or pass `--strategy`):

- `merge` *(default)* — a merge commit; keeps the branch's individual commits on the target.
- `squash` — collapses the whole branch into a single commit on the target.
- `rebase` — replays the branch's commits onto the target with no merge commit.

If you don't say, it's `merge`. (This applies to `pr` hops only — a hop configured `direct`
always merges with `--no-ff` and has no strategy option. Which hops are which is up to your
`code.stages`: `feature → develop` is a common `direct` hop, but it can just as well be a
`pr` one.)

**After a stage-to-stage promotion, the lower stages are synced back down.** Once `develop → qa`
(or `qa → main`) lands, **promoting-a-branch** merges the target back into the source and cascades
to the bottom of the pipeline, so `develop` is never left one merge commit behind `qa`, release
tags on `main` are visible from `develop`, and a squash or rebase hop doesn't re-present the same
changes next time. Each stage decides how it receives that back-merge with `syncDown` (`direct`,
`pr`, or `none`), defaulting to its own `merge` setting — so a PR-only stage gets a small
"Sync qa back into develop" PR that auto-merges on green CI, and a direct stage just gets a push.
Put `"syncDown": "none"` on a stage to opt it out (the cascade stops there). A conflict or red CI
on the sync stops and reports; nothing is ever squashed, rebased, or reset on a stage branch.

That's the full loop: **file → triage → work (in a worktree, behind a merge gate) → promote up
the pipeline** — all without leaving the session.

When you have several independent issues to tackle at once, `/queue-batches NxM` scales this loop
horizontally: N background agents each work M issues sequentially in isolated worktrees (zones),
stopping at the to-test gate; you then ship the batch with **promoting-branches** (or hand-pick
branches one at a time with promoting-a-branch).

### 5. Sweep up

Merged branches don't remove themselves — `working-an-issue` clears the *worktree*, but the
`feature/<ref>-<N>-<slug>` ref stays on origin (and usually locally) forever. Every so often:

> **You:** "clean up the branches"

**cleaning-up-branches** finds the ones whose work has already landed in a stage — including
squash-merged ones, which git alone can't recognise — checks each against its issue's status so a
half-finished promotion gets flagged rather than swept away, and shows you the list. Nothing is
deleted until you say go, and deleting on **origin** is a separate yes from deleting locally.

---

## Where your config lives

- **`.flightdirector/config.json`** (commit it) — code backend + coordinates, the `stages`
  pipeline, and the `issueTrackers` list: each tracker's ref, coordinates and role→label-name
  map, one of them the default. See [flight-setup.md](references/flight-setup.md) for the schema.
  A config from before trackers had names is converted automatically the next time a skill
  runs (`flight reconcile`).
- **`.flightdirector/secrets.json`** (gitignored) — your API tokens: the code token, plus one per
  tracker that doesn't share it. If flight ever finds this file tracked by git, it warns you on
  every run. Rotating a token? Write the new one to `.flightdirector/secrets-new.json`, run
  `flight auth check --secrets .flightdirector/secrets-new.json` (add `--tracker <REF>` for a
  tracker's token), and move it into place only once every line is a `✓`.
- **`.flightdirector/config.local.json`** (gitignored, optional) — per-machine overrides of
  `config.json`: a fork's `owner`, a self-hosted `api`, `promptLog.enabled`, a `ciWatchTimeout`.
  It is layered over the committed file on every read, the way Claude Code layers
  `settings.local.json` over `settings.json`. Only list the keys you change — nested objects
  merge key by key, while scalars **and arrays** replace wholesale (a local `code.stages`
  replaces the whole pipeline, a local `issueTrackers` the whole tracker list). Issue trackers
  carry their own coordinates, so a local `code.api` or `code.owner` override moves the code
  axis only — to repoint a tracker on this machine, give a complete local `issueTrackers` array.
  `reconcile` never writes local values into `config.json`, an invalid local file is an error,
  and a tracked one warns on every run. Merge rules in full:
  [flight-setup.md](references/flight-setup.md#flightdirectorconfiglocaljson--optional-gitignored).

- **`code.signature.enabled`** (optional, default `true`) — the tracker signature described in
  [step 3](#3-work-it). `false` writes bare bodies.
- **`code.preflight`** (optional, off by default) — your repo's check command, run before a
  merge; see [the preflight gate](#4-promote-toward-release).
- **`labels.status.new`** on a tracker (optional, off by default) — the starting status given to
  issues newly filed on that tracker; see [File it](#1-file-it).

Want a different pipeline later? Edit `code.stages` in `.flightdirector/config.json` — e.g. add a `qa`
stage between `develop` and `main`. The skills pick it up immediately. For worked setups at 1, 2, 3,
and 4 hops — with contrasting `direct`/`pr`, merge-strategy, and issue-status configs, plus how
batch-promote differs by first-hop strategy — see
[example-flows.md](references/example-flows.md).

---

## Cost ledger (optional)

Every finished issue gets a **work-ledger comment**: what was done, on which model, and what it
cost. Turn on the **prompt ledger** and those numbers are measured instead of guessed:

```jsonc
// .flightdirector/config.json
"code": { "promptLog": { "enabled": true } }
```

The plugin's bundled hooks then append one record per agent turn — prompt, model, tokens,
estimated cost — to a gitignored `.flightdirector/prompt-log.jsonl`. **Claude Code and Codex
write the same file with the same schema**, so a project worked from both (even at once) has one
ledger, and `flight prompt-log summary --session <id>` renders the per-model totals the
ledger comment pastes in. Cost is priced from a bundled table you can extend per repo
(`.flightdirector/pricing.json`), and `summary` prices each row again from its tokens, so a
pricing fix also corrects turns already logged; under a subscription login it is labelled `api-equivalent` —
what the tokens *would* cost via the API, good for comparing issues, not a bill. Unknown models
and unreadable transcripts show up as `null` with a warning, never as a silent zero. Full schema
and semantics: [prompt-log.md](references/prompt-log.md).

---

## Driving flight from another tool (`--json`)

A dashboard, editor panel or script can drive the same dispatcher the skills use, without ever
seeing a token or calling a forge API. Add `--json` to the read and write verbs and every
backend answers with the same shape:

```sh
flight capabilities --json                    # {"plugin","version","capabilities":[…]}: feature-detect here
flight issues list --state open --json        # {"issues":[…], "truncated", "total"}
flight issues get --number 42 --json          # one issue: labels, status role, body, signature split out
flight issues comments --number 42 --json     # [{id, author, created, updated, url, body, signature}]
flight labels statuses --json                 # this repo's status roles → label names and colours
flight issues comment --number 42 --body hi --json   # the new comment, same shape as above
```

A failure under `--json` prints one `{"error":{"code","message"}}` object on stdout and exits
non-zero. The code is one of `not-configured`, `auth`, `not-found`, `network`, `backend` or
`usage`, so a UI can show "set this repo up" or "fix your token" instead of raw stderr. Without
`--json`, the tab-separated output agents rely on is unchanged. Every field, verb and edge
case: [json-output.md](references/json-output.md).

---

## Tips

- **Issues elsewhere than code — or in several places?** Code stays on `code`; issues live in
  one or more named trackers (another repo, another backend, a Jira project), each with its own
  ref, token and labels. Add one with *"add an issue tracker"*. See
  [backends.md](references/backends.md).
- **The merge gate is real.** If you want something merged, say so explicitly — "merge #N" /
  "promote …". Claude will leave work at *ready-to-test* and stop otherwise.
- **Re-running setup is safe — and useful after an upgrade.** `setting-up-a-repo` is
  idempotent: it only adds what's missing, never renames or deletes your existing labels, and
  keeps your trackers and your default as they are. It also asks only the setup questions your config has no answer for yet, so a re-run is how a
  repo picks up an option added in a newer release (the prompt ledger, say) without being
  re-asked the ones it already answered.
