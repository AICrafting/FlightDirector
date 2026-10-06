# Machine-readable output (`--json`)

Flight's default output is for agents: terse, tab-separated and line-oriented (see
[adapter-contract.md](adapter-contract.md) → *Output & exit conventions*). Programs that drive the
dispatcher, such as a desktop app's Issues panel, use the JSON forms described here instead.
They exist so a consumer never has to call a forge or Jira itself, or hold a token.

Ground rules:

- **`--json` is opt-in per call.** Without it, every verb's output stays byte-for-byte what it
  was. Agents and skills keep relying on that.
- **Field names and types are the same on every backend** (Forgejo, GitHub, GitLab, Jira). A
  field the backend can't supply is `null`. It is never left out and never typed differently.
- **Feature-detect, don't version-compare.** Run `flight capabilities --json` and check for the
  token you need. A token is never renamed or removed once released.
- Run `flight` from the repository's working directory, as an agent would.

## Version and capabilities

Neither probe needs a repository, a config, a token or the network.

```
$ flight --version
flight 0.17.2
$ flight --version --json
{"plugin":"flight","version":"0.17.2"}
$ flight capabilities --json
{"plugin":"flight","version":"0.17.2","capabilities":["version","capabilities", …]}
```

`flight capabilities` without `--json` prints one token per line.

| Token | Meaning |
|---|---|
| `version` | `flight --version [--json]` prints the plugin version |
| `capabilities` | this probe |
| `json-errors` | a failing `--json` call reports a coded error envelope (below) |
| `labels-json` | `labels list --json` and `labels statuses [--json]` |
| `write-json` | `issues create`, `issues comment` and `issues set-status` take `--json` |
| `issues-json` | `issues list`, `issues get` and `issues comments` take `--json`, and `issues list` takes `--status ROLE` |
| `issues-paging` | `issues list --json` pages with `--per-page M [--cursor C]` (below) |
| `issues-copy` | `issues copy` and `issues resync` exist |
| `issues-deps` | `issues block`, `unblock`, `blockers`, `blocking`, and `blocked_by` on `issues get --json` |
| `preflight` | `preflight run` and `preflight check` run and check the repo's `code.preflight` gate (FJ-307) |
| `issues-attach-check` | `issues attach --check` asks whether the tracker's backend can upload attachments (FJ-311) |

## Which verbs take `--json`

`--json` belongs to the dispatcher for the `issues` and `labels` groups. It is removed from the
arguments before an adapter sees them, and passed on as `LS_JSON=1`. Only a `--json` where a flag
can stand counts: the value of another option (a body or title that is literally `--json`) is
kept as given. On a verb of those groups
that has no JSON form, it is a `usage` error rather than being silently ignored. Other groups keep
their own meaning: `prompt-log summary --json` predates this and is unchanged.

| Verb | `--json` output |
|---|---|
| `issues list` | a list object (below) |
| `issues get` | one issue object |
| `issues comments` | an array of comment objects, oldest first |
| `issues resolve`, `issues tracker` | already JSON; `--json` adds the error envelope |
| `issues create` | the new issue object |
| `issues comment` | the new comment object |
| `issues set-status` | `{number, tracker, qualified, status, label}` |
| `issues copy` | `{source, target, copied: {body, comments, labels, status, footer, backLink}, skipped: {labels, status}}`; with `--dry-run`, `target` is null and `dryRun` is true |
| `issues block` | `{number, by, via, status}` |
| `issues unblock` | `{number, by, removed, status}`; a no-op unblock still prints it, with `removed: []`. `block` / `unblock` also take `--model ID` |
| `issues blockers` / `blocking` | `{issues: [{id, title, state, via}]}`; a text-linked issue that no longer exists has `title` and `state` null (TSV: empty title, state `unknown`) |
| `issues resync` | `{source, target, copied: {comments}, skipped: {}}`; `dryRun: true` with `--dry-run` |
| `labels list` | an array of label objects |
| `labels statuses` | an array of status roles |

## Issues

`--number` takes whatever `issues list` returned, either `number` or `qualified` (`81`,
`FJ-81`, a Jira `KAN-7`), exactly as it does without `--json`.

### The issue object

```jsonc
{
  "number": "81",            // native id, ALWAYS a string ("81" on a forge, "KAN-7" on Jira)
  "tracker": "FJ",           // the named tracker's ref (null on a pre-schema-3 config)
  "qualified": "FJ-81",      // tracker-qualified id; Jira KAN-7 on tracker JIR → "JIR-7"
  "title": "…",
  "state": "open",           // "open" | "closed", normalized on every backend
  "status": "to-test",       // status ROLE from this tracker's label map, or null
  "labels": ["bug", "status/to test"],
  "author": "dave",          // login (Jira: display name), or null
  "created": "2026-10-02T09:28:43Z",   // ISO-8601 UTC, always ending in Z
  "updated": "2026-10-02T09:29:15Z",
  "comments": 3,             // comment count, or null where the backend doesn't give one cheaply
  "url": "https://…/issues/81",        // web link
  "body": "markdown…",       // without the flight signature; null in list rows
  "signature": {"plugin": "flight", "version": "0.17.2", "model": "Opus/5.5"},  // or null
  "blocked_by": [{"id": "GH-3", "title": "…", "state": "open", "via": "text"}]  // issues get only; null in list rows and when the lookup failed
}
```

Every key is present on every backend. Notes:

- **`status`** is the first role in the tracker's `labels.status` map, in map order, whose label
  the issue carries. A role recorded as declined (`false`) never matches. It stays set on a
  closed issue: `state` says open or closed, and `status` says where the work got to.
- **`signature`** is the trailing `---` / `🤖 via FlightDirector:<plugin>@<version>[ with
  <model>]` footer Flight appends to every body it writes. It is split out of `body`, and `model`
  is null when the footer names none. Bodies Flight didn't write have `signature: null` and their
  text untouched. A `---` elsewhere in the text is left alone.
- **`blocked_by`** is filled by `issues get --json` only, with the same lookup `issues blockers`
  does. It is `null` in `list` rows, and when that lookup fails (`get` still succeeds, with a
  warning on stderr).
- **`comments`** comes straight from the issue on Forgejo, GitHub and GitLab, and from `get` on
  Jira. Jira list rows have `comments: null`.

### `issues list --json`

```json
{"issues": [ …issue objects… ], "truncated": true, "total": 38, "errors": []}
```

- **Rows** are issue objects with `body` and `signature` set to null. Use `issues get` for the body.
- **Order** is newest created first, with the issue number breaking ties. The order is the same on
  every backend and with `--all-trackers`.
- **`truncated`** is true when `--limit` (default 50) held rows back. **`total`** is the server's
  row count when the backend reports one (Forgejo, GitLab), otherwise null.
- **Filters:** `--state open|closed|all`, `--label NAME` (repeatable) and `--limit N` work as
  without `--json`. **`--status ROLE`** filters by a status role, mapped to this tracker's label
  name. On a tracker you selected (the default or `--tracker REF`), an unconfigured or declined
  role is a `usage` error.
- **`errors`** is always `[]` for a single tracker.

**`--all-trackers --json`** lists every configured tracker into the same object:

- Every row carries its own `tracker`.
- `truncated` is true if any tracker's rows were truncated.
- `total` is the sum when every tracker answered and reported a total, otherwise null. A
  partial sum would look complete.
- A tracker that fails adds `{"tracker": "GH", "code": "auth", "reason": "…"}` to `errors`, is also
  named on stderr, and the command still exits 0 with the others' rows. Only when every tracker
  fails is the result the error envelope of the first failure.
- `--status ROLE` is mapped per tracker. A tracker that has no label for the role (never
  defined, or declined as `false`) contributes zero rows and a `total` of 0, with a note on
  stderr naming the tracker and the role. It is not an `errors` entry. The text form behaves the
  same way and still exits 0.

### Paging: `issues list --json --per-page M [--cursor C]`

For a "Load more" button: fetch one page at a time instead of re-running with a growing
`--limit`.

```json
{"issues": [ …M issue objects… ], "truncated": true, "total": 38, "errors": [], "next": "eyJ2Ijox…"}
```

- **First page:** `--per-page M` (1–100) and no `--cursor`. **Next page:** the same command with
  `--cursor` set to the previous page's `next`. Keep `--state`, `--label`, `--status` and
  `--tracker` the same; a cursor used with different filters or another tracker is a `usage`
  error.
- **`next`** is the cursor for the following page, or null on the last page. It is opaque. Don't
  parse or build one, and don't keep it across flight upgrades (an outdated cursor is a `usage`
  error: start again without one). `truncated` is true exactly when `next` is non-null. `total`
  is the whole list's size where the backend reports one (Forgejo, GitLab), otherwise null.
- **Order:** newest created first, ties by number descending, the same as without paging. Pages
  never overlap. An issue filed between two loads doesn't repeat a row on the next page: it
  appears when the list is loaded from the start. On Forgejo, GitHub and GitLab an issue that
  leaves the list between loads (closed, relabelled) doesn't make the next page skip one either.
  Jira's pages only move forward, so there a row can be missed when issues leave the list
  between loads. Reloading from the start resyncs.
- **Not combinable** with `--limit` (a page has its own size) or `--all-trackers` (a cursor is one
  tracker's position): both are `usage` errors. Page each tracker with `--tracker REF` instead.
  The paging flags need `--json`.

### `issues comments --json`

An array, oldest first:

```json
[{"id": "17969", "author": "dave", "created": "…Z", "updated": "…Z",
  "url": "https://…/issues/199#issuecomment-17969", "body": "…", "signature": { … }}]
```

`id` is a string on every backend. GitLab's system notes (label and state changes) are left out,
as in the text form. `url` links to the comment itself.

## Errors

A failing `--json` call exits non-zero and prints **exactly one** JSON object on stdout, with
nothing before it, so a single parse always works:

```json
{"error":{"code":"not-found","message":"forgejo/issues: GET /issues/999 → HTTP 404: issue does not exist"}}
```

stderr still carries the human sentence, as without `--json`. `message` is for display; branch on
`code`, which is one of:

| `code` | When |
|---|---|
| `not-configured` | no `.flightdirector/config.json`, one that is not valid JSON or uses a schema this Flight can't use (too new, or not yet migrated where named trackers are needed), an invalid tracker config, no backend or adapter for it, or a coordinate the config should supply. Offer the setting-up-a-repo flow. |
| `auth` | no token resolved, or the backend answered 401/403 |
| `not-found` | the backend answered 404/410, or an issue id or tracker ref names nothing configured |
| `network` | the server couldn't be reached (curl itself failed) |
| `backend` | the server answered with any other error (5xx, an unexpected 4xx), or the call failed in a way nothing classified |
| `usage` | bad flags or arguments, or `--json` on a verb without a JSON form |
| `unsupported` | an adapter's `dep-*` verb: the backend can't record a dependency here, and `issues block` handles it by falling back to comments. Also `issues attach` (and `attach --check`) on a backend that can't upload: GitHub and Jira |
| `already-copied` | `issues copy`: the ledger already records a copy of this issue on that tracker; use `issues resync`, or `--force` for a second copy |

The code is decided where the cause is known, and never by matching message text. The dispatcher
classifies config, usage and ref resolution. Each adapter's `_api` maps HTTP status and curl
failure through the shared `adapters/_errors.sh` (`fail`, `http_fail`, `require_env`), which
writes the envelope to the `FLIGHT_ERROR_FILE` the dispatcher exports for a `--json` call.

### Writes

- **`issues create --json`** returns the new issue in the `issues get --json` shape, read back
  through that verb. The issue already exists by then, so if the read-back fails the call
  **still succeeds**. It answers with the fields it knows (`number`, `tracker`, `qualified`,
  `title`, `state: "open"`), `labels: []` so the type never changes, and null for the rest. It
  also warns on stderr. That way a caller never files it
  twice.
- **`issues comment --json`** returns the new comment in the `comments --json` entry shape. The
  signature flight appended comes back split into `signature`.
- **`issues set-status --json`** returns
  `{"number": "12", "tracker": "FJ", "qualified": "FJ-12", "status": "to-test", "label": "status/to test"}`.

Without `--json` these verbs print what they always did: the number, nothing, and nothing.

## Labels

Both verbs honour `--tracker REF`. Without it they act on the default tracker.

### `labels list --json`

The tracker's labels, in the backend's order, for filter chips:

```json
[{"name": "bug", "color": "#e11d21", "description": "Something is broken"}]
```

`color` is `#rrggbb` lowercase whether or not the backend sends the `#`. An empty description is
`null`. Jira labels have neither, so both are `null`.

### `labels statuses [--json]`

The tracker's status roles, so a UI never assumes a repo's label names:

```json
[{"role": "in-progress", "label": "status/in progress", "color": "#1f9d55"},
 {"role": "to-test",     "label": "status/to test",     "color": "#e3a008"}]
```

- Roles come in the order the tracker's `labels.status` map lists them.
- A role recorded as declined (`false`) is left out.
- `color` is that label's colour on the tracker, or `null` when the label is missing there or has
  no colour.
- Without `--json` the output is `role⇥label⇥color` rows, with the colour column empty when
  unknown.
- Pass a role to `issues list --status ROLE` to filter by it.

