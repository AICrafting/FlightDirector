# lightspeed setup

Shared by all lightspeed skills. Every backend operation goes through the **dispatcher** —
`"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" <group> <verb> …` — which calls the backend's REST
API with `curl`. There is no MCP server, and no token handling in the skills themselves. See
[ADR 0001](../../docs/adr/0001-curl-over-mcp-and-adapter-architecture.md) for why, and
[adapter-contract.md](adapter-contract.md) for the full verb set.

## Prerequisites

- `curl` and `jq` on `PATH`.
- A per-repo API token (least privilege — see below). Nothing to install or run.

## Two config files in the `.lightspeed/` folder

### `.lightspeed/config.json` — committable

Backend, coordinates, and preferences, across two independent axes:

- **`code`** — the required base: where code, change-requests (PRs), and CI live.
- **`issues`** — optional; **inherits from `code`** (backend, owner, repo, api, token) when
  omitted. Override it for split setups (issues tracked in a different repo or backend), or
  drop it entirely if you don't track issues.

```jsonc
{
  "code": {
    "backend": "forgejo", "owner": "acme", "repo": "widget",
    "api": "https://git.example.com/api/v1",
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main",    "merge": "pr",     "issueStatus": "done" }
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
               "haiku": "model/haiku", "fable": "model/fable" }
  }
}
```

- **`api`** — the instance API base (`…/api/v1`), *not* repo-scoped; the dispatcher appends
  `/repos/<owner>/<repo>`.
- **`labels`** — maps each **role** to the **actual label name this repo uses**. Skills and
  adapters speak roles and names; turning a name into its numeric id happens *inside* the
  adapter, so nothing above the adapter ever deals in label ids.
- **`stages`** — ordered promotion pipeline. `stages[0]` is the first integration branch;
  feature branches fork from it. Each hop carries its own `merge` (`direct`|`pr`) and optional
  `gate` (`pre-merge`|`post-merge-qa`, default `pre-merge`). Consumed by `working-an-issue`
  (uses `stages[0]`) and `promoting-a-branch` (one hop at a time).
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
  superseded by `stages`. For backwards compatibility a legacy `trunkBranch` is still read
  **first** if present; otherwise `stages[0].name` is used.

### queue-batches config (all optional)

Consumed only by the `queue-batches` skill; absent keys fall back safely.

```jsonc
"code": {
  // …existing keys (backend, owner, repo, api, stages)…
  "zones": [ { "name": "auth", "paths": ["src/auth/**"] } ],
  "queueBatches": { "defaultModel": "sonnet", "agentRulesFile": ".lightspeed/agent-rules.md" }
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
  `.lightspeed/agent-rules.md`; if that file is absent, workers run with the skill's built-in
  safety rules only (no project-specific rules).

### GitHub backend

Point an axis at GitHub by setting its `backend` + `api` in `.lightspeed/config.json`:

```jsonc
"code": {
  "backend": "github",
  "owner": "your-org-or-user",
  "repo": "your-repo",
  "api": "https://api.github.com",          // note: no /api/v1 (that's Forgejo)
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

The token goes in the gitignored `.lightspeed/secrets.json` (`code.token`), a GitHub PAT with
**repo** scope (+ **workflow** if you use `ci`). `setting-up-a-repo` does not yet offer GitHub
as a backend choice — configure GitHub repos by hand-editing `.lightspeed/config.json` for now.

### `.lightspeed/secrets.json` — gitignored

Just the token(s), one per axis, with the same `code → issues` inheritance:

```jsonc
{ "code": { "token": "…" }, "issues": { "token": "…" } }  // omit issues to share code's token
```

**This file must be gitignored** — it holds a credential. If lightspeed finds it tracked by
git, it warns loudly on every run (it does not refuse). Add `.lightspeed/secrets.json` to your
`.gitignore`.

Token precedence: `LS_TOKEN` / `FORGEJO_TOKEN` in the environment override everything; otherwise
the secrets file (the axis's token, inheriting `code`'s).

## Least-privilege tokens

The point of a per-repo token is blast radius: one scoped to a single repo can't touch another,
so a misfire fails with `403` instead of writing to the wrong place. On Forgejo, create a token
with only the two scopes the skills need — `write:repository` (PRs, CI) and `write:issue` (issues
**and labels**) — not an all-orgs admin token. These two are compatible with a token *restricted
to a single repository*; do **not** add `write:misc` — the skills don't use it, and Forgejo won't
let you combine `write:misc` with a single-repo restriction.

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
