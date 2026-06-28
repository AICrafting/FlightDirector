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
      issues                 # subcommands: list get create comment set-status close
      pr                     # subcommands: open merge        (pull request; "MR" on GitLab)
      ci                     # subcommands: watch log
      labels                 # subcommands: resolve
    github/ …                # future: same executable names, same contract
```

## Invocation

Skills call the dispatcher, never an adapter directly, resolving the plugin path via
`$CLAUDE_PLUGIN_ROOT`:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" <group> <verb> [--flag value …]
```

The dispatcher:

1. Reads `.lightspeed.json` (config) and `.lightspeed.secrets.json` (token), from repo root.
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
| `create`    | `--title T` `--body B` (or `--body-file PATH`) `--label NAME` (repeatable) | the new issue `number`; labels resolved name→id, applied at creation |
| `update`    | `--number N` `--title T` and/or `--body B` (or `--body-file PATH`) | (nothing) — patches only the fields passed |
| `comment`   | `--number N` `--body B` (or `--body-file PATH`) | (nothing; exit 0) |
| `attach`    | `--number N` `--file PATH` `[--name NAME]` | the uploaded asset's `url` (multipart upload; embed it in the body) |
| `set-status`| `--number N` `--status ROLE`           | (nothing) — resolves ROLE→label name→id internally, removes other status/* first |
| `close`     | `--number N`                           | (nothing) |

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
| `watch` | `--sha SHA` `[--status-file PATH]`                | one line per state change: `task-<id> status=<state>`; exits on terminal state. Background-friendly for the `Monitor` tool. |
| `log`   | `--sha SHA` (or `--failed BRANCH`)                | raw failed-job log to stdout (host-access dependent; see ADR consequences) |

## Notes

- `--body-file` exists alongside `--body` precisely so multi-line markdown / fenced code (PR
  bodies, test-plan blocks) survives without shell-quoting hell — the adapter assembles the
  JSON with `jq --rawfile`.
- Label **name→id** resolution lives entirely inside the adapter (`set-status`, and `labels
  resolve` for skills that need ids directly). Skills speak role/label *names*, never ids —
  the per-instance id problem stops at the adapter boundary.
- `ci watch`/`ci log` are the existing shared scripts adapted to this signature, not new code.
- `⇥` above denotes a literal TAB.
