---
name: setting-up-a-repo
description: Use when setting up a repo for lightspeed for the first time — "set up this repo", "set up lightspeed", "configure lightspeed", "set up labels", "bootstrap labels", "add the default labels" — or when filing/triage reveals the repo has no lightspeed config or few labels. Writes the lightspeed config + secrets (backend coordinates, stage pipeline, worker model), then reconciles a default label taxonomy against existing labels and creates only what's missing, after a preview.
---

# Setting Up a Repo

The first-run setup skill: it writes the `.lightspeed/config.json` + `.lightspeed/secrets.json` the
dispatcher needs, then brings the repo up to the default label taxonomy — idempotently, adopting
existing equivalents and creating only the approved missing labels.

**The defaults live in** [default-labels.md](../../references/default-labels.md) — that's the
data; this skill is the logic. Config schema:
[lightspeed-setup.md](../../references/lightspeed-setup.md). Verbs:
[adapter-contract.md](../../references/adapter-contract.md).

Once config + secrets exist (Steps 1–3), all label actions go through the dispatcher:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" labels <list|create> …
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
- **Never commit `.lightspeed/secrets.json`.** It holds the token — add it to `.gitignore`
  before writing it.

## Step 1: Coordinates + instance

Autodetect from the git remote that points at the host: `git remote get-url origin` → parse
`owner/repo` and the host. The API base is `https://<host>/api/v1`. **Confirm all three with the
user** (owner, repo, api). For a split setup (issues tracked in a different repo/backend), ask;
otherwise `issues` inherits `code` and you only need one set.

## Step 2: Token → secrets file

The dispatcher needs a per-repo API token. Ask the user to create a **least-privilege** token on
the host — just `write:repository` and `write:issue` (the latter also covers labels), not an
all-orgs admin token. These two work with a token restricted to a single repository; do **not**
add `write:misc` (unused, and Forgejo rejects it on a single-repo token). See
[lightspeed-setup.md](../../references/lightspeed-setup.md). Then:

1. Create the config folder: `mkdir -p .lightspeed`.
2. Add `.lightspeed/secrets.json` **and** `.worktrees/` to `.gitignore` **first** (create
   `.gitignore` if needed). `.worktrees/` is where `working-an-issue` creates per-issue git
   worktrees — they must be ignored so they don't appear as untracked content in the repo.
3. Write `.lightspeed/secrets.json`:
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
  { "name": "main",    "merge": "pr" }
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
  { "name": "main",    "merge": "pr" }
]
```

**(c) Advanced / custom** — capture a custom ordered list of stages (name + per-hop `merge` and
optional `gate`), or tell the user they can hand-edit `code.stages` in `.lightspeed/config.json`
afterward per [lightspeed-setup.md](../../references/lightspeed-setup.md).

**Defaults explained briefly:**
- Feature branches fork from `stages[0]` (the first integration branch).
- `merge: "direct"` integrates by merging locally; `merge: "pr"` opens a pull request for the hop.
- `gate: "pre-merge"` runs checks before merging; `gate: "post-merge-qa"` merges then verifies in
  that environment. The gate governs *merging only*.
- `issueStatus` (per stage, optional) sets the issue's status label on entering that stage;
  `closesIssues` (per stage, optional) overrides the default close point, which is the terminal
  stage. Together they drive issue lifecycle independently of `gate`. See
  [lightspeed-setup.md](../../references/lightspeed-setup.md).
- The user can always edit `.lightspeed/config.json` later to adjust stages.

## Step 4: Write the initial config

Write `.lightspeed/config.json` in the `.lightspeed/` folder (created in Step 2) with coordinates + the chosen stage pipeline (the
`labels` map gets finalized in Step 8; start it from the defaults). Example for preset (b):

```json
{
  "code": { "backend": "forgejo", "owner": "…", "repo": "…", "api": "https://…/api/v1",
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main",    "merge": "pr" }
    ],
    "queueBatches": { "defaultModel": "sonnet" } },
  "labels": {
    "status": { "in-progress": "status/in progress", "to-test": "status/to test",
                "blocked": "status/blocked", "deferred": "status/deferred",
                "review": "status/review", "qa": "status/qa" },
    "model": { "opus": "model/opus", "sonnet": "model/sonnet",
               "haiku": "model/haiku", "fable": "model/fable" }
  }
}
```

`code.queueBatches.defaultModel` sets the default model the `queue-batches` skill gives its
worker agents (overridable per run). `sonnet` is a sensible default for mechanical implementation
work; change it here to retarget all future parallel runs (e.g. to a newer model) without editing
the skill. You can also add an optional `code.zones` array later — see
[lightspeed-setup.md](../../references/lightspeed-setup.md) — to make `queue-batches` schedule
deterministically instead of inferring zones.

Use the `stages` array from the chosen preset (a), (b), or the user's custom pipeline. All six
status roles (`in-progress`, `to-test`, `blocked`, `deferred`, `review`, `qa`) are seeded so the
reconcile step in Steps 6–8 ensures the corresponding labels exist. If a config already exists,
show the diff and confirm before overwriting — don't clobber hand-edits. From here the dispatcher
works.

## Step 5: Load defaults and existing labels

- Read [default-labels.md](../../references/default-labels.md) for the target taxonomy, colors,
  and each label's listed equivalents.
- Fetch what the repo already has:
  ```
  "$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" labels list
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

## Step 8: Plan → confirm → create → finalize

Show one grouped plan and ask once:

```
Label plan for <owner>/<repo>:

  CREATE  model/opus, model/sonnet, feature, tech-debt, security, ux, bug
  ADOPT   awaiting-test ← 'status/testing'   (repo already has it; using yours)
  EXISTS  status/blocked
  AREAS   area/app, area/server, area/db   (proposed from repo layout — confirm)

Create these? [y]
```

On approval, create each missing label with its name/color/description from the data file:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" labels create --name "bug" --color "#d73a4a" --description "Something is broken"
```

Then **finalize `.lightspeed/config.json`**: update the `labels` map so every role records the actual
name this repo uses (the adopted names from Steps 6–7). This is what makes the other skills use
*this repo's* label names. Report what was created, adopted, and declined. Re-running later is
safe — everything now present becomes EXISTS/ADOPT.

## Common mistakes

- Creating `feature` when the repo already uses `enhancement` (duplicate taxonomy). Adopt
  `enhancement` as the role's name and record it in the config.
- Creating labels but forgetting to finalize the `labels` map in `.lightspeed/config.json` — then the
  other skills use plugin defaults and ignore the names you adopted.
- Writing `.lightspeed/secrets.json` without gitignoring it first — that leaks the token.
- Seeding `area/*` from the table without checking the project.
- Recoloring or renaming an existing label to match the default. Only add what's missing.
