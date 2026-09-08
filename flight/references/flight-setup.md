# Flight setup

Shared by all flight skills. Every backend operation goes through the **dispatcher** —
`flight <group> <verb> …` — which calls the backend's REST
API with `curl`. There is no MCP server, and no token handling in the skills themselves. See
[ADR 0001](../../docs/adr/0001-curl-over-mcp-and-adapter-architecture.md) for why, and
[adapter-contract.md](adapter-contract.md) for the full verb set.

## Prerequisites

- `curl` and `jq` on `PATH`.
- `python3` (standard library only) — **only** if you turn on the prompt ledger
  (`code.promptLog.enabled`); nothing else in flight needs it.
- A per-repo API token (least privilege — see below). Nothing to install or run.

## Two config files in the `.flightdirector/` folder

> **Renamed folder.** Before the plugin was renamed from `lightspeed` to `flight` this folder was
> `.lightspeed/`. The dispatcher still reads a legacy `.lightspeed/config.json` when
> `.flightdirector/config.json` is absent (printing a one-line deprecation notice on stderr), and
> resolves `secrets.json` independently so a half-migrated repo keeps working. Migrate with
> `git mv .lightspeed .flightdirector` plus a manual `mv` of the gitignored `secrets*` files, or
> re-run `setting-up-a-repo`. `.flightdirector/` is shared by every Flight Director plugin.

### `.flightdirector/config.json` — committable

Backend, coordinates, and preferences, across two independent axes:

- **`code`** — the required base: where code, change-requests (PRs), and CI live.
- **`issues`** — optional; **inherits from `code`** (backend, owner, repo, api, token) when
  omitted. Override it for split setups (issues tracked in a different repo or backend), or
  drop it entirely if you don't track issues.

```jsonc
{
  "schemaVersion": 2,
  "harnesses": {
    "claude": { "plugins": { "flight": { "reconciledWith": "0.11.0" } } },
    "codex":  { "plugins": { "flight": { "reconciledWith": "0.11.0" } } }
  },
  "code": {
    "backend": "forgejo", "owner": "acme", "repo": "widget",
    "api": "https://git.example.com/api/v1",
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main",    "merge": "pr",     "strategy": "merge", "issueStatus": "done" }
    ]
  },
  "issues": { "backend": "forgejo", "owner": "acme", "repo": "planning" }, // omit to inherit code
  "labels": {
    "status": {
      "in-progress": "status/in progress",
      "to-test":     "status/to test",
      "blocked":     "status/blocked",
      "deferred":    "status/deferred"
    },
    "model": { "opus": "model/opus", "sonnet": "model/sonnet",
               "haiku": "model/haiku", "fable": "model/fable",
               "sol": "model/sol", "terra": "model/terra",
               "luna": "model/luna", "astra": "model/astra" }
  }
}
```

- **`schemaVersion`** — version of the committable Flight config schema. Schema 2 nested the
  reconcile stamp under `plugins` (see below); schema 1 configs migrate themselves on the next
  reconcile, so there is no manual step.
- **`harnesses.<harness>.plugins.<plugin>.reconciledWith`** — installed version of that Flight
  Director plugin that last reconciled this config from that harness (`claude` or `codex`). The
  stamp is scoped per harness **and** per plugin because `.flightdirector/` is shared by the whole
  family: without the `plugins.<name>` level, two plugins would overwrite one key and each would
  compare its version against the other's. A schema 1 config's bare
  `harnesses.<harness>.reconciledWith` is flight's stamp by definition — `flight reconcile` moves
  it to `plugins.flight.reconciledWith` and drops the old key. Unknown keys are preserved and an
  older plugin never downgrades a newer stamp *of the same plugin*. Model discovery is not a
  migration: missing `model/*` labels are created lazily when work-ledger entries are finalized.

- **`api`** — the backend's API base, *not* repo-scoped; the adapter appends the repo path. Its
  shape is per backend: Forgejo/Gitea `https://<host>/api/v1`, GitHub `https://api.github.com`,
  GitLab `https://<host>/api/v4`, Jira the site base. The example above is a Forgejo repo; the
  same file pointed at GitHub or GitLab differs **only** in `backend` and `api` — see the
  per-backend sections below and [backends.md](backends.md).
- **`labels`** — maps each **role** to the **actual label name this repo uses**. Skills and
  adapters speak roles and names; turning a name into its numeric id happens *inside* the
  adapter, so nothing above the adapter ever deals in label ids.
- **`stages`** — ordered promotion pipeline. `stages[0]` is the first integration branch;
  feature branches fork from it. Each hop carries its own `merge` (`direct`|`pr`), optional
  `strategy` (see below) and optional `gate` (`pre-merge`|`post-merge-qa`, default
  `pre-merge`). Consumed by `working-an-issue` (uses `stages[0]`) and `promoting-a-branch`
  (one hop at a time).
- **`strategy`** (per stage, optional) — the merge strategy used when a `pr` hop's PR is merged
  into this stage: `merge` | `squash` | `rebase`. **Defaults to `merge`.** A true merge is the
  default because Flight's model is one branch per issue promoted through a chain of stages:
  the same commits travel `feature → develop → qa → main`, and preserving them keeps each
  stage's history comparable, keeps `git log <target>..HEAD` (how `promoting-a-branch` finds an
  issue's commits) meaningful at every hop, and avoids the duplicate-commit churn that squashing
  or rebasing at one hop causes at the next. Set `"strategy": "squash"` on a stage whose repo
  convention is a linear one-commit-per-PR history. Read it with:
  ```
  flight config '.code.stages[<i>].strategy // "merge"'
  ```
  It applies to `pr` hops only — a `direct` hop always merges with `--no-ff`.
- **`issueStatus`** (per stage, optional) — a **status role name** (a key in `labels.status`).
  On *entering* this stage, `promoting-a-branch` runs the atomic `issues set-status --status
  <role>` (adds the new status, drops the others in one call — the board can never show two
  states). Omit to leave the issue's status untouched on entry to this stage. Setting it on the
  **terminal** stage (e.g. `issueStatus: "done"`) relabels the issue as it closes, so a shipped
  issue shows `status/done` rather than keeping its last in-flight label (e.g. `status/qa`).
- **`closesIssues`** (per stage, optional, boolean) — **defaults to "true iff this is the
  terminal (last) stage."** Set explicitly to override: `false` on the terminal stage keeps
  issues open after the final stage; `true` on a non-terminal stage closes issues early at that
  stage (e.g. close at `develop`, treat `main` as a pure release cut). The `gate` field is
  orthogonal — it governs merge policy, not issue lifecycle.
- Note: `trunkBranch`, `mergeStrategy`, and `gate` (single-value top-level fields) are
  superseded by `stages` — the per-stage `strategy` field replaces a top-level `mergeStrategy`.
  For backwards compatibility a legacy `trunkBranch` is still read
  **first** if present; otherwise `stages[0].name` is used.

### queue-batches config (all optional)

Consumed only by the `queue-batches` skill; absent keys fall back safely.

```jsonc
"code": {
  // …existing keys (backend, owner, repo, api, stages)…
  "zones": [ { "name": "auth", "paths": ["src/auth/**"] } ],
  "queueBatches": { "defaultModel": "sonnet", "agentRulesFile": ".flightdirector/agent-rules.md" }
}
```

- `code.zones` — `[{ "name": "...", "paths": ["glob", ...] }]`. Disjoint file zones used to
  schedule parallel work so concurrently-running issues never touch the same paths. If omitted,
  `queue-batches` infers pseudo-zones from issue bodies at triage time and warns that the
  inferred zones are approximate.
- `code.queueBatches.defaultModel` — worker-agent model when the user gives no per-run override.
  Seeded by `setting-up-a-repo` during first-run setup; falls back to `sonnet` if unset.
- `code.queueBatches.agentRulesFile` — path (repo-relative) to a markdown file of repo-specific
  agent hard-rules / CI gotchas, injected verbatim into each worker prompt. Defaults to
  `.flightdirector/agent-rules.md`; if that file is absent, workers run with the skill's built-in
  safety rules only (no project-specific rules).

### Prompt ledger (optional, off by default)

```jsonc
"code": {
  "promptLog": { "enabled": true }
}
```

- `code.promptLog.enabled` — turns on the bundled prompt/cost logger for this repo. The plugin
  ships hooks for both harnesses; they run `flight prompt-log <mode>`, which exits silently unless
  this is `true`, so the switch is the only producer control. When on, every turn appends one
  record to `.flightdirector/prompt-log.jsonl` under the main worktree root (gitignore it — records contain prompt
  text) and `working-an-issue` sums them per session for the work-ledger comment via
  `flight prompt-log summary`. Schema, pricing, and semantics: [prompt-log.md](prompt-log.md).
- `.flightdirector/pricing.json` — optional per-repo pricing override/extension, merged on top of
  the bundled `flight/scripts/prompt-logger/pricing.json` (same shape).

### GitHub backend

Point an axis at GitHub by setting its `backend` + `api` in `.flightdirector/config.json`:

```jsonc
"code": {
  "backend": "github",
  "owner": "your-org-or-user",
  "repo": "your-repo",
  "api": "https://api.github.com",          // the API host itself — no version path
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

The token goes in the gitignored `.flightdirector/secrets.json` (`code.token`): a fine-grained PAT
scoped to the repo with Contents, Issues, and Pull requests read/write (plus Actions read if you
use `ci`), or a classic PAT with **repo** (+ **workflow**). `setting-up-a-repo` detects a
`github.com` remote and proposes this config for you. Full permission table in
[backends.md](backends.md#github-full-parity).

### GitLab backend

Point an axis at GitLab by setting its `backend` + `api`. `owner`/`repo` together form the
project path GitLab addresses by (subgroups belong in `owner`, e.g. `"group/sub"`):

```jsonc
"code": {
  "backend": "gitlab",
  "owner": "your-group",                    // subgroups allowed: "group/subgroup"
  "repo": "your-project",
  "api": "https://gitlab.com/api/v4",       // self-managed: https://gitlab.example.com/api/v4
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

The token goes in the gitignored `.flightdirector/secrets.json` (`code.token`), a GitLab personal or
project access token with the **api** scope. `pr` is a merge request and `ci` is pipelines (see
the [adapter contract](adapter-contract.md) → GitLab specifics for the `--strategy` and pipeline
nuances). Like GitHub, `setting-up-a-repo` does not yet offer GitLab as a backend choice —
configure GitLab repos by hand-editing `.flightdirector/config.json` for now.

### Jira backend (issues-axis only)

Jira is an issue tracker, not a git host, so it backs **only the `issues` axis** — pair it with a
git `code` backend (`pr`/`ci` keep resolving to `code`):

```jsonc
{
  "code":   { "backend": "github", "owner": "acme", "repo": "widget",
              "api": "https://api.github.com", "stages": [ { "name": "main", "merge": "pr" } ] },
  "issues": { "backend": "jira",
              "api": "https://your-site.atlassian.net",  // the site base, no /rest/api/3
              "project": "KAN",                            // the Jira project key
              "email": "you@example.com" }                 // for email:token Basic auth
}
```

Auth is HTTP **Basic** `email:api_token` (a classic Atlassian API token — not OAuth). The token
goes in `.flightdirector/secrets.json` under `issues.token`; the account email is `issues.email` in
config (or `LS_EMAIL` in the env). The dispatcher exports `LS_PROJECT` + `LS_EMAIL` alongside the
usual `LS_*`. See `adapter-contract.md` → **Jira backend specifics** for the identifier (key-as-id),
status-as-labels, close-as-transition, ADF, and thin-labels behaviours. `setting-up-a-repo` does
not yet offer Jira — configure it by hand-editing `.flightdirector/config.json` for now.

### `.flightdirector/secrets.json` — gitignored

Just the token(s), one per axis, with the same `code → issues` inheritance:

```jsonc
{ "code": { "token": "…" }, "issues": { "token": "…" } }  // omit issues to share code's token
```

**This file must be gitignored** — it holds a credential. If flight finds it tracked by
git, it warns loudly on every run (it does not refuse). Add the `.flightdirector/secrets*` glob to
your `.gitignore` — ignoring the whole family (`secrets.local.json`, `secrets.json.bak`,
`secrets-github.json`, editor swap copies) rather than the one exact filename.

Token precedence: `LS_TOKEN` or `FLIGHT_TOKEN` in the environment override everything
(`FORGEJO_TOKEN` is still honoured as the legacy name); otherwise the secrets file (the axis's
token, inheriting `code`'s).

## Least-privilege tokens

The point of a per-repo token is blast radius: one scoped to a single repo can't touch another,
so a misfire fails with `403` instead of writing to the wrong place. Scope the token to the one
repository or project wherever the backend allows it, and grant only what the skills call:

| Backend | Minimum |
|---|---|
| Forgejo/Gitea | `write:repository` (PRs, CI) + `write:issue` (issues **and** labels), restricted to the repo; no `write:misc` |
| GitHub | fine-grained PAT: Contents, Issues, Pull requests read/write; Actions read for `ci` |
| GitLab | project access token with the `api` scope (or a fine-grained per-project token) |
| Jira | unscoped API token — least privilege comes from the account's project role |

Where to create each token and the reasoning behind each minimum is in
[backends.md](backends.md).

## How resolution works

The dispatcher picks the **axis** from the group — `issues`/`labels` → `issues.*`,
`pr`/`ci` → `code.*` — resolves that axis's backend, coordinates, and token (inheriting `code`),
exports them as `LS_*`, and execs `adapters/<backend>/<group>`. Skills therefore never pass
owner/repo/token; they just name the verb. `setting-up-a-repo` autodetects and writes the
coordinates from the git remote on first run, so in the normal case you set nothing by hand.

## Context note

List verbs project with `jq` to minimal TSV before anything reaches the conversation, so listing
issues is cheap on context. Still pass a sane `--limit` and paginate rather than pulling hundreds
at once.
