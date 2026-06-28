# lightspeed setup

Shared by all lightspeed skills. Every backend operation goes through the **dispatcher** —
`"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" <group> <verb> …` — which calls the backend's REST
API with `curl`. There is no MCP server, and no token handling in the skills themselves. See
[ADR 0001](../../docs/adr/0001-curl-over-mcp-and-adapter-architecture.md) for why, and
[adapter-contract.md](adapter-contract.md) for the full verb set.

## Prerequisites

- `curl` and `jq` on `PATH`.
- A per-repo API token (least privilege — see below). Nothing to install or run.

## Two config files at the repo root

### `.lightspeed.json` — committable

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
      { "name": "develop", "merge": "direct", "gate": "pre-merge" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa" },
      { "name": "main",    "merge": "pr" }
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
- Note: `trunkBranch`, `mergeStrategy`, and `gate` (single-value top-level fields) are
  superseded by `stages`. `trunkBranch` is still read as a fallback for `stages[0]` for
  backwards compatibility.

### `.lightspeed.secrets.json` — gitignored

Just the token(s), one per axis, with the same `code → issues` inheritance:

```jsonc
{ "code": { "token": "…" }, "issues": { "token": "…" } }  // omit issues to share code's token
```

**This file must be gitignored** — it holds a credential. If lightspeed finds it tracked by
git, it warns loudly on every run (it does not refuse). Add `.lightspeed.secrets.json` to your
`.gitignore`.

Token precedence: `LS_TOKEN` / `FORGEJO_TOKEN` in the environment override everything; otherwise
the secrets file (the axis's token, inheriting `code`'s).

## Least-privilege tokens

The point of a per-repo token is blast radius: one scoped to a single repo can't touch another,
so a misfire fails with `403` instead of writing to the wrong place. On Forgejo, create a token
with only the scopes the skills need — `write:repository`, `write:issue`, and `write:misc` (for
labels) — not an all-orgs admin token.

## How resolution works

The dispatcher picks the **axis** from the group — `issues`/`labels` → `issues.*`,
`pr`/`ci` → `code.*` — resolves that axis's backend, coordinates, and token (inheriting `code`),
exports them as `LS_*`, and execs `adapters/<backend>/<group>`. Skills therefore never pass
owner/repo/token; they just name the verb. `bootstrapping-labels` autodetects and writes the
coordinates from the git remote on first run, so in the normal case you set nothing by hand.

## Context note

List verbs project with `jq` to minimal TSV before anything reaches the conversation, so listing
issues is cheap on context. Still pass a sane `--limit` and paginate rather than pulling hundreds
at once.
