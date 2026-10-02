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

## Which verbs take `--json`

`--json` belongs to the dispatcher for the `issues` and `labels` groups. It is removed from the
arguments before an adapter sees them, and passed on as `LS_JSON=1`. On a verb of those groups
that has no JSON form, it is a `usage` error rather than being silently ignored. Other groups keep
their own meaning: `prompt-log summary --json` predates this and is unchanged.

| Verb | `--json` output |
|---|---|
| `issues resolve`, `issues tracker` | already JSON; `--json` adds the error envelope |

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
| `not-configured` | no `.flightdirector/config.json`, an invalid tracker config, no backend or adapter for it, or a coordinate the config should supply. Offer the setting-up-a-repo flow. |
| `auth` | no token resolved, or the backend answered 401/403 |
| `not-found` | the backend answered 404/410, or an issue id or tracker ref names nothing configured |
| `network` | the server couldn't be reached (curl itself failed) |
| `backend` | the server answered with any other error (5xx, an unexpected 4xx), or the call failed in a way nothing classified |
| `usage` | bad flags or arguments, or `--json` on a verb without a JSON form |

The code is decided where the cause is known, and never by matching message text. The dispatcher
classifies config, usage and ref resolution. Each adapter's `_api` maps HTTP status and curl
failure through the shared `adapters/_errors.sh` (`fail`, `http_fail`, `require_env`), which
writes the envelope to the `FLIGHT_ERROR_FILE` the dispatcher exports for a `--json` call.
