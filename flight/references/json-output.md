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
flight 0.16.0
$ flight --version --json
{"plugin":"flight","version":"0.16.0"}
$ flight capabilities --json
{"plugin":"flight","version":"0.16.0","capabilities":["version","capabilities", …]}
```

`flight capabilities` without `--json` prints one token per line.

| Token | Meaning |
|---|---|
| `version` | `flight --version [--json]` prints the plugin version |
| `capabilities` | this probe |
| `json-errors` | a failing `--json` call reports a coded error envelope (below) |
| `issues-json` | `issues list`, `issues get` and `issues comments` take `--json`, and `issues list` takes `--status ROLE` |

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
  "signature": {"plugin": "flight", "version": "0.16.0", "model": "Opus/5.5"}  // or null
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
  name. An unconfigured or declined role is a `usage` error.
- **`errors`** is always `[]` for a single tracker.

**`--all-trackers --json`** lists every configured tracker into the same object:

- Every row carries its own `tracker`.
- `truncated` is true if any tracker's rows were truncated.
- `total` is the sum when every tracker reported a total, otherwise null.
- A tracker that fails adds `{"tracker": "GH", "code": "auth", "reason": "…"}` to `errors`, is also
  named on stderr, and the command still exits 0 with the others' rows. Only when every tracker
  fails is the result the error envelope of the first failure.
- `--status ROLE` is mapped per tracker. A tracker without that role reports a `usage` error
  entry.

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

The code is decided where the cause is known, and never by matching message text. The dispatcher
classifies config, usage and ref resolution. Each adapter's `_api` maps HTTP status and curl
failure through the shared `adapters/_errors.sh` (`fail`, `http_fail`, `require_env`), which
writes the envelope to the `FLIGHT_ERROR_FILE` the dispatcher exports for a `--json` call.
