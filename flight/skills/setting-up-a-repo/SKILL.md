---
name: setting-up-a-repo
description: Use when setting up a repo for flight for the first time — "set up this repo", "set up flight", "configure flight", "set up labels", "bootstrap labels", "add the default labels" — when filing/triage reveals the repo has no flight config or few labels, when re-running setup after an upgrade to pick up new questions, or when retrofitting the backend breadcrumb onto an already-configured repo ("add the flight note/breadcrumb", "add it to AGENTS.md"). Writes the flight config + secrets (code coordinates, stage pipeline, worker model, prompt ledger, preflight gate), hands the issue tracker — coordinates, ref, credential, label reconcile, starting status — to add-an-issue-tracker, and leaves a backend breadcrumb in the repo's agent instructions (AGENTS.md, imported by CLAUDE.md).
---

# Setting Up a Repo

Before the first command, follow [runtime preflight](../../references/runtime.md). One
exception: on a repo with **no** `.flightdirector/config.json` yet, `reconcile` has nothing to
read — resolve `DISP` and `HARNESS`, skip `reconcile`, and run it once the config is written
(Step 5).

The first-run (and re-run) setup skill. It owns everything **repo-wide**: the code backend and
its coordinates, the code token, the stage pipeline, the repo preferences (`queue-batches`
worker model, prompt ledger, preflight gate), the gitignore entries, and the agent-instructions
breadcrumb. **Issue trackers belong to the
[add-an-issue-tracker](../add-an-issue-tracker/SKILL.md) skill** — the first tracker on a fresh
repo, every tracker's unanswered questions on a re-run, and any tracker added later: its
coordinates, stable ref and aliases, credential, starting status, and the label reconcile that
adopts existing equivalents and creates only what's missing.

Config schema: [flight-setup.md](../../references/flight-setup.md). Verbs:
[adapter-contract.md](../../references/adapter-contract.md). Label defaults (used by the
sub-skill): [default-labels.md](../../references/default-labels.md).

## Red flags — STOP

- **Never commit `.flightdirector/secrets.json`.** It holds the tokens — add the
  `.flightdirector/secrets*` glob to `.gitignore` before writing it, so backups and variants
  (`secrets.local.json`, `secrets.json.bak`, `secrets-new.json`, …) can't leak either. Ignore
  `.flightdirector/config.local.json` in the same edit — it is the per-machine override of
  `config.json` and must never be committed either.
- **Never hand-convert an older config.** A config below schema 3 (a singular `issues` object, a
  top-level `labels` map) is migrated by `flight reconcile`, which the runtime preflight runs.
- **Never write a `config.json` without a default tracker.** A schema-3 config needs a non-empty
  `issueTrackers` with exactly one `default: true`; on a fresh repo the config is assembled as a
  candidate and installed by add-an-issue-tracker together with the first tracker.
- **Never rename, recolor, or delete an existing label**, and never create `area/*` labels without
  the user's input — add-an-issue-tracker's label reconcile only adds, after one preview.
- **A re-run preserves.** Existing trackers, their refs and the default stay as they are; only
  absent answers are asked (the gap check).

## Step 0: Read what the repo already tells you — offer, then confirm

Before asking anything from scratch, **look at what the repo already tells you** and lead with a
confirm-and-go offer. Detection is a shortcut, not a gate: everything below has a manual fallback
(Steps 1–4), so when a signal is missing or ambiguous, say so and drop through to the prompts —
never guess a backend into the config.

**First, reuse an existing flight config.** If `.flightdirector/config.json` already exists, the
runtime preflight's `flight reconcile` has already brought it to schema 3 (moving a legacy
`issues`/`labels` pair into one default tracker, and `config.local.json` and `secrets.json`
along with it). If reconcile **refused** instead — mixed legacy and named forms, a newer schema,
a config with no backend at all — show its message and resolve that first: a config with no
backend needs only the missing `code.backend` (Step 1), after which reconcile is re-run;
everything else follows the message's instructions. Never convert by hand, and keep
`legacyIssueTracker` and the `issues` stub (`"backend": "requires-newer-flight"`) if the
migration wrote them.

Then treat the config as the source of truth: show its code coordinates, stage pipeline and
trackers (`flight config '.issueTrackers[] | "\(.ref)\(if .default then " [default]" else "" end) — \(.name) (\(.backend))"'`)
back to the user and ask whether to keep or revise them. Don't re-ask for values it already
has — but **"keep it" does not mean "skip the questions"**: it means carry forward every
question the config already answers, then run the **gap check** below and ask only the ones it
doesn't. Either way, check the agent instructions (`AGENTS.md` / `CLAUDE.md`) for the backend
breadcrumb (Step 6) — repos set up before that step existed won't have one, and a re-run is how
they retrofit it.

**The gap check — ask only what the config has no explicit answer for.** Every question this
skill owns maps to a config key. On a re-run, for each one: the key is **present** (with any
value — `false` and `null` count) → skip the question; the key is **absent** → ask it, exactly as
a first run would, and **write the answer down even when it is "no"** so the next re-run doesn't
ask again. This is the whole contract — it is what lets a repo set up before a question existed
pick that question up on its next re-run, and it is why a declined option is recorded as an
explicit `false` rather than left out.

| Question | Config key(s) | Asked in |
|---|---|---|
| Code backend + coordinates | `code.backend`, `code.owner`, `code.repo`, `code.api` | Step 1 |
| Code API token | `code.token` in `.flightdirector/secrets.json` | Step 2 |
| Stage pipeline | `code.stages` | Step 3 |
| Worker model for `queue-batches` | `code.queueBatches.defaultModel` | Step 4 |
| Prompt ledger | `code.promptLog.enabled` | Step 4 |
| Repo check command (preflight gate) | `code.preflight` (a command string, or `false` if declined) | Step 4 |
| Issue trackers | `issueTrackers` — each entry's own questions (ref, aliases, credential, starting status `labels.status.new`, labels) are add-an-issue-tracker's gap check | Step 5 |

A question added to this skill later gets a row here and follows the same rule; the rule is the
contract, not this list. Write only the keys the gap check filled — never rewrite the keys you
carried forward (Step 4's "don't clobber hand-edits"). The starting-status question moved to
add-an-issue-tracker because it is **per tracker**: one tracker may use `status/new`, another
may have declined.

**Migrate a legacy `.lightspeed/` folder.** If `.lightspeed/config.json` exists but
`.flightdirector/config.json` does not, the repo was configured before the plugin was renamed. Offer
the move (show the commands, wait for a yes), then run:

```
git mv .lightspeed/config.json .flightdirector/config.json   # tracked → keeps history
mv .lightspeed/secrets* .flightdirector/                     # gitignored → plain mv (any secrets file)
rmdir .lightspeed 2>/dev/null || true                        # leave it if anything else is inside
```

Then add `.flightdirector/secrets*`, `.flightdirector/config.local.json` and
`.flightdirector/batches/` to `.gitignore` (keep the
old `.lightspeed/…` lines if other branches still use them), run `flight reconcile --harness
<claude|codex>` so the moved config reaches schema 3, and continue as a re-run over the existing
config. Until the move happens the dispatcher keeps working off the legacy folder with a
one-line notice on stderr — so never block a user on the migration.

**Retrofit-only shortcut:** when the user just wants the breadcrumb added to an
already-configured repo ("add the flight note/breadcrumb", "put it in AGENTS.md"), read the
backends and tracker refs from the existing config and jump straight to Step 6 — no label
reconcile needed.

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

**Detect issue-tracker signals** (for the first tracker, handed to add-an-issue-tracker in
Step 5). By default the issues live on the code repository. Look for signs they don't:
- **Jira** — project keys shaped like `ABC-123` in recent commit subjects or branch names
  (`git log --oneline -50`, `git branch -a`) strongly suggest a Jira tracker (ref `ABC`, the
  project key) paired with the git `code` backend.
- Otherwise assume the tracker is the code repository and only confirm.

**Then offer, and let the user confirm-and-go.** Summarize what you found and propose the setup in
one shot, e.g.:

```
Detected from this repo:
  code     → github   (remote is github.com/acme/widgets)
  tracker  → jira     KAN, the default (commits reference KAN-123, KAN-456)

Set it up this way? [y] — or tell me what to change.
```

On `y`, carry these detected values straight into Steps 1–5 (skip the questions they already
answer). If detection was **inconclusive** (no remote, unrecognized host, conflicting signals) or
the user wants something different, fall back to the manual flow below and ask normally.

**Supported backends to offer:** `github`, `gitlab`, `forgejo` for `code`; any of those **or**
`jira` for an issue tracker (Jira is a tracker only, always paired with a git code backend). All
four are implemented.

## Step 1: Code coordinates + instance

If Step 0 detected and the user confirmed the coordinates, carry them forward — this step is the
**fallback** when detection was inconclusive or declined. Autodetect from the git remote that
points at the host: `git remote get-url origin` → parse `owner/repo` and the host. The API base
follows the backend (see the Step 0 table): `https://<host>/api/v1` for Forgejo, `/api/v4` for
GitLab, `https://api.github.com` for GitHub. **Confirm all three with the user** (owner, repo,
api). Issue coordinates are not asked here — add-an-issue-tracker proposes the code repository
as the first tracker and asks only if the issues live elsewhere.

## Step 2: Code token → secrets file

The dispatcher needs a per-repo API token for the code repository. Ask the user to create a
**least-privilege** token on the host — just `write:repository` and `write:issue` (the latter
also covers labels), not an all-orgs admin token. These two work with a token restricted to a
single repository; do **not** add `write:misc` (unused, and Forgejo rejects it on a single-repo
token). The exact scopes and the token-creation steps differ per backend (GitHub, GitLab,
Forgejo) — see [backends.md](../../references/backends.md) for the per-backend token walkthrough,
and [flight-setup.md](../../references/flight-setup.md) for the config schema. Then:

1. Create the config folder: `mkdir -p .flightdirector`.
2. Add `.flightdirector/secrets*`, `.flightdirector/config.local.json`, `.worktrees/`, **and**
   `.flightdirector/batches/` to `.gitignore` **first** (create `.gitignore` if needed). Ignore
   the whole `secrets*` family, not just `secrets.json` — a second token file or a backup made
   while rotating a token is otherwise one `git add -A` from being committed. `.worktrees/` is
   where `working-an-issue` creates per-issue git worktrees. `.flightdirector/batches/` holds
   `queue-batches`' per-run batch manifests **and** the retained work identities under
   `batches/work-items/` (which tracker each branch's issue belongs to) — local, durable state
   (not secrets) that must be ignored so it doesn't appear as untracked content, and that must
   not be deleted wholesale. Add `.flightdirector/prompt-log.jsonl` too if the user opts into
   the prompt ledger in Step 4 (it holds prompt text).
3. Write `.flightdirector/secrets.json` — or, on a re-run, merge into it, keeping every
   `issueTrackers` credential and unknown key:
   ```json
   { "code": { "token": "<the token>" } }
   ```
   Tracker credentials are added under `issueTrackers.<REF>` by add-an-issue-tracker; a tracker
   on the code repository normally shares this token (`"credentialRef": "code"`).
4. Verify the token as soon as a config exists — on a re-run now, on a fresh repo right after
   Step 5 installs it: `flight auth check`. It is read-only, and it reports identity, repo
   reach, and each capability the skills need — so a wrong scope, a wrong `owner`/`repo`, or an
   expired token surfaces here instead of halfway through the label reconcile. A candidate
   token can be checked before it goes live with
   `flight auth check --secrets .flightdirector/secrets-new.json`. (Trackers are checked with
   `flight auth check --tracker <REF>`; `--axis issues` still checks the default tracker.)

## Step 3: Workflow preferences — stage pipeline preset

Ask which promotion pipeline the repo uses. Present three options:

**(a) Simple — `develop → main`**
Feature branches fork from `develop`, integrate there directly, then promote to `main` via PR:
```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge" },
  { "name": "main",    "merge": "pr",     "strategy": "merge", "issueStatus": "done" }
]
```

**(b) Multi-stage — `develop → qa → main`**
Same as (a) but an intermediate `qa` branch sits between integration and production. Each stage
carries an `issueStatus` so the board mirrors the issue's position; issues stay open until the
terminal stage (`main`), where they close:
```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
  { "name": "qa",      "merge": "pr",     "strategy": "merge", "gate": "post-merge-qa", "issueStatus": "qa" },
  { "name": "main",    "merge": "pr",     "strategy": "merge", "issueStatus": "done" }
]
```

**(c) Advanced / custom** — capture a custom ordered list of stages (name + per-hop `merge` and
optional `gate`), or tell the user they can hand-edit `code.stages` in `.flightdirector/config.json`
afterward per [flight-setup.md](../../references/flight-setup.md).

**Defaults explained briefly:**
- Feature branches fork from `stages[0]` (the first integration branch).
- `merge: "direct"` integrates by merging locally; `merge: "pr"` opens a pull request for the hop.
- `strategy` (per stage, optional) is how a `pr` hop's PR is merged into that stage: `merge` |
  `squash` | `rebase`, default `merge`. It applies to `pr` hops only — a `direct` hop always
  merges with `--no-ff`. See [flight-setup.md](../../references/flight-setup.md).
- `gate: "pre-merge"` runs checks before merging; `gate: "post-merge-qa"` merges then verifies in
  that environment. The gate governs *merging only*.
- `issueStatus` (per stage, optional) sets the issue's status label on entering that stage — a
  status **role**, resolved through the label map of the tracker the issue belongs to;
  `closesIssues` (per stage, optional) overrides the default close point, which is the terminal
  stage. Together they drive issue lifecycle independently of `gate`. The terminal stage closes
  issues by default; `closesIssues: false` there (with an `issueStatus`) leaves them open when
  the real release happens after the last branch. See
  [flight-setup.md](../../references/flight-setup.md).
- The user can always edit `.flightdirector/config.json` later to adjust stages.

## Step 4: Repo preferences and the config skeleton

On a **fresh repo**, assemble the repo-wide part of the config as a **candidate file outside
`.flightdirector/`** (e.g. `CFG="$(mktemp)"`) — it has no tracker yet, so it is not a valid
config and must not be installed on its own. Schema 3, the `issues` stub that makes an older
Flight stop loudly instead of acting on the code repository, and no top-level `labels`, no real
`issues` object and no `legacyIssueTracker` (migration writes that; a fresh config never has
one). Example for preset (b):

<!-- fresh-config-skeleton -->
```json
{
  "schemaVersion": 3,
  "code": {
    "backend": "forgejo",
    "owner": "acme",
    "repo": "widget",
    "api": "https://git.example.com/api/v1",
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa", "merge": "pr", "strategy": "merge", "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main", "merge": "pr", "strategy": "merge", "issueStatus": "done" }
    ],
    "queueBatches": { "defaultModel": ["sonnet", "luna"] },
    "promptLog": { "enabled": false },
    "preflight": "./scripts/run-checks.sh"
  },
  "issues": {
    "backend": "requires-newer-flight",
    "note": "Issue tracking uses issueTrackers (config schema 3); update Flight to use it."
  }
}
```

The harness stamp (`harnesses.<harness>.plugins.flight.reconciledWith`) is written by the
`flight reconcile` that runs once the config is installed — don't write it by hand. On a
**re-run**, the existing `config.json` is the file: write only the keys the gap check filled.

**Ask for the worker model.** Skip this if `code.queueBatches.defaultModel` is already present
(gap check, Step 0) — a single model name from an older setup counts as answered. Otherwise ask
which models `queue-batches` should give its worker agents, **in order of preference**
(overridable per run). Each harness can only dispatch its own models, and `queue-batches` uses
the first entry the running harness can use, so suggest one entry per harness the team works
from: a Claude model followed by a Codex model, e.g. `["sonnet", "luna"]`. Write the
answer to `code.queueBatches.defaultModel` as an array (a single name is fine too). Changing it later
retargets all future parallel runs (e.g. to a newer model) without editing the skill. You can also add an optional `code.zones` array later — see
[flight-setup.md](../../references/flight-setup.md) — to make `queue-batches` schedule
deterministically instead of inferring zones.

**Offer the prompt ledger (opt-in).** Skip this if `code.promptLog.enabled` is already present
(gap check, Step 0). Otherwise ask: *"Log each agent turn's prompt, tokens, and estimated cost to
`.flightdirector/prompt-log.jsonl` so issue ledgers are measured rather than estimated? (Both
Claude Code and Codex write the same file; it stays local and gitignored.)"* If yes, add
`"promptLog": { "enabled": true }` under `code` and make sure `.flightdirector/prompt-log.jsonl`
is in `.gitignore` (Step 2). If no, write `"promptLog": { "enabled": false }` — an explicit
"no" is an answer; a missing key is an unasked question and gets asked again next re-run. The
plugin's bundled hooks do the rest — nothing else to install.

**Offer a repo check command — the preflight gate (opt-in).** Skip this if `code.preflight` is
already present (gap check, Step 0). Otherwise look for the command the repo already uses to check
itself — a `scripts/run-checks.sh` or `scripts/test.sh`, a `test` script in `package.json`, a
`check`/`test` target in a `Makefile`, what the CI workflow runs — and ask: *"Should flight run a
check command before it merges work? Without one, a `direct` hop (usually `feature → develop`) has
no gate but you saying 'promote'. Suggested: `<the command you found>`."* Offer a suggestion only
when you actually found one; otherwise ask what they run, and make clear "none" is a fine answer.

If yes, write `"preflight": "<command>"` under `code`. Before recording it, check the two things
the gate depends on: the command runs **from a worktree root, not just the main checkout** (no
hard-coded absolute paths), and its **exit code is the verdict** (zero passes, anything else
stops the merge — nothing parses its output). `promoting-a-branch`, `promoting-branches` and
`queue-batches` then run it before merging; a `pr` hop still watches CI afterwards. **If no,
write `"preflight": false`** — recorded like every other declined option; every reader uses
`.code.preflight // empty`, so `false` behaves exactly like leaving it out. Full semantics:
[flight-setup.md](../../references/flight-setup.md) → *Repo preflight gate*.

**Leave the user's other hooks alone.** Flight's hooks are plugin-bundled and write only their
own file, so any prompt-related hook the user already runs (in `.claude/settings.local.json`,
`settings.json`, or Codex's config) — an audit log, a cost dashboard, another plugin's telemetry
— coexists with the ledger. Never edit, disable, or advise deleting such hooks; if you notice
one, you may mention it and move on. Details: [prompt-log.md](../../references/prompt-log.md).

If a config already exists, show the diff of the keys the gap check filled in and confirm before
writing — don't clobber hand-edits or rewrite carried-forward keys.

## Step 5: Issue trackers — delegate to add-an-issue-tracker

**REQUIRED SUB-SKILL:** run [add-an-issue-tracker](../add-an-issue-tracker/SKILL.md) — once per
tracker it needs to touch:

- **Fresh repo (no trackers):** hand it the candidate `CFG` from Step 4, the confirmed code
  coordinates, and any tracker signal from Step 0. It collects the first tracker — which
  becomes **the default** — merges it into the candidate, installs the result as
  `.flightdirector/config.json`, runs the deferred `flight reconcile`, verifies the tracker's
  credential, and reconciles its labels. Then run Step 2's `flight auth check` for the code
  token.
- **Re-run:** hand it each configured tracker in turn for **its** gap check (a migrated tracker
  typically still lacks `aliases` and, if the repo never answered it, `labels.status.new`).
  Never append a replacement tracker, change a `ref`, or move the default.
- **"Add another tracker"** during setup, or at any time later: that is add-an-issue-tracker on
  its own. The existing default stays the default unless the user explicitly asks to change it.

From here the dispatcher works: `flight issues …` and `flight labels …` act on the default
tracker, or on the one named by `--tracker <REF>` or a qualified id (`KAN-12`).

## Step 6: Leave a backend breadcrumb in the agent instructions (AGENTS.md)

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

Append this block — with the *actual* backend, tracker refs and stage names from the config — to
the resolved file. Show it to the user before writing (it's their instructions file).

**Do not write a host into the block by default.** Agent-instruction files are committed and
travel with every clone and public mirror; a private forge's hostname doesn't belong there, and
the breadcrumb doesn't need it — its job is to stop agents reaching for `gh` and to point them at
the dispatcher, which reads the hosts from `.flightdirector/config.json`. Tracker **refs**
(`FJ`, `KAN`) are fine to name; their URLs are not. Name a host only if the user says the repo
is private and asks for it spelled out.

```markdown
## Issue tracking — flight

This repo manages issues/PRs/CI with the **flight** plugin. The backend is
**<backend>** — NOT GitHub — so never reach for `gh` here. Issues live in the
named tracker(s) **<REF> (default, <backend>)**[, **<REF2> (<backend>)**]. Hosts,
coordinates, the stage pipeline, and each tracker's label names live in
`.flightdirector/config.json` (tokens in `.flightdirector/secrets.json`,
git-ignored). Act through the flight skills (working-an-issue,
promoting-a-branch, filing-issues, …) or the dispatcher: `flight <group> <verb>`.

Workflow red lines — these hold for every model and survive context
compaction; re-read them before any git write, especially if the session's
earlier instructions were summarized away or the model changed mid-session:

- Resolve an issue once (`flight issues resolve --number <input>`; a bare
  `#N` means the default tracker) and pass its tracker on every later issue
  and label command (`--tracker <REF>`), so the work never drifts to another
  tracker.
- Each issue is worked on its own `feature/<ref>-<N>-<slug>` branch (e.g.
  `feature/<ref>-12-fix-login`) in its own `.worktrees/<ref>-<N>-<slug>`
  worktree — NEVER commit directly to the integration branch (`<stages[0]>`)
  or any later stage. Older `feature/<N>-<slug>` branches still work.
- Every git command is `git -C "<worktree path>" …` — a bare `git` is a bug,
  even when you think you're in the right directory; the shell's cwd persists
  between tool calls.
- Merging is gated on the user's explicit go-ahead ("promote"); it happens
  through the promoting-a-branch skill, never by hand.
- Keep the issue's status label honest at every transition
  (in-progress → to-test → …) via `flight issues set-status --tracker <REF>`.
```

For a GitHub-backend repo, keep the block but drop the "NOT GitHub" clause and say plainly that
issue actions still go through the dispatcher/skills, not raw `gh`. When code and issues live on
different backends, name both (e.g. "code on Forgejo; issues in Jira tracker `KAN`, the
default").

**Offer a local-notes file for anything private.** Notes that must not be published — the real
host of a self-hosted forge, homelab caveats, personal conventions — go in a **gitignored
`AGENTS.local.md`** next to `AGENTS.md`, and `AGENTS.md` gets a short section that pulls it in
for both harnesses:

```markdown
## Additional local notes

Claude:
@AGENTS.local.md

Codex:
Please read the file AGENTS.local.md if it exists and treat its contents as if
it were in this file directly.
```

Claude Code resolves the nested `@AGENTS.local.md` import (a missing import is silently skipped,
so public clones lose nothing); Codex has no import mechanism, so the plain-prose instruction
does the same job. If the user wants this, add `AGENTS.local.md` to `.gitignore` **before**
creating the file, then create it with a heading and the notes they dictate.

**Idempotent:** if either file already has an "Issue tracking — flight" section — or the
pre-rename "Issue tracking — lightspeed" one — update it in place (the backend or trackers may
have changed, a pre-tracker block names unqualified `feature/<N>-<slug>` branches, and the old
block names the `lightspeed` dispatcher) rather than appending a duplicate. If the existing block
lives in `CLAUDE.md` and the repo also has (or is getting) an `AGENTS.md`, offer to move it there
so there is one copy, not two that drift.

## Common mistakes

- Writing `.flightdirector/secrets.json` without gitignoring `.flightdirector/secrets*` first — that
  leaks the token.
- Installing the Step 4 skeleton as `config.json` before a tracker is merged into it — a schema-3
  config without `issueTrackers` is invalid, and `reconcile` would try to migrate it.
- Hand-converting a schema-2 config (moving `issues`/`labels` yourself) instead of letting
  `flight reconcile` do it — it also converts `config.local.json`, `secrets.json` and binds the
  existing branches.
- Adding `legacyIssueTracker` or a top-level `labels` map to a fresh config.
- Asking the starting-status question here: it is per tracker, and add-an-issue-tracker owns it.
- Treating "reuse the existing config" as "jump to labels". A re-run must still run the gap
  check (Step 0) — a repo set up before a question existed never gets asked it otherwise, and
  the ledger (or whatever the newest option is) silently stays off.
- Leaving a declined option out of the config instead of writing it as `false`. Absent means
  "never asked", so the user gets the same question on every re-run.
- Letting a re-run make a new tracker, or the most recently mentioned one, the default.
