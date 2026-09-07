---
name: setting-up-a-repo
description: Use when setting up a repo for flight for the first time — "set up this repo", "set up flight", "configure flight", "set up labels", "bootstrap labels", "add the default labels" — when filing/triage reveals the repo has no flight config or few labels, or when retrofitting the backend breadcrumb onto an already-configured repo ("add the flight note/breadcrumb", "add it to AGENTS.md"). Writes the flight config + secrets (backend coordinates, stage pipeline, worker model), reconciles a default label taxonomy against existing labels (creating only what's missing, after a preview), and leaves a backend breadcrumb in the repo's agent instructions (AGENTS.md, imported by CLAUDE.md).
---

# Setting Up a Repo

Before the first command, follow [runtime preflight](../../references/runtime.md).

The first-run setup skill: it writes the `.flightdirector/config.json` + `.flightdirector/secrets.json` the
dispatcher needs, then brings the repo up to the default label taxonomy — idempotently, adopting
existing equivalents and creating only the approved missing labels.

**The defaults live in** [default-labels.md](../../references/default-labels.md) — that's the
data; this skill is the logic. Config schema:
[flight-setup.md](../../references/flight-setup.md). Verbs:
[adapter-contract.md](../../references/adapter-contract.md).

Once config + secrets exist (Steps 1–3), all label actions go through the dispatcher:

```
flight labels <list|create> …
```

## Why a skill and not a script

"Create it only if an equivalent doesn't already exist" is a judgment call (is `kind/bug` the
same as `bug`? is `enhancement` the role `feature`?) — reasoning, not a diff. And `area/*` labels
must be proposed from the actual project, not seeded from a table.

## Red flags — STOP

- **Never rename, recolor, or delete an existing label.** This skill only *adds*.
- **An equivalent already present is ADOPTED, not duplicated.** If the repo has `enhancement`,
  don't create `feature` — record `enhancement` as the name for that role and move on.
- **Never create `area/*` labels without project input.** They're project-dependent — propose,
  then wait for the user to confirm/edit.
- **One confirmation gate before creating anything.** Show the full plan first.
- **Never commit `.flightdirector/secrets.json`.** It holds the token — add the
  `.flightdirector/secrets*` glob to `.gitignore` before writing it, so backups and
  per-backend variants (`secrets.local.json`, `secrets.json.bak`, …) can't leak either.

## Step 0: Detect existing backends — offer, then confirm

Before asking anything from scratch, **look at what the repo already tells you** and lead with a
confirm-and-go offer. Detection is a shortcut, not a gate: everything below has a manual fallback
(Steps 1–4), so when a signal is missing or ambiguous, say so and drop through to the prompts —
never guess a backend into the config.

**First, reuse an existing flight config.** If `.flightdirector/config.json` already exists, read
it and treat it as the source of truth: show its coordinates + stage pipeline back to the user and
ask whether to reuse it as-is (skip to the label reconcile, Step 5) or revise it. Don't re-ask for
values it already has. Either way, check the agent instructions (`AGENTS.md` / `CLAUDE.md`) for the backend
breadcrumb (Step 9) — repos set up before that step existed won't have one, and a re-run is how
they retrofit it.

**Migrate a legacy `.lightspeed/` folder.** If `.lightspeed/config.json` exists but
`.flightdirector/config.json` does not, the repo was configured before the plugin was renamed. Offer
the move (show the commands, wait for a yes), then run:

```
git mv .lightspeed/config.json .flightdirector/config.json   # tracked → keeps history
mv .lightspeed/secrets* .flightdirector/                     # gitignored → plain mv (any secrets file)
rmdir .lightspeed 2>/dev/null || true                        # leave it if anything else is inside
```

Then add `.flightdirector/secrets*` and `.flightdirector/batches/` to `.gitignore` (keep the
old `.lightspeed/…` lines if other branches still use them) and continue as a re-run over the
existing config. Until the move happens the dispatcher keeps working off the legacy folder with a
one-line notice on stderr — so never block a user on the migration.

**Retrofit-only shortcut:** when the user just wants the breadcrumb added to an
already-configured repo ("add the flight note/breadcrumb", "put it in AGENTS.md"), read the backend +
host from the existing config and jump straight to Step 9 — no label reconcile needed.

**Detect the CODE backend from the git remote host.** Read the remote URL —
`git config --get remote.origin.url` (or `git remote -v`) — and map the host to a backend:

| Remote host | Backend | API base |
|---|---|---|
| `github.com` | `github` | `https://api.github.com` |
| `gitlab.com` **or** a self-managed GitLab host | `gitlab` | `https://<host>/api/v4` |
| a Forgejo/Gitea host (self-hosted) | `forgejo` | `https://<host>/api/v1` |

The host isn't always decisive on its own — a self-managed GitLab and a Forgejo/Gitea instance
both live on a custom domain. Corroborate before asserting: a `gitlab-ci.yml`/`.gitlab-ci.yml` or a
`git@gitlab.…`-style remote points to GitLab; a `.forgejo/`/`.gitea/` workflow dir or Gitea-style
API paths point to Forgejo. When the host is a bare custom domain with no corroborating signal,
**offer your best guess but ask the user to confirm the backend** rather than committing to one.
Parse `owner/repo` from the same URL for the coordinates Step 1 wants.

**Detect ISSUE-backend signals.** By default the `issues` axis inherits `code` (same host tracks
the issues). Look for signs it doesn't:
- **Jira** — project keys shaped like `ABC-123` in recent commit subjects or branch names
  (`git log --oneline -50`, `git branch -a`) strongly suggest a Jira issues-axis backend paired
  with the git `code` backend. Offer a split setup: `code` = the detected git host, `issues` =
  `jira` (issues-axis-only, per Step 4 / the config schema).
- Otherwise assume `issues` inherits `code` and only confirm.

**Then offer, and let the user confirm-and-go.** Summarize what you found and propose the config in
one shot, e.g.:

```
Detected from this repo:
  code    → github   (remote is github.com/acme/widgets)
  issues  → jira      (commits reference KAN-123, PROJ-456)

Set it up this way? [y] — or tell me what to change.
```

On `y`, carry these detected values straight into Steps 1–4 (skip the questions they already
answer). If detection was **inconclusive** (no remote, unrecognized host, conflicting signals) or
the user wants something different, fall back to the manual flow below and ask normally.

**Supported backends to offer:** `github`, `gitlab`, `forgejo` for the `code` axis; plus `jira`
as an **issues-axis-only** backend (paired with a git code backend). All four are implemented.

## Step 1: Coordinates + instance

If Step 0 detected and the user confirmed the coordinates, carry them forward — this step is the
**fallback** when detection was inconclusive or declined. Autodetect from the git remote that
points at the host: `git remote get-url origin` → parse `owner/repo` and the host. The API base
follows the backend (see the Step 0 table): `https://<host>/api/v1` for Forgejo, `/api/v4` for
GitLab, `https://api.github.com` for GitHub. **Confirm all three with the user** (owner, repo,
api). For a split setup (issues tracked in a different repo/backend — e.g. the Jira pairing from
Step 0), ask; otherwise `issues` inherits `code` and you only need one set.

## Step 2: Token → secrets file

The dispatcher needs a per-repo API token. Ask the user to create a **least-privilege** token on
the host — just `write:repository` and `write:issue` (the latter also covers labels), not an
all-orgs admin token. These two work with a token restricted to a single repository; do **not**
add `write:misc` (unused, and Forgejo rejects it on a single-repo token). The exact scopes and the
token-creation steps differ per backend (GitHub, GitLab, Forgejo, Jira) — see
[backends.md](../../references/backends.md) for the per-backend token walkthrough, and
[flight-setup.md](../../references/flight-setup.md) for the config schema. Then:

1. Create the config folder: `mkdir -p .flightdirector`.
2. Add `.flightdirector/secrets*`, `.worktrees/`, **and** `.flightdirector/batches/` to `.gitignore`
   **first** (create `.gitignore` if needed). Ignore the whole `secrets*` family, not just
   `secrets.json` — a second token file or a backup made while rotating a token is otherwise one
   `git add -A` from being committed. `.worktrees/` is where `working-an-issue` creates
   per-issue git worktrees, and `.flightdirector/batches/` is where `queue-batches` writes per-run
   batch manifests — both are per-run local state (not secrets) that must be ignored so they
   don't appear as untracked content in the repo. Add `prompt_log.jsonl` too if the user opts
   into the prompt ledger in Step 4 (it holds prompt text).
3. Write `.flightdirector/secrets.json`:
   ```json
   { "code": { "token": "<the token>" } }
   ```

## Step 3: Workflow preferences — stage pipeline preset

Ask which promotion pipeline the repo uses. Present three options:

**(a) Simple — `develop → main`**
Feature branches fork from `develop`, integrate there directly, then promote to `main` via PR:
```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge" },
  { "name": "main",    "merge": "pr",     "issueStatus": "done" }
]
```

**(b) Multi-stage — `develop → qa → main`**
Same as (a) but an intermediate `qa` branch sits between integration and production. Each stage
carries an `issueStatus` so the board mirrors the issue's position; issues stay open until the
terminal stage (`main`), where they close:
```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
  { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
  { "name": "main",    "merge": "pr",     "issueStatus": "done" }
]
```

**(c) Advanced / custom** — capture a custom ordered list of stages (name + per-hop `merge` and
optional `gate`), or tell the user they can hand-edit `code.stages` in `.flightdirector/config.json`
afterward per [flight-setup.md](../../references/flight-setup.md).

**Defaults explained briefly:**
- Feature branches fork from `stages[0]` (the first integration branch).
- `merge: "direct"` integrates by merging locally; `merge: "pr"` opens a pull request for the hop.
- `gate: "pre-merge"` runs checks before merging; `gate: "post-merge-qa"` merges then verifies in
  that environment. The gate governs *merging only*.
- `issueStatus` (per stage, optional) sets the issue's status label on entering that stage;
  `closesIssues` (per stage, optional) overrides the default close point, which is the terminal
  stage. Together they drive issue lifecycle independently of `gate`. See
  [flight-setup.md](../../references/flight-setup.md).
- The user can always edit `.flightdirector/config.json` later to adjust stages.

## Step 4: Write the initial config

Write `.flightdirector/config.json` in the `.flightdirector/` folder (created in Step 2) with coordinates + the chosen stage pipeline (the
`labels` map gets finalized in Step 8; start it from the defaults). Example for preset (b):

```json
{
  "schemaVersion": 2,
  "harnesses": { "claude": { "plugins": { "flight": { "reconciledWith": "<installed-version>" } } } },
  "code": { "backend": "forgejo", "owner": "…", "repo": "…", "api": "https://…/api/v1",
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main",    "merge": "pr",     "issueStatus": "done" }
    ],
    "queueBatches": { "defaultModel": "sonnet" } },
  "labels": {
    "status": { "in-progress": "status/in progress", "to-test": "status/to test",
                "blocked": "status/blocked", "deferred": "status/deferred",
                "review": "status/review", "qa": "status/qa", "done": "status/done" },
    "model": { "opus": "model/opus", "sonnet": "model/sonnet",
               "haiku": "model/haiku", "fable": "model/fable",
               "sol": "model/sol", "terra": "model/terra",
               "luna": "model/luna", "astra": "model/astra" }
  }
}
```

`code.queueBatches.defaultModel` sets the default model the `queue-batches` skill gives its
worker agents (overridable per run). `sonnet` is a sensible default for mechanical implementation
work; change it here to retarget all future parallel runs (e.g. to a newer model) without editing
the skill. You can also add an optional `code.zones` array later — see
[flight-setup.md](../../references/flight-setup.md) — to make `queue-batches` schedule
deterministically instead of inferring zones.

**Offer the prompt ledger (opt-in).** Ask: *"Log each agent turn's prompt, tokens, and estimated
cost to `prompt_log.jsonl` so issue ledgers are measured rather than estimated? (Both Claude Code
and Codex write the same file; it stays local and gitignored.)"* If yes, add
`"promptLog": { "enabled": true }` under `code` and make sure `prompt_log.jsonl` is in
`.gitignore` (Step 2). The plugin's bundled hooks do the rest — nothing else to install. If the
user already runs a personal prompt-logger hook (e.g. in `.claude/settings.local.json`), tell them
to remove it or every turn is logged twice. Details: [prompt-log.md](../../references/prompt-log.md).

Use the `stages` array from the chosen preset (a), (b), or the user's custom pipeline. All six
status roles (`in-progress`, `to-test`, `blocked`, `deferred`, `review`, `qa`, `done`) are seeded so the
reconcile step in Steps 6–8 ensures the corresponding labels exist. If a config already exists,
show the diff and confirm before overwriting — don't clobber hand-edits. From here the dispatcher
works.

## Step 5: Load defaults and existing labels

- Read [default-labels.md](../../references/default-labels.md) for the target taxonomy, colors,
  and each label's listed equivalents.
- Fetch what the repo already has:
  ```
  flight labels list
  ```
  Output is `name⇥color⇥description` per label.

## Step 6: Reconcile

For each default label (and each role-based label — status, model), classify it:

| Outcome | Condition | What to record for the role |
|---|---|---|
| **EXISTS** | The repo already has that exact label name | Use that name |
| **ADOPT** | The repo has one of its listed equivalents (or an obvious synonym) — don't duplicate | **Adopt the repo's existing name** for the role (e.g. role `awaiting-test` → `status/testing` because the repo has it) |
| **MISSING** | Neither the name nor an equivalent is present — candidate to create | Use the default name (once created) |

Apply judgment beyond the table's synonyms — a repo's `Bug` (case) or `🐛 bug` clearly covers
`bug`. **This is the mechanism that respects the user's conventions:** for every role the skills
depend on (`status/*`, `model/*` especially), record the *actual name this repo uses* — that's
what gets written to `labels` in Step 8. When more than one candidate could fill a role, ask.

## Step 7: Handle `area/*` separately (project-dependent)

Don't take `area/*` from the table blindly. Inspect the repo (top-level structure, README,
obvious services) and **propose** an area set that fits — e.g. `web/` + `api/` + `migrations/`
suggests `area/app`, `area/server`, `area/db`. Let the user confirm, edit, or skip. Adopt
existing area equivalents the same way (`frontend` → `area/app`).

Whatever area names are chosen — including custom ones not in the table — create them all with
the single `area/*` **group colour** (`#3b82f6` per [default-labels.md](../../references/default-labels.md)).
One colour per namespaced prefix is the convention (`model/*` likewise shares its colour);
`status/*` is the only namespaced set that varies colour per label.

## Step 8: Plan → confirm → create → finalize

Show one grouped plan and ask once:

```
Label plan for <owner>/<repo>:

  CREATE  model/opus, model/sonnet, model/sol, model/terra, model/luna, model/astra,
          feature, tech-debt, security, ux, bug
  ADOPT   awaiting-test ← 'status/testing'   (repo already has it; using yours)
  EXISTS  status/blocked
  AREAS   area/app, area/server, area/db   (proposed from repo layout — confirm)

Create these? [y]
```

On approval, create each missing label with its name/color/description from the data file:

```
flight labels create --name "bug" --color "#d73a4a" --description "Something is broken"
```

Then **finalize `.flightdirector/config.json`**: update the `labels` map so every role records the actual
name this repo uses (the adopted names from Steps 6–7). This is what makes the other skills use
*this repo's* label names. Report what was created, adopted, and declined. Re-running later is
safe — everything now present becomes EXISTS/ADOPT.

> **Forgejo — optional label exclusivity.** Forgejo (and Gitea) can mark a scoped label group
> *exclusive*, so its UI allows only one label from that group on an issue at a time. flight
> doesn't rely on this — `set-status` already drops the prior `status/*` label before adding the
> new one, on every backend — so it's purely a guard against a human hand-adding two labels in the
> Forgejo UI. If you want that guard, set the `status/*` group **exclusive** and leave `model/*`
> **non-exclusive** (an issue can legitimately be touched by more than one model) in Forgejo's
> label settings, per your preference. Not applicable to GitHub (no such feature); GitLab expresses
> exclusivity differently (via `scope::value` naming, tier-gated).

## Step 9: Leave a backend breadcrumb in the agent instructions (AGENTS.md)

Agents reflexively assume GitHub — "issue #21" pattern-matches to `gh` — and a `.flightdirector/`
directory alone hasn't proven loud enough to stop that. So finish setup by writing the backend
into the repo's agent instructions (they load every session; a memory directory is per-user and
doesn't travel with the repo).

**Which file.** flight runs under Claude Code *and* Codex, and they read different files: Codex
auto-discovers `AGENTS.md` (and never reads `CLAUDE.md` unless a user configures it as a
fallback); Claude Code reads `CLAUDE.md`, which can import `AGENTS.md` with a bare `@AGENTS.md`
line. So the block belongs in **`AGENTS.md`**, with `CLAUDE.md` importing it — one source, both
harnesses. Resolve the target like this, and tell the user which case applied:

| Repo has | Do |
|---|---|
| `AGENTS.md` (with or without `CLAUDE.md`) | Put the block in `AGENTS.md`. If `CLAUDE.md` exists and has no `@AGENTS.md` import, offer to add one at its top; if there is no `CLAUDE.md`, offer to create one containing just `@AGENTS.md`. |
| only `CLAUDE.md` | Recommend the split: create `AGENTS.md` with the block, add `@AGENTS.md` at the top of `CLAUDE.md`. If the user says they don't use Codex and would rather keep a single file, put the block in `CLAUDE.md` instead — their call. |
| neither | Create `AGENTS.md` with the block and a `CLAUDE.md` containing `@AGENTS.md`. |

Don't suggest a symlink (`CLAUDE.md -> AGENTS.md`): it breaks on Windows without Developer
Mode and leaves no room for Claude-only notes. The import is the documented pattern.

Append this block — with the *actual* backend, host, and stage names from the config — to the
resolved file. Show it to the user before writing (it's their instructions file):

```markdown
## Issue tracking — flight

This repo manages issues/PRs/CI with the **flight** plugin. The backend is
**<backend>** at `<host>` — NOT GitHub — so never reach for `gh` here.
Coordinates, stage pipeline, and label names live in `.flightdirector/config.json`
(token in `.flightdirector/secrets.json`, git-ignored). Act through the flight
skills (working-an-issue, promoting-a-branch, filing-issues, …) or the
dispatcher: `flight <group> <verb>`.

Workflow red lines — these hold for every model and survive context
compaction; re-read them before any git write, especially if the session's
earlier instructions were summarized away or the model changed mid-session:

- Each issue is worked on its own `feature/<N>-<slug>` branch in its own
  `.worktrees/<N>-<slug>` worktree — NEVER commit directly to the integration
  branch (`<stages[0]>`) or any later stage.
- Merging is gated on the user's explicit go-ahead ("promote"); it happens
  through the promoting-a-branch skill, never by hand.
- Keep the issue's status label honest at every transition
  (in-progress → to-test → …) via `flight issues set-status`.
```

For a GitHub-backend repo, keep the block but drop the "NOT GitHub" clause and say plainly that
issue actions still go through the dispatcher/skills, not raw `gh`. For a split setup, name both
axes (e.g. "code on Forgejo at …, issues in Jira project ABC").

**Idempotent:** if either file already has an "Issue tracking — flight" section — or the
pre-rename "Issue tracking — lightspeed" one — update it in place (the backend may have changed,
and the old block names the `lightspeed` dispatcher) rather than appending a duplicate. If the
existing block lives in `CLAUDE.md` and the repo also has (or is getting) an `AGENTS.md`, offer
to move it there so there is one copy, not two that drift.

## Common mistakes

- Creating `feature` when the repo already uses `enhancement` (duplicate taxonomy). Adopt
  `enhancement` as the role's name and record it in the config.
- Creating labels but forgetting to finalize the `labels` map in `.flightdirector/config.json` — then the
  other skills use plugin defaults and ignore the names you adopted.
- Writing `.flightdirector/secrets.json` without gitignoring `.flightdirector/secrets*` first — that
  leaks the token.
- Seeding `area/*` from the table without checking the project.
- Recoloring or renaming an existing label to match the default. Only add what's missing.
