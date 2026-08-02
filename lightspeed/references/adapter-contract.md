# Adapter contract

The boundary between skills and backends, per [ADR 0001](../../docs/adr/0001-curl-over-mcp-and-adapter-architecture.md).
Skills never embed a backend's endpoints — they invoke **verbs** through a single dispatcher,
which resolves the right backend for the axis and execs that backend's adapter.

## Layout

These ship **inside the plugin** (so they travel when `lightspeed` is installed), under
`lightspeed/scripts/`:

```
lightspeed/scripts/
  lightspeed                 # dispatcher (the entrypoint skills call)
  adapters/
    forgejo/
      _common.sh             # shared: _api(), label_id(), auth, error handling (sourced)
      issues                 # subcommands: list get create comment set-status close reopen
      pr                     # subcommands: open merge        (pull request; "MR" on GitLab)
      ci                     # subcommands: watch log
      labels                 # subcommands: resolve
    github/ …                # future: same executable names, same contract
```

## Invocation

Skills call the dispatcher, never an adapter directly. The plugin ships `bin/lightspeed`
(and `bin/batch-manifest`); Claude Code adds the plugin's `bin/` directory to the Bash
tool's `PATH`, so skills invoke it as a bare command — no plugin-root environment
variable needed:

```
lightspeed <group> <verb> [--flag value …]
```

The dispatcher:

1. Reads `.lightspeed/config.json` (config) and `.lightspeed/secrets.json` (token), from repo root.
2. Picks the **axis** for the group — `issues`/`labels` → `issues.*`, `pr`/`ci` → `code.*` —
   applying `code → issues` inheritance when the `issues` block is omitted.
3. Exports the resolved coordinates + token into the adapter's environment: `LS_API`,
   `LS_OWNER`, `LS_REPO`, `LS_TOKEN`, `LS_TRUNK` (code's trunk branch), `LS_LABELS_JSON`
   (the `labels` map, for role→name resolution), and `LS_BACKEND`. Token precedence:
   `LS_TOKEN`/`FORGEJO_TOKEN` env override, else the secrets file (axis, `code → issues`).
4. Execs `adapters/<backend>/<group> <verb> [args…]`.

So adapters are pure: they read coordinates/token from `LS_*` env, never parse config, never
know which axis they serve. Swapping `forgejo` for `github` changes nothing above the adapter.

## Output & exit conventions (every verb)

- **stdout** is the *only* data channel, and is **line-oriented and minimal** — projected with
  `jq` to just what the caller needs, so it stays light in conversation context. No raw API
  JSON unless a verb explicitly returns one object (`issues get`).
- **TSV** for multi-field rows: tab-separated, one record per line, no header. Readable by
  Claude, trivially `cut`-able by scripts.
- **stderr** carries human-readable errors only.
- **Exit code**: `0` success; non-zero on any failure (network, HTTP ≥ 400, bad args), with a
  one-line reason on stderr. Skills must check it — a non-zero exit is a hard stop, never a
  silent no-op.

## Verbs (proposed shapes — open to revision)

### `issues`

| Verb        | Args                                   | stdout |
|-------------|----------------------------------------|--------|
| `list`      | `--state open\|closed\|all` `--limit N` `--label NAME` (repeatable) | one row per issue: `number⇥title⇥comma,labels` |
| `get`       | `--number N`                           | `number⇥title` then a blank line then the raw body (the one verb that emits a body) |
| `comments`  | `--number N`                           | one block per comment, oldest-first: `author⇥created_at` header line, the raw comment body, then a blank separator line. Empty output (exit 0) = no comments |
| `create`    | `--title T` `--body B` (or `--body-file PATH`) `--label NAME` (repeatable) | the new issue `number`; labels resolved name→id, applied at creation |
| `update`    | `--number N` `--title T` and/or `--body B` (or `--body-file PATH`) | (nothing) — patches only the fields passed |
| `comment`   | `--number N` `--body B` (or `--body-file PATH`) | (nothing; exit 0) |
| `attach`    | `--number N` `--file PATH` `[--name NAME]` | the uploaded asset's `url` (multipart upload; embed it in the body) |
| `set-status`| `--number N` `--status ROLE`           | (nothing) — resolves ROLE→label name→id internally, removes other status/* first |
| `clear-status`| `--number N`                         | (nothing) — removes every managed `status/*` label from the issue |
| `label-add` | `--number N` `--label NAME` (repeatable) | (nothing) — adds existing labels by name (errors if a name doesn't exist) |
| `assign`    | `--number N` `--user LOGIN` (repeatable) | (nothing) — **replaces** the issue's assignees with the given user(s). Forgejo/GitHub take logins as-is; GitLab resolves login→numeric id via the instance `/users` lookup; Jira resolves email/name→accountId and allows only ONE `--user` (single-assignee model) |
| `unassign`  | `--number N`                           | (nothing) — removes all assignees |
| `close`     | `--number N`                           | (nothing) |
| `reopen`    | `--number N`                           | (nothing) — inverse of `close`; sets the issue's state back to open |

### `labels`

| Verb      | Args                                     | stdout |
|-----------|------------------------------------------|--------|
| `list`    | (none)                                   | one row per label: `name⇥color⇥description` |
| `resolve` | `--name NAME` (repeatable)               | one row per input: `name⇥id` (empty id = not found) |
| `create`  | `--name NAME` `--color #RRGGBB` `[--description D]` | the new label's `id` |

### `pr` (pull request — "MR" on GitLab)

| Verb    | Args                                                   | stdout |
|---------|--------------------------------------------------------|--------|
| `open`  | `--head BRANCH` `--base BRANCH` `--title T` `--body-file PATH` | `number⇥url` |
| `merge` | `--number N` `--strategy merge\|squash\|rebase`        | (nothing) |

### `ci` (the two MCP couldn't do)

| Verb    | Args                                              | stdout |
|---------|---------------------------------------------------|--------|
| `watch` | `--pr N` \| `--sha SHA` `[--status-file PATH] [--timeout SECS]` | one line per state change: `ci runs=<n> pending=<p> failed=<f> status=<pending\|success\|failure>`; **aggregates all runs** for the SHA — stays watching while any is pending, verdict is `failure` if any run failed. Exits 0 once none pending. `--pr` resolves the PR's head SHA (the SHA the run reports — prefer it; a local `--sha` may be unpushed). `--timeout` (env `LS_CI_WATCH_TIMEOUT` / config `code.ciWatchTimeout`; default 900; 0 disables) exits non-zero rather than polling forever. **Superseded runs don't count**: only the latest attempt per (workflow, trigger event) is scored — a retried-to-green flake watches green — and a newest manual re-dispatch (`workflow_dispatch`; GitLab: `web` pipeline) supersedes that workflow's earlier runs outright. Background-friendly for the `Monitor` tool. |
| `log`   | `--sha SHA` (or `--failed BRANCH`)                | failed jobs' plaintext logs to stdout, one `── job <id>: <name> ──` header per job, fetched via the backend's per-job logs API (Forgejo 16+: `/actions/jobs/{id}/logs`) |

## Notes

- `--body-file` exists alongside `--body` precisely so multi-line markdown / fenced code (PR
  bodies, test-plan blocks) survives without shell-quoting hell — the adapter assembles the
  JSON with `jq --rawfile`.
- Label **name→id** resolution lives entirely inside the adapter (`set-status`, and `labels
  resolve` for skills that need ids directly). Skills speak role/label *names*, never ids —
  the per-instance id problem stops at the adapter boundary.
- `ci watch`/`ci log` are the existing shared scripts adapted to this signature, not new code.
- `⇥` above denotes a literal TAB.
- **GitHub backend specifics:** GitHub label endpoints use label **names**, not numeric ids — the
  github adapter resolves and applies labels by name internally (skills are unchanged). `issues
  attach` is **not supported** on GitHub (no REST API for issue attachments) and exits non-zero
  with that reason. `issues list` filters out pull requests (GitHub returns PRs from the issues
  endpoint). `pr merge` maps `--strategy` to GitHub's `merge_method`. `ci log` streams per-job
  logs (`/actions/jobs/{id}/logs`) rather than the run-level zip. Note GitHub's `issues list`
  endpoint is **eventually consistent** — a just-created issue can take a few seconds to appear in
  the list, though `issues get` reflects it immediately; don't rely on a list snapshot taken
  milliseconds after a create.
- **GitLab backend specifics:** GitLab addresses a project by its URL-encoded path — the
  adapter builds `projects/<owner%2Frepo>` from `owner`/`repo` (subgroups' slashes encode too).
  Issues are addressed by their per-project **`iid`** (what the contract calls `--number`), and
  the body lives in `description`, not `body`. Labels are applied **by name** (like GitHub) via
  `add_labels`/`remove_labels`; `set-status` does the single-status swap in one `PUT`. Auth is a
  `PRIVATE-TOKEN` header (personal/project access token). `issues comments` drops GitLab **system
  notes** (label/state-change activity) so only real comments come back. `issues attach` uploads
  to the project-scoped `/uploads` endpoint and prints the asset path to embed in a body/comment.
  `pr` is a **merge request**; `pr merge` maps `--strategy squash` to the merge endpoint's
  `squash=true`, while `merge`/`rebase` merge with `squash=false` — a true rebase/fast-forward
  merge otherwise follows the project's configured *merge method* (GitLab's merge endpoint has no
  per-request `merge_method`). `ci` is **pipelines**: `ci watch` aggregates all pipelines for the
  SHA (`?sha=`), `--pr` resolves the MR head SHA (`.sha`); pending = created/waiting/preparing/
  pending/running/scheduled, a clean pass = success/skipped/manual, anything else (failed/canceled)
  counts as failure. `ci log` pulls the failed pipeline's failed-job traces (`/jobs/:id/trace`).
  MR **mergeability is computed asynchronously**, so an immediate `pr merge` right after `pr open`
  can transiently 405 until GitLab finishes its merge check — retry briefly (the rig smoke does).
- **Jira backend specifics:** Jira is an **issues-axis-only** backend (an issue tracker, not a git
  host) — it implements **only `issues` + `labels`**; `pr`/`ci` keep resolving to the `code`
  backend. Pair it with a git `code` backend. It targets Jira **Cloud REST v3** with HTTP **Basic**
  `email:api_token` auth (a classic Atlassian API token, not OAuth). The dispatcher threads two
  generic passthroughs for it — `LS_PROJECT` (the project key, config `issues.project`) and
  `LS_EMAIL` (config `issues.email`, or `LS_EMAIL` in the env). Decisions:
  - **Identifier = key.** The `--number` value is a Jira **key** (`KAN-123`), treated as an opaque
    id; skills print `#<key>` unchanged. `issues create` returns the key.
  - **`set-status` → Jira labels.** Maps a role → a `status/*` **label** (atomic add-target /
    remove-other-status-labels), matching the single-status model — it does **not** drive workflow
    transitions. Jira labels are **single tokens**: status label names in config must be
    **space-free** (e.g. `status/in-progress`, not `status/in progress`).
  - **`close`/`reopen` → workflow transitions.** Labels can't close a Jira issue, so `close` finds
    the transition into a status whose category is **`done`** and posts it; `reopen` transitions
    back to a **`new`** (To-Do) or, failing that, **`indeterminate`** (In-Progress) category. This
    is the one place transitions are unavoidable.
  - **Bodies/comments are ADF.** Jira stores rich text as Atlassian Document Format (ADF) JSON. A
    **minimal** shim converts markdown→ADF for writes (`create`/`update`/`comment`) and ADF→plain
    text for reads (`get`/`comments`): paragraphs, fenced code blocks, and bullet/ordered lists.
    Inline marks (bold, links) are carried as plain text, not styled.
  - **Labels are thin.** Jira labels are bare strings with no colour/description and no id distinct
    from the name. `labels list` emits `name⇥⇥` (empty colour + description); `labels resolve`
    returns the **name as its own id** (`name⇥name`); `labels create` is a **no-op** that succeeds
    idempotently (labels spring into existence on first use). `issues attach` is **not supported**.
  - **`list` via JQL.** Uses the enhanced-JQL search endpoint `POST /rest/api/3/search/jql` (the
    legacy `POST /rest/api/3/search` was decommissioned by Atlassian). `--state` maps to
    `statusCategory` (open = `!= Done`, closed = `= Done`, all = unfiltered); `--label` adds a
    `labels IN (…)` clause. Jira's JQL index is **eventually consistent** — a just-created/updated
    issue can lag `list` by seconds, though `issues get` reflects it immediately.
