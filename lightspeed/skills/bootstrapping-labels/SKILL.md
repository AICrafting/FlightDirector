---
name: bootstrapping-labels
description: Use when setting up a Forgejo repo's labels for the first time, or when the user says "set up labels", "bootstrap labels", "add the default labels", "configure issue labels", or when filing reveals the repo has few or no labels. Reconciles a default taxonomy against existing labels and creates only what's missing, after a preview.
---

# Bootstrapping Labels

Bring a Forgejo repo up to the plugin's default label taxonomy — idempotently. Reads the
defaults, compares against what already exists (treating equivalents as already-present),
shows a plan, and creates only the approved missing labels.

**Setup and repo coordinates:** see [forgejo-setup.md](../../references/forgejo-setup.md).
**The defaults live in** [default-labels.md](../../references/default-labels.md) — that's
the data; this skill is the logic. All calls go through `mcp__forgejo__*` tools.

## Why a skill and not a script

Labels are created with `mcp__forgejo__create_repo_label`, an MCP tool only the agent can
call — a standalone shell script would have to fall back to curl + a token, which this
plugin deliberately avoids. And "create it only if an equivalent doesn't already exist" is
a judgment call (is `kind/bug` the same as `bug`?), which is reasoning, not a diff.

## Red flags — STOP

- **Never rename, recolor, or delete an existing label.** This skill only *adds*.
- **An equivalent already present is ADOPTED, not duplicated.** If the repo has `enhancement`,
  don't create `feature` — record `enhancement` as the name for that role and move on.
- **Never create `area/*` labels without project input.** They're project-dependent —
  propose, then wait for the user to confirm/edit.
- **One confirmation gate before creating anything.** Show the full plan first.

## Step 1: Determine repo coordinates

Autodetect `owner`/`repo` from the git remote that points at the Forgejo host
(`git remote get-url origin` → parse `owner/repo`) and **confirm with the user**. Fall back
to `FORGEJO_OWNER`/`FORGEJO_REPO` or asking (see setup reference for precedence). These get
written to the config in Step 8 — bootstrap is where they're captured.

## Step 2: Load defaults and existing labels

- Read [default-labels.md](../../references/default-labels.md) for the target taxonomy,
  colors, and each label's listed equivalents.
- Fetch what the repo already has: `mcp__forgejo__list_repo_labels(owner, repo)`.

## Step 3: Reconcile

For each default label (and each role-based label — status, model), classify it:

| Outcome | Condition | What to record for the role |
|---|---|---|
| **EXISTS** | The repo already has that exact label name | Use that name |
| **ADOPT** | The repo has one of its listed equivalents (or an obvious synonym) — don't duplicate | **Adopt the repo's existing name** for the role (e.g. role `awaiting-test` → `status/qa` because the repo has `status/qa`, not `status/to test`) |
| **MISSING** | Neither the name nor an equivalent is present — candidate to create | Use the default name (once created) |

Apply judgment on equivalence beyond the table's listed synonyms — a repo's `Bug` (case)
or `🐛 bug` clearly covers `bug`.

**This is the mechanism that respects the user's conventions.** For every role the skills
depend on (the `status/*` and `model/*` roles especially), record the *actual name this repo
uses* — that's what gets written to the config in Step 7 and what every other skill then
uses. The plugin's default name is only used when nothing equivalent exists and you create it.
When more than one candidate could fill a role, ask the user which to adopt.

## Step 4: Handle `area/*` separately (project-dependent)

Don't take `area/*` from the table blindly. Inspect the repo (its top-level structure,
README, obvious services) and **propose** an area set that fits — e.g. a repo with
`web/` + `api/` + `migrations/` suggests `area/app`, `area/server`, `area/db`. Present
your proposal and let the user confirm, edit, or skip areas entirely before any get added
to the create list. Adopt existing area equivalents the same way (`frontend` → `area/app`).

## Step 5: Present the plan, get one confirmation

Show a single grouped plan and ask once:

```
Label plan for <owner>/<repo>:

  CREATE  model/opus, model/sonnet, model/haiku
  CREATE  feature, tech-debt, security, performance, ux, polish, regression,
          quick-win, high-value, critical
  CREATE  bug                      (none present)
  ADOPT   awaiting-test ← 'status/qa'    (repo already has it; using yours)
  EXISTS  status/blocked           (already present)
  AREAS   area/app, area/server, area/db   (proposed from repo layout — confirm)
  STATUS  status/in progress, status/deferred   (missing — create? adopting status/qa above)

Create the CREATE + confirmed AREAS/STATUS labels? [y]
```

(Status labels are optional — offer them, default to including only if the user uses a
status workflow.)

## Step 6: Create the approved labels

For each approved missing label, using the name, color, and description from the data file:

```
mcp__forgejo__create_repo_label(owner, repo, name="bug", color="#d73a4a", description="Something is broken")
```

Then report what was created, what was adopted from existing labels, and anything the user
declined. Re-running later is safe — everything now present becomes EXISTS/ADOPT.

## Step 7: Capture workflow preferences

Ask the two repo-level questions `working-an-issue` needs:

1. **Merge strategy** — *"When an issue is approved, merge via a Forgejo pull request, or a
   direct git merge into the trunk branch?"* → `mergeStrategy`: `"pr"` or `"direct"`.
2. **Trunk branch** — confirm the integration branch (`develop`? `main`?) → `trunkBranch`.

## Step 8: Write the per-repo config

Write `.lightspeed.json` at the repo root (see
[forgejo-setup.md](../../references/forgejo-setup.md) for the schema) capturing the merge
prefs and the **role → adopted-name** map you built in Steps 3–4. This is what makes the
other skills use *this repo's* label names. Example for a repo that already had `status/qa`:

```json
{
  "owner": "cerebralgardens",
  "repo": "meshcore_lib",
  "trunkBranch": "develop",
  "mergeStrategy": "pr",
  "labels": {
    "status": { "in-progress": "status/in progress", "awaiting-test": "status/qa",
                "blocked": "status/blocked", "deferred": "status/deferred" },
    "model": { "opus": "model/opus", "sonnet": "model/sonnet",
               "haiku": "model/haiku", "fable": "model/fable" }
  }
}
```

If a config already exists, show the diff and confirm before overwriting — don't clobber
hand-edits.

## Common mistakes

- Creating `feature` when the repo already uses `enhancement` (duplicate taxonomy). Adopt
  `enhancement` as the role's name and record it in the config.
- Creating labels but forgetting to write `.lightspeed.json` — then the other skills
  fall back to plugin defaults and ignore the names you just adopted.
- Seeding `area/*` from the table without checking the project — these must be proposed
  from the actual repo and confirmed.
- Recoloring or renaming an existing label to match the default. Leave existing labels
  untouched; only add what's missing.
