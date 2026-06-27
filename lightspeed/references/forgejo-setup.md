# Forgejo setup (shared by both skills)

Both `filing-issues` and `triaging-issues` operate against a Forgejo repo **through
the forgejo MCP server** — they call `mcp__forgejo__*` tools, never raw HTTP. There
is no curl and no token handling in these skills. (Numeric label IDs are still needed
when *adding/removing* labels on an issue — see the labels section below.)

## Prerequisite: the forgejo MCP server

These skills assume goern's Forgejo MCP server is installed and registered:
<https://codeberg.org/goern/forgejo-mcp>

Install it (Go binary, AUR, Nix, or container — see that repo's README) and register
it in your MCP client. **The server MUST be registered under the name `forgejo`**, so
its tools surface as `mcp__forgejo__create_issue`, `mcp__forgejo__list_repo_issues`,
etc. If you register it under a different name, the tool names change and these skills
won't find them.

Example stdio registration:

```json
{
  "mcpServers": {
    "forgejo": {
      "command": "forgejo-mcp",
      "args": ["--transport", "stdio", "--url", "https://git.example.com"],
      "env": { "FORGEJO_ACCESS_TOKEN": "${FORGEJO_ACCESS_TOKEN}" }
    }
  }
}
```

This is a **documented prerequisite, not a bundled server** — the plugin declares no
MCP server of its own, on purpose. Bundling a second `forgejo` declaration would
collide with the one you already run, and the plugin can't pin or ship a third-party
binary anyway. Install it once, globally; these skills just use it.

## Repo coordinates (owner + repo)

Every `mcp__forgejo__*` call needs an `owner` and a `repo`. These are **not secrets** (the
token is — and it stays in the MCP server config, never here), and they're inherently
per-repo, so their home is the per-repo `.lightspeed.json` (below).

`bootstrapping-labels` fills them in by reading the git remote that points at your Forgejo
host (`git remote get-url …` → `owner/repo`) and asking you to confirm. Precedence the
skills use to resolve them:

1. `FORGEJO_OWNER` / `FORGEJO_REPO` env vars, if set (an explicit override)
2. `owner` / `repo` in `.lightspeed.json`
3. Autodetect from the git remote
4. Ask

So in the normal case you set nothing — bootstrap detects, confirms, and writes them.

## Labels: creating uses names, adding/removing uses IDs

Two different conventions, and getting them mixed up causes silent no-ops:

- **Creating a label** (`mcp__forgejo__create_repo_label`) takes a **name** + color. No ID.
- **Creating an issue** (`mcp__forgejo__create_issue`) takes **no labels at all** — create
  the issue first, then attach labels against its index.
- **Adding/removing labels on an issue** (`mcp__forgejo__add_issue_labels`,
  `remove_issue_labels`) take **numeric label IDs** (comma-separated), *not* names. A name
  passed here silently no-ops.

So before any add/remove, resolve names → IDs:

```
mcp__forgejo__list_repo_labels(owner, repo)   # returns each label's name AND numeric id
```

Build a name→id map from that result and pass the IDs. The IDs are **per-instance** — an
id from one repo means nothing on another, so always resolve against the target repo. A
once-per-session lookup is enough; the IDs are stable within a repo.

## Per-repo config (`.lightspeed.json`)

Repo-specific preferences live in a `.lightspeed.json` file at the repo root.
`bootstrapping-labels` **writes** it (asking the questions it needs); the other skills
**read** it. If it's absent, skills fall back to the defaults noted below. Commit it or
gitignore it — your call.

```json
{
  "owner": "cerebralgardens",
  "repo": "meshcore_lib",
  "trunkBranch": "develop",
  "mergeStrategy": "pr",
  "labels": {
    "status": {
      "in-progress": "status/in progress",
      "awaiting-test": "status/qa",
      "blocked": "status/blocked",
      "deferred": "status/deferred"
    },
    "model": {
      "opus": "model/opus", "sonnet": "model/sonnet",
      "haiku": "model/haiku", "fable": "model/fable"
    }
  }
}
```

- **`trunkBranch`** — the branch `working-an-issue` merges into. Default `develop` (also
  common: `main`). May instead come from `FORGEJO_TRUNK_BRANCH`.
- **`mergeStrategy`** — `"pr"` (open/merge a Forgejo pull request) or `"direct"` (local git
  merge into the trunk branch). `working-an-issue` branches on this. Default `"direct"`.
- **`labels`** — maps each **role** to the **actual label name this repo uses**. This is how
  the plugin respects your existing conventions: if your repo already calls the awaiting-test
  state `status/qa`, this map says so, and every skill uses `status/qa` — not the plugin's
  `status/to test`. Bootstrap fills this in by adopting equivalents it finds (see
  [default-labels.md](default-labels.md) for each role's recognized equivalents).

**Resolving a role to a label at runtime:** read the role's name from this config; if the
config is missing, match the role's default name or any of its equivalents (from
default-labels.md) against `list_repo_labels`, and use whichever the repo actually has. Then
resolve that name to its numeric ID for add/remove calls.

- **`owner`/`repo`** — the repo coordinates (see above). Autodetected from the git remote
  during bootstrap; `FORGEJO_OWNER`/`FORGEJO_REPO` override if set.

## Status-label convention (for the workable filter)

Both `triaging-issues` (which excludes non-pickable work) and `working-an-issue` (which
transitions issues through these states) use one status set:

- `status/in progress` — already in flight
- `status/to test` — built, awaiting the user's verification
- `status/blocked` — can't be started
- `status/deferred` — intentionally not now

`working-an-issue` moves an issue `status/in progress` → `status/to test` → (clear all on
merge). `triaging-issues` excludes anything carrying any of these from "what to work on."

Adjust these names to your repo's convention (this is the one place to do it), or drop the
filter if you don't use a status workflow. Remember these are added/removed by numeric ID,
so they get resolved via `list_repo_labels` like any other label.

## Context-size note

Unlike a curl-to-file approach, `mcp__forgejo__list_repo_issues` returns issue JSON
**into the conversation context**. For repos with many open issues, fetch with a sane
`limit` and paginate deliberately rather than pulling hundreds of issues at once. Reason
over each page before fetching the next.
