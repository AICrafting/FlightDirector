# Adapter contract

The boundary between skills and backends, per [ADR 0001](../../docs/adr/0001-curl-over-mcp-and-adapter-architecture.md).
Skills never embed a backend's endpoints — they invoke **verbs** through a single dispatcher,
which resolves the right target — `code`, or one named issue tracker — and execs that
backend's adapter.

## Layout

These ship **inside the plugin** (so they travel when `flight` is installed), under
`flight/scripts/`:

```
flight/scripts/
  flight                 # dispatcher (the entrypoint skills call)
  adapters/
    forgejo/
      _common.sh             # shared: _api(), label_id(), auth, error handling (sourced)
      issues                 # subcommands: list get create comment set-status close reopen dep-add dep-remove dep-list dep-blocking
      pr                     # subcommands: open merge list   (pull request; "MR" on GitLab)
      ci                     # subcommands: watch log
      labels                 # subcommands: resolve
      auth                   # subcommands: check        (read-only token verifier)
    github/ …                # future: same executable names, same contract
```

## Invocation

Skills call the dispatcher, never an adapter directly. The plugin ships `bin/flight`
(and `bin/batch-manifest`). Claude Code may add `bin/` to `PATH`, but skills resolve the
installed plugin root and use the absolute script path so the same package works in Codex. See
[runtime.md](runtime.md).

```
flight <group> <verb> [--flag value …]
```

The dispatcher:

1. Reads `.flightdirector/config.json` (config) and `.flightdirector/secrets.json` (token), from repo
   root, and refuses a `schemaVersion` newer than it understands (currently 3).
2. Picks the **axis** for the group — `issues`/`labels` → the issue side, `pr`/`ci`/`auth`/`branches` →
   `code.*` (`auth check --axis issues` or `--tracker` overrides that one). On a schema-2 config the
   issue side is `issues.*` with `code → issues` inheritance. On schema 3 it is **one named
   tracker** from `issueTrackers` — see **Named tracker routing** below — and the config is
   validated first, so an invalid tracker list never reaches an adapter.
3. Exports the resolved coordinates + token into the adapter's environment: `LS_API`,
   `LS_OWNER`, `LS_REPO`, `LS_PROJECT`, `LS_EMAIL`, `LS_TOKEN`, `LS_TOKEN_SOURCE`, `LS_TRUNK` (code's
   trunk branch), `LS_LABELS_JSON` (the selected tracker's `labels` map — schema 2: the top-level
   one — for role→name resolution), and `LS_BACKEND`. Token precedence: `LS_TOKEN` /
   `FLIGHT_TOKEN` env override (`FORGEJO_TOKEN` is still honoured as a legacy name), else the
   secrets file (axis, `code → issues`; for a schema-3 tracker with `credentialRef: "code"`,
   `secrets.code`). A schema-3 tracker with **its own credential** skips the env override
   entirely and reads only `secrets.issueTrackers.<REF>`. `LS_TOKEN_SOURCE` names which
   of those won — the env var as `$FLIGHT_TOKEN` (leading `$`), or the secrets file's path in a
   form that resolves from wherever the caller ran: absolute for the repo's own (gitignored,
   main-checkout-only) file, or exactly the argument when `auth check --secrets` supplied a
   candidate. It is empty when no token resolved. Print it verbatim; do not shorten it against
   the repo root, because the common caller is a linked worktree where the repo-relative form
   names nothing (#196). It exists so `auth check` can say where the token came from instead of
   leaving a 401 to be blamed on the file (#177). On top of that, and only for the legacy
   `FORGEJO_TOKEN`, the dispatcher notes on stderr when it shadows a present secrets file
   holding a different token — the backend-neutral names are a deliberate override and stay
   quiet on the every-verb path.
4. **Signs the body** on `issues create|update|comment` and `pr open|update` (see **Body
   signature** below), and strips its own flags (`--model`, `--no-signature`) from the args.
5. Execs `adapters/<backend>/<group> <verb> [args…]`.

So adapters are pure: they read coordinates/token from `LS_*` env, never parse config, never
know which axis — or which named tracker — they serve. Swapping `forgejo` for `github` changes
nothing above the adapter.

## Named tracker routing (schema 3, dispatcher-owned)

Config and credential rules are in [flight-setup.md](flight-setup.md#named-issue-trackers-config-schema-3).
On a schema-3 config the dispatcher, not the adapter, chooses the tracker for every `issues` and
`labels` verb and for `auth check --tracker REF` / `--axis issues`:

- **`--tracker REF`** (any `issues`/`labels` verb, `auth check`) — select by `ref` or alias,
  case-insensitively. Stripped before the adapter runs. Given twice → error. Unknown → error
  naming near matches and every configured tracker; no network call is made. `pr`/`ci` do not
  take it: they always use `code`. `auth check --tracker REF --axis code` is a conflict.
- **`--number INPUT`** on any `issues` verb is resolved first: a bare `12`/`#12` means the default
  tracker (or the `--tracker` one); `GH12`, `GH-12`, `GH#12` or a Jira key `PROJ-7` names its
  tracker. The adapter receives the **native** id (`12`, or `PROJ-7` for Jira). A qualified id
  naming a different tracker than `--tracker` is an error.
- Without `--tracker` or a qualified id, the default tracker is used — so every existing
  unqualified call keeps working, with unchanged output.
- On a schema-2 config, `--tracker`, `--all-trackers`, `issues resolve` and `issues tracker`
  fail with "run flight reconcile" rather than falling back to the single-tracker path.

Dispatcher-owned verbs:

| Verb | Args | stdout |
|------|------|--------|
| `issues resolve` | `--number INPUT` `[--tracker REF]` | one line of JSON: `{"tracker":"FJ","number":"12","qualified":"FJ-12","display":"FJ-12","branchPrefix":"fj-12"}`. `tracker` is the canonical ref; `number` the native id as a string (`"PROJ-7"` for Jira, leading zeros stripped otherwise); `qualified` is `REF-<digits>`, always — the routing key. `display` is the name people and commits use and `branchPrefix` the branch/worktree prefix: with several trackers, `qualified` and `qualified` lowercased; when the repo has **one** tracker that is Jira or the code repository's own issue tracker (#258), the issue's own name — `display` `#12` (Jira: `PROJ-7`), `branchPrefix` `12` (`proj-7`). A single tracker in another forge repository stays qualified, because a bare `#12` would autolink to the code repository's issue. No coordinates, URLs or secrets. No network call. Ambiguous input (`A12` with refs `A` and `A1`) fails listing the candidates unless `--tracker` picks one |
| `issues tracker` | `[--tracker REF]` | the selected tracker's config entry as one line of JSON (config only — never secrets), e.g. to read its label map: `flight issues tracker --tracker GH \| jq -r '.labels.status["to-test"]'` |
| `issues list` | `--all-trackers` plus the ordinary `list` flags | every tracker in config order, each dispatched with its own coordinates, credential and label map. Each row is that tracker's ordinary `list` row with the issue's `display` id prepended: `FJ-12⇥12⇥title⇥labels` (Jira: `JIR-1⇥PROJ-1⇥…`), or `#12⇥12⇥…` in a single-tracker repo (see `issues resolve`). Every issue verb accepts that first column as `--number`. A tracker that fails is reported on stderr as `flight: tracker REF unavailable: <reason>` and makes the exit status non-zero; the other trackers' rows are still printed — a failure is never an empty backlog. A tracker that succeeds keeps its stderr too (the "showing N of M rows" truncation warning, the `FORGEJO_TOKEN` note), each line prefixed `flight: tracker REF: `. Cannot be combined with `--tracker`; only `issues list` accepts it |

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
- **`LS_JSON=1`** (set by the dispatcher for a `--json` call) asks an adapter's `issues list`,
  `get` and `comments` for *base objects* instead of TSV: the backend's fields mapped onto the
  shared shape (`adapters/_json.sh`; list rows plus pager `truncated`/`total`). The dispatcher
  finishes them (`scripts/issue-json.jq`). Failures go through `adapters/_errors.sh`, so the
  dispatcher can report a coded error.
- **Programs, not agents,** use the opt-in `--json` forms and the `flight --version` /
  `flight capabilities` probes. Their contract is in [json-output.md](json-output.md); the
  default output above never changes because of them.

## URL encoding

**Every caller-supplied value an adapter puts in a URL — query parameter or path segment — is
percent-encoded, through the one shared `urlenc` in `flight/scripts/_portable.sh`.** Adapters do
not define their own; `_portable.sh` is sourced by every adapter and by `_authlib.sh`, so `urlenc`
is simply in scope. It is `jq`'s `@uri`, which leaves the RFC 3986 unreserved set alone
(`A-Z a-z 0-9 - _ . ~`) and encodes everything else as UTF-8 bytes. It goes through `_portable.sh`'s
`jq` wrapper, so a Windows `jq.exe` cannot smuggle a CR into the URL.

Encode the **value**, never the assembled URL: the `?`, `&` and `=` that separate parameters, a
fixed path prefix such as `refs/heads/`, and GitHub's `owner:ref` colon are delimiters, so they are
written around what `urlenc` returns rather than passed through it.

Branch names, label names, states and usernames are all caller input and all reach a query string.
Unencoded, a space makes curl refuse the whole request outright ("Malformed input to a URL
function") and a `#` truncates the query at the fragment — the second is the dangerous one, because
the request succeeds and the lookup silently matches nothing. Values the adapter itself produced,
and backend ids that are verified integers or hex SHAs, need no encoding; encoding them anyway is
harmless and byte-identical.

## Paging

Every backend clamps a list request to its own maximum and reports the clamp only in a header:
Forgejo caps at `MAX_RESPONSE_ITEMS` (50 by default), GitHub defaults to 30 and caps at 100,
GitLab caps at 100, Jira clamps `maxResults` to its own ceiling. A single request per list verb
is therefore silently truncated, and the truncation is invisible to the caller.

Two rules follow, and adapters must implement both:

1. **Page until a page comes back EMPTY — never until a page looks short.** A short page and a
   clamped page are indistinguishable, so "stop when fewer rows than asked for came back" is not
   a stopping condition, it is a guess. (Jira's two read paths stop on the flags the API gives
   instead: `nextPageToken` for `/search/jql`, `startAt` against `total` for the collection
   endpoints.)
2. **`--limit N` is a ceiling, not a request size.** The adapter pages underneath it and returns
   at most N rows. When the ceiling hid something, a warning goes to **stderr** naming the count
   where the backend reports one (`warning: showing 50 of 109 rows for /issues; raise --limit to
   see the rest`) and saying `more are available` where it does not. stdout stays clean TSV, so
   a caller that ignores stderr is unaffected and one that reads it can tell a complete list from
   a clamped one. That distinction is the whole point: without it, "raise `--limit` if a full page
   came back" is a no-op, because at the cap a full page always comes back.

Verbs with no `--limit` (`issues comments`, `labels list`) page to exhaustion and never warn.

**The exception.** Forgejo's `/issues/{n}/comments` ignores both `limit` and `page` and returns
the whole thread (verified against a 53-comment issue), so that one verb is deliberately *not*
paged — a page-until-empty loop would re-fetch the same rows until the guard fired. GitHub and
GitLab comment endpoints do cap, and are paged.

## Verbs (proposed shapes — open to revision)

### `issues`

| Verb        | Args                                   | stdout |
|-------------|----------------------------------------|--------|
| `list`      | `--state open\|closed\|all` `--limit N` `--label NAME` (repeatable); JSON only: `--per-page M [--cursor C]` | one row per issue: `number⇥title⇥comma,labels`. `--limit` is a true ceiling: the adapter pages underneath it (see **Paging**), so `--limit 200` returns up to 200 rows rather than one server-clamped page. Under `LS_JSON`, `--per-page`/`--cursor` return one cursor page instead, through `cursor_page` (page-numbered backends) or `cursor_page_token` (Jira) in `_json.sh` (#262; contract in [json-output.md](json-output.md)) |
| `get`       | `--number N`                           | `number⇥title⇥state` then a blank line then the raw body (the one verb that emits a body). `state` is **normalized to exactly `open` or `closed`** on every backend, so a caller can ask "is #N open?" in one call; it is field 3 because appending leaves `cut -f1`/`cut -f2` readers untouched |
| `comments`  | `--number N`                           | one block per comment, oldest-first: `author⇥created_at` header line, the raw comment body, then a blank separator line. Empty output (exit 0) = no comments. Unbounded: the thread is always returned whole, because oldest-first rendering means a truncated fetch drops the **newest** comments, and "the later comment wins" depends on those |
| `create`    | `--title T` `--body B` (or `--body-file PATH`) `--label NAME` (repeatable) | the new issue `number`; labels resolved name→id, applied at creation |
| `update`    | `--number N` `--title T` and/or `--body B` (or `--body-file PATH`) | (nothing) — patches only the fields passed |
| `comment`   | `--number N` `--body B` (or `--body-file PATH`) | (nothing; exit 0) |
| `attach`    | `--number N` `--file PATH` `[--name NAME]` | the uploaded asset's `url` (multipart upload; embed it in the body) |
| `set-status`| `--number N` `--status ROLE`           | (nothing) — resolves ROLE→label name→id internally, removes other status/* first |
| `clear-status`| `--number N`                         | (nothing) — removes every managed `status/*` label from the issue |
| `label-add` | `--number N` `--label NAME` (repeatable) | (nothing) — adds existing labels by name (errors if a name doesn't exist) |
| `label-remove` | `--number N` `--label NAME` (repeatable) | (nothing) — removes labels by name; the exact mirror of `label-add`. Errors if a name doesn't exist on the repo (catches typos), but is **idempotent** about the issue: a label the issue isn't carrying is a no-op success. Jira, whose labels are free text with no repo-level registry, validates only its no-spaces rule |
| `assign`    | `--number N` `--user LOGIN` (repeatable) | (nothing) — **replaces** the issue's assignees with the given user(s). Forgejo/GitHub take logins as-is; GitLab resolves login→numeric id via the instance `/users` lookup; Jira resolves email/name→accountId and allows only ONE `--user` (single-assignee model) |
| `unassign`  | `--number N`                           | (nothing) — removes all assignees |
| `close`     | `--number N`                           | (nothing) |
| `reopen`    | `--number N`                           | (nothing) — inverse of `close`; sets the issue's state back to open |
| `dep-add`   | `--number N` `--by M`                  | (nothing) — records "N is blocked by M", both on this tracker; idempotent. Fails `unsupported` where the backend can't (Forgejo with dependencies switched off, GitLab Free tier, a GitLab pair already joined by a link of another type such as `relates_to` — GitLab allows one link per pair, and an unexpected 409 from its links endpoint maps here too — a Jira site with no "is blocked by" link type) |
| `dep-remove`| `--number N` `--by M`                  | (nothing) — removes that link; idempotent |
| `dep-list`  | `--number N`                           | one row per issue blocking N: `number⇥title⇥state`; under `LS_JSON` an array of `{number, title, state}`. Links to another repo/project are left out |
| `dep-blocking` | `--number N`                        | the issues N blocks, same shape |

### `labels`

| Verb      | Args                                     | stdout |
|-----------|------------------------------------------|--------|
| `list`    | (none)                                   | one row per label: `name⇥color⇥description` |
| `resolve` | `--name NAME` (repeatable)               | one row per input: `name⇥id` (empty id = not found) |
| `create`  | `--name NAME` `--color #RRGGBB` `[--description D]` | the new label's `id` |
| `ensure`  | `--name NAME` `--color #RRGGBB` `[--description D]` | existing or new label `id`; preserves existing metadata and tolerates concurrent creation |
| `ensure`  | `--model MODEL_ID`                       | derives the stable family in the dispatcher, then ensures the standard `model/<family>` label |
| `model-family` | `--id MODEL_ID`                      | stable family on stdout; non-zero for tool/service ids; warns when using the sanitized fallback |
| `edit`    | `--name NAME --new-name NAME`            | renamed label's `id`; preserves issue associations where the backend supports global labels |
| `delete`  | `--name NAME` `[--force]`                | (nothing). Removes the label from the repo. **Refuses by default while the label is still on any issue or PR/MR, open or closed**, naming the count (`50+` past one page); `--force` deletes regardless and the backend strips it from those issues. Unknown name is an error. Jira has no repo-level label object → always errors (use `issues label-remove`) |

### `pr` (pull request — "MR" on GitLab)

| Verb    | Args                                                   | stdout |
|---------|--------------------------------------------------------|--------|
| `open`  | `--head BRANCH` `--base BRANCH` `--title T` `--body-file PATH` | `number⇥url` |
| `get`   | `--number N`                                           | `number⇥title⇥state⇥url`. `state` is **normalized to the vocabulary `pr list` already uses — `open` \| `closed` \| `merged`** — whatever the backend calls it on the wire, so `[ "$(flight pr get --number N \| cut -f3)" = open ]` is a correct open check on every backend. GitLab spells an open MR `opened` (mapped) and has a first-class `merged` (kept); Forgejo and GitHub have no merged state at all — a merged PR is a closed one with `merged_at` set — so the adapter derives it, the same expression its `list` projection uses. GitLab's transient `locked` is the one value that passes through unchanged: it has no equivalent anywhere else, and folding it into `open` or `closed` would invent a fact |
| `update`| `--number N` `--title T` and/or `--body B` (or `--body-file PATH`) | (nothing) — patches only the fields passed, so a title fix leaves the body alone (mirrors `issues update`) |
| `merge` | `--number N` `--strategy merge\|squash\|rebase`        | (nothing) |
| `list`  | `--state open\|closed\|merged\|all` (default `open`) `[--head BRANCH] [--base BRANCH] [--limit N]` (default 30) | one row per PR: `number⇥state⇥head⇥base⇥title`; `state` is the same normalized `open` \| `closed` \| `merged` as `pr get` — `merged` for a merged PR whatever the backend calls it, and `open` for a GitLab MR the wire calls `opened`. `--state merged --head <branch>` is how `branches` detects a **squash/rebase** merge, whose commits are rewritten so the branch tip never becomes an ancestor of the target. `--limit` bounds the **fetch**, not the matches — on Forgejo, where `--head`/`--base` filter client-side, a small limit can hide an old PR. The fetch itself is paged (see **Paging**), so the limit is honoured in full rather than clamped to one page. |

### `auth`

| Verb    | Args                                          | stdout |
|---------|-----------------------------------------------|--------|
| `check` | `[--secrets PATH]` `[--axis code\|issues]` `[--tracker REF]` | one `✓`/`✗`/`-` line per check: `<mark> <label>  <detail>`. Exit non-zero if any check failed |

`auth check` verifies a token **before** anything relies on it: the identity the backend reports,
whether the repo/project named in `config.json` is reachable, one probe per capability group the
skills exercise, and the token's expiry where the backend exposes it. Rules:

- **Read-only, always.** It issues `GET`s only — never creating, editing or deleting anything —
  so **write access is reported "not tested"** rather than guessed at. `_authlib.sh`'s `probe`
  refuses any other method.
- It is the one verb that must **not** die on an HTTP error: a `401`/`403`/`404` *is* the finding.
  So the auth adapters use `probe` (records the status, keeps going) instead of each backend's
  `_api` (which exits on ≥ 400), and they share `adapters/_authlib.sh` for the line shape.
- Failures carry the **backend's own wording**, which is what actually names the fix — GitLab's
  `insufficient_granular_scope … [Work Item: Read]`, GitHub's per-resource 403.
- The **token is never printed** beyond its first 8 characters.
- All three flags are dispatcher-owned. `--axis` selects which axis's coordinates and token to
  check (default `code`; on schema 3 `issues` means the default tracker). `--tracker REF`
  (schema 3) checks that tracker with its own credential selection. `--secrets PATH` points the token lookup at a **candidate** file so a new
  token is verified before it replaces the live one; precedence is `--secrets` > `LS_SECRETS_FILE`
  > the normal resolution (`LS_TOKEN`/`FLIGHT_TOKEN` env, then the repo's secrets file) — an
  explicit candidate file deliberately beats an ambient env token.
- The per-backend probe list is the executable form of the scope/permission tables in
  [backends.md](backends.md); keep the two in step.

### `ci` (the two MCP couldn't do)

| Verb    | Args                                              | stdout |
|---------|---------------------------------------------------|--------|
| `watch` | `--pr N` \| `--sha SHA` `[--status-file PATH] [--timeout SECS]` | one line per state change: `ci runs=<n> pending=<p> failed=<f> skipped=<s> cancelled=<c> status=<pending\|success\|failure\|cancelled\|skipped>`; **aggregates all runs** for the SHA — stays watching while any is pending, verdict is `failure` if any run failed. Exits 0 once none pending (the exit code says a terminal state was reached, not that it was green — read `status=`). **Skipped is its own verdict, never a pass**: `skipped` runs are counted on their own axis, and a SHA whose runs were *all* skipped reports `status=skipped` rather than `success`, because nothing executed. A partial skip still reports `success`, with `skipped=<s>` naming how much did not run. **Cancelled is its own verdict too** (FJ-281): a run stopped before it finished is counted as `cancelled=<c>`, not as failed, and with no failure the verdict is `status=cancelled`, ahead of `skipped` and `success`. Nothing failed, so `ci log` has nothing to show, but nothing was verified either. With `--pr`, if the PR's head moved during the watch (a push mid-run is also what usually cancels a run), a line on **stderr** names the new head: the verdict is for the old one, so watch again. `--pr` resolves the PR's head SHA (the SHA the run reports — prefer it; a local `--sha` may be unpushed). **Two clocks**: `--timeout` (env `LS_CI_WATCH_TIMEOUT` / config `code.ciWatchTimeout`; default 900; 0 disables) bounds how long a run may **execute**, while `--queue-timeout` (env `LS_CI_QUEUE_TIMEOUT` / config `code.ciQueueTimeout`; default 3600; 0 disables) bounds time in which every job of every non-terminal run is waiting for a runner. Queued time does not count against `--timeout`, so a healthy run serialized behind a scarce runner is no longer reported as a hang; each message names which cap fired and the key that raises it. The run-level status cannot tell the two apart — every backend reports a run as running once ANY job starts — so a run that looks executing is confirmed against its own job list (`/actions/runs/{id}/jobs`, GitLab `/pipelines/{id}/jobs`), and anything unreadable counts as executing, i.e. keeps the shorter cap in charge. "No run found at all" is a trigger/push problem rather than a queue and stays bounded by `--timeout`. **Superseded runs don't count**: only the latest attempt per (workflow, trigger event) is scored — a retried-to-green flake watches green — and a newest manual re-dispatch (`workflow_dispatch`; GitLab: `web` pipeline) supersedes that workflow's earlier runs outright. A cancelled run is superseded too (FJ-313) when the same workflow has a run on that SHA under another trigger event that was not cancelled — a PR opened on a just-pushed commit starts a `push` and a `pull_request` run and a concurrency group cancels the first — so the twin's verdict stands; GitLab, which has no workflow dimension, applies this only between a SHA's `push` and `merge_request_event` pipelines. Background-friendly for the `Monitor` tool. |
| `log`   | `--pr N` \| `--sha SHA` \| `--failed BRANCH`      | failed jobs' plaintext logs to stdout, one `── job <id>: <name> ──` header per job, fetched via the backend's per-job logs API (Forgejo 16+: `/actions/jobs/{id}/logs`). `--pr` resolves the PR/MR head commit exactly as `watch --pr` does, and is the form to use after a red `watch --pr`. `--pr` and `--sha` dump **every failed run** on the commit, oldest first, each under a `run <id>` line — a commit usually carries one run per workflow, often started in the same second, so "the latest run" is as likely to be the green one. `--failed BRANCH` takes the latest failed run under the branch ref, and when there is none falls back to the branch's head commit: runs triggered by a pull-request event (Forgejo) or merge-request pipelines (GitLab) carry the PR/MR ref, never `refs/heads/<branch>` (GitHub's `?branch=` filter already matches both). A commit whose runs all passed prints `(no failed jobs for run …)` and exits 0; no run at all is a non-zero `no CI run found`. |

### `branches` (dispatcher-owned, not a backend adapter)

Finding and deleting merged branches is git-local work — ref ancestry, the worktree list, `git
branch -d` — so `branches` lives in the dispatcher (`scripts/branches`) rather than behind a
backend adapter. Its one backend need, the squash/rebase fallback, **recurses through the
dispatcher** as `pr list --state merged --head <branch>`, so every HTTP request still happens
inside an adapter. It is anchored to the **main** checkout (parent of the shared git dir), so it
behaves identically when invoked from a linked worktree. Driven by the
[cleaning-up-branches](../skills/cleaning-up-branches/SKILL.md) skill.

| Verb    | Args | stdout |
|---------|------|--------|
| `list`  | `[--merged-into STAGE] [--pattern GLOB]… [--no-fetch]` | one row per **merged** candidate: `branch⇥where⇥merged-into⇥pr⇥issue⇥worktree`. `where` is `local`/`remote`/`local+remote`; `pr` is the merged PR number when the evidence came from the backend, else `-`; `issue` is the branch's issue as a qualified id from `scripts/issue-identity.sh` (`FJ-12` for `feature/fj-12-…`; a legacy `feature/12-…` branch through the migration's binding), `unbound` for a legacy branch whose tracker cannot be recovered, `error` when the identity lookup itself failed (the helper's reason goes to stderr — never read it as "no issue"), else `-` (before config schema 3: the `N` parsed from `<prefix>/<N>-<slug>`); `worktree` is the `.worktrees/` path still holding it, else `-`. Runs `git fetch --prune origin` first unless `--no-fetch` (a fetch failure warns, it does not stop). Unmerged branches are absent, not flagged. |
| `prune` | `[--merged-into STAGE] [--pattern GLOB]… [--branch NAME]… [--local] [--remote] [--worktrees] [--dry-run] [--no-fetch]` | one row per action: `action⇥branch⇥detail`, where action is `remove-worktree`, `delete-local`, `delete-remote`, `drop-binding` (schema 3: the branch is now gone locally and on origin, so its retained identity binding was removed), the `would-…` preview form, or `skip` (detail = why). Exits non-zero if anything was skipped because an operation *failed*. |
| `sync-down` | `--from STAGE` | After a promotion into `STAGE` (`stages[i]`, `i ≥ 1`): for `j = i-1 … 0`, merge `stages[j+1]` back into `stages[j]` per that stage's `syncDown` (`direct` \| `pr` \| `none`, default = its `merge`). One row per stage, in cascade order: `stage⇥outcome⇥detail`, outcome ∈ `fast-forwarded` \| `merged` \| `already-level` \| `pr-merged` (detail starts `#N`) \| `skipped` (`none`) \| `stopped` \| `nothing-below` (`STAGE` is `stages[0]`). Runs the freshness check on each lower stage first (behind → fast-forward; ahead/diverged → `stopped`). `direct` merges with `--ff` (a merge commit only when needed) in the checkout holding the stage, or in a throwaway worktree when that checkout is dirty or absent, then pushes; `pr` recurses through the dispatcher — `pr open` (head = upper, base = lower, no issue keywords), `ci watch --pr`, then `pr merge --strategy merge` **only** on `status=success` — and leaves the PR open on anything else (red CI, or an all-skipped run that verified nothing). A conflict is aborted and reported. Stops the cascade and exits non-zero on the first `stopped` row; never resolves, rebases or resets a stage ([ADR 0002](../../docs/adr/0002-sync-down-after-promotion.md)). |

**Merged** means either the branch tip is an ancestor of a configured stage, or the backend
reports a merged PR whose head was that branch and whose base is a configured stage. Candidates
come from `code.branches.patterns` (default `["feature/*","bugfix/*","release/*"]`);
`--merged-into` narrows the stages considered and `--pattern` overrides the config.

Safety is in the verb, not in the caller:

- `prune` with **none** of `--local`/`--remote`/`--worktrees` deletes nothing — it prints the
  `would-…` preview and says so on stderr. Under-specifying is a preview, never a guess.
- Local deletion is `git branch -d` — **never `-D`**. A refusal is reported as a `skip`.
- Worktree removal is `git worktree remove` — **never `--force`**. A dirty or locked worktree is
  a `skip` and a non-zero exit.
- Remote deletion happens **only** under `--remote`.
- Stage branches, `archived/*`, and any branch checked out in the main checkout or a worktree
  outside `.worktrees/` are protected regardless of the patterns.

### `preflight` (dispatcher-owned)

Runs the repo's `code.preflight` gate ([flight-setup.md](flight-setup.md) → *Repo preflight
gate*) and checks its verdict. It lives in the dispatcher (`scripts/preflight`) so that the
`sh -c` running the gate is never in the agent's own command line, where Claude Code's Bash
safety check cannot read it and may stop to ask (FJ-307). The dispatcher reads the key and
passes it to the helper; the helper never reads config.

| Verb    | Args | Behaviour |
|---------|------|-----------|
| `run`   | `--worktree DIR [--log FILE] [--verdict FILE]` | Runs the gate in `DIR` with its output in `--log` (a temp file when omitted). Exit 0 with `preflight: passed (<cmd>)`, or `preflight: none configured` when the key is absent; exit 1 when the gate fails, printing the log's last 40 lines and `preflight: FAILED (<cmd>) — full log: <path>`. With `--verdict`, the file is removed first and then holds `pass <sha>`, `fail <sha>` or `none <sha>`, where `<sha>` is `DIR`'s `HEAD` when the gate started. A config that cannot be read fails before the gate starts and leaves no verdict. |
| `check` | `--worktree DIR --verdict FILE` | Exit 0 only when `FILE` holds `pass` or `none` for `DIR`'s **current** `HEAD`. Otherwise exit 1, naming the reason on stderr: no verdict, a failed gate, or a verdict for an older commit. |

Both exit 2 on a usage error. Advertised as the `preflight` capability.

### `issues copy` / `issues resync` (dispatcher-owned)

Copy one issue to another configured tracker, and later bring that copy up to date with source
comments. Like `branches`, these live in the dispatcher (`scripts/issue-copy`) rather than in an
adapter: they read and write each side back through the dispatcher with that tracker's own
credential and label map, so every backend pair works.

| Verb | Args | stdout |
|---|---|---|
| `copy` | `--from ID --to TRACKER` `[--no-body] [--no-comments] [--no-labels] [--no-status] [--footer] [--back-link] [--force] [--dry-run]` | the copy's display id; skipped labels/status on stderr. `--dry-run`: the plan, nothing written |
| `resync` | `--from ID --to TRACKER [--dry-run]` | the number of comments posted (`0` = up to date) |

- Title always; body, comments, labels and status by default. Labels match **by exact name**
  and are never created on the target. Status maps by **role** (the source's label → its role →
  the target's label for it). Comments are posted oldest-first under an attribution line
  (`**author** commented on YYYY-MM-DD:`). Assignees, open/closed state and attachments are
  never copied, and the source is never closed.
- The source ↔ copy link is recorded in `.flightdirector/copies.jsonl` (see
  [flight-setup.md](flight-setup.md)). `copy` refuses a source already recorded for that
  tracker (`already-copied`; `--force` overrides). `resync` posts the source comments the
  record doesn't list and touches nothing else. A record is written after each step, so a copy
  that fails partway is finished by `resync`.
- `--tracker` is refused: the two trackers are `--from` (any id `issues resolve` accepts) and
  `--to` (a ref or alias). `--to` the source's own tracker is a usage error. Requires config schema 3.

### `issues block` / `unblock` / `blockers` / `blocking` (dispatcher-owned)

"This issue is blocked by that one" (FJ-271), handled by `scripts/issue-deps` through the
dispatcher, like `copy`.

| Verb | Args | stdout |
|---|---|---|
| `block` | `--number ID --by ID [--no-status] [--model ID]` | `FJ-12 blocked by GH-3 (native\|text)` |
| `unblock` | `--number ID --by ID [--no-status] [--model ID]` | `FJ-12 no longer blocked by GH-3` (or, on stderr, that it wasn't) |
| `blockers` | `--number ID` | `id⇥title⇥state⇥native\|text` per blocker |
| `blocking` | `--number ID` | the same, per issue it blocks |

- Two issues on the same tracker use its `dep-*` verbs. On `unsupported`, and always across
  trackers, the link is a pair of signed comments: `**Blocked by GH-3**: <title>` on the blocked
  issue and `**Blocks FJ-12**: <title>` on the blocker; unblocking posts `**No longer …**`. Only
  flight-signed comments count (they are always signed; see `--signature`), and per pair the latest
  wins. The first-line match ignores case, so a hand-edited `blocked by fj-12` still counts.
- Status, unless `--no-status`: `block` sets the tracker's `blocked` role and records
  `(was <role>)`; the last `unblock` restores that role, or `new`, or clears the status. A status
  someone changed by hand is left alone.
- A text-linked issue that no longer exists is still listed by `blockers` / `blocking`, with an
  empty title and state `unknown` (TSV), or `title` and `state` null (`--json`).
- `--model ID` stamps the signature on the comments `block` / `unblock` post. A no-op `unblock`
  (nothing was linked) exits 0; under `--json` it still prints `{number, by, removed: [], status}`.
- A partial write names the missing piece and says to rerun: rerunning `block` / `unblock` is safe.
- `--tracker` is refused (each id names its tracker). Requires config schema 3.

## Notes

- `--body-file` exists alongside `--body` precisely so multi-line markdown / fenced code (PR
  bodies, test-plan blocks) survives without shell-quoting hell — the adapter assembles the
  JSON with `jq --rawfile`.
- Label **name→id** resolution lives entirely inside the adapter (`set-status`, and `labels
  resolve` for skills that need ids directly). Skills speak role/label *names*, never ids —
  the per-instance id problem stops at the adapter boundary.
- Model-family derivation lives in the dispatcher, before adapter execution. Skills pass the raw
  model id to `labels model-family` / `labels ensure --model` rather than interpreting vendor
  naming conventions themselves.
- **Body signature** (dispatcher-owned, #132). Every body flight writes — `issues create` /
  `update` / `comment` (so every work-ledger entry) and `pr open` / `update` (so every
  promotion and sync-down PR) — ends with:

  ```
  ---
  🤖 via FlightDirector:flight@0.14.0 with Fable/5.1
  ```

  A blank line, a rule, then `🤖 via FlightDirector:flight@<installed version>`, plus ` with
  <Model/ver>` when the model is known. The model comes from the dispatcher-owned `--model <id>`
  flag (stripped before the adapter sees the args) or `FLIGHT_MODEL` / `LS_MODEL` in the env,
  rendered as `Fable/5.1` from `claude-fable-5-1`, `Sol/5.6` from `gpt-5.6-sol`, `GPT/5` from
  `gpt-5`; unknown → omitted. On `update` a trailing signature already on the body is
  **replaced**, not stacked, matched on shape so a newer plugin re-signs an older body. Titles,
  labels and status are never touched. Off switch: `code.signature.enabled: false` in config,
  or `--no-signature` on one call. Adapters never see any of this — the Jira ADF shim just
  learned to render a `---` line as a `rule` node so the separator survives there too.
- `ci watch`/`ci log` are the existing shared scripts adapted to this signature, not new code.
- `⇥` above denotes a literal TAB.
- **GitHub backend specifics:** GitHub label endpoints use label **names**, not numeric ids — the
  github adapter resolves and applies labels by name internally (skills are unchanged). `issues
  attach` is **not supported** on GitHub (no REST API for issue attachments) and exits non-zero
  with that reason. `issues list` filters out pull requests (GitHub returns PRs from the issues
  endpoint). `pr merge` maps `--strategy` to GitHub's `merge_method`. `pr` has no `merged` state
  either — merged is closed-with-`merged_at`, which both `pr list` and `pr get` read to report
  `merged` — but GitHub *does* filter by branch server-side, so the adapter sends
  `head=<owner>:<branch>` and `base=` and re-checks client-side. `ci log` streams per-job
  logs (`/actions/jobs/{id}/logs`) rather than the run-level zip. Note GitHub's `issues list`
  endpoint is **eventually consistent** — a just-created issue can take a few seconds to appear in
  the list, though `issues get` reflects it immediately; don't rely on a list snapshot taken
  milliseconds after a create.
- **GitLab backend specifics:** GitLab addresses a project by its URL-encoded path — the
  adapter builds `projects/<owner%2Frepo>` from `owner`/`repo` (subgroups' slashes encode too).
  Issues are addressed by their per-project **`iid`** (what the contract calls `--number`), and
  the body lives in `description`, not `body`. GitLab reports an open issue's state as
  **`opened`**, not `open`, and spells an open MR's state the same way, so `issues get`, `pr get` and
  `pr list` all normalize it — a caller comparing the raw wire value against `open` would read every
  open GitLab issue and MR as not-open. Labels are applied **by name** (like GitHub) via
  `add_labels`/`remove_labels`; `set-status` does the single-status swap in one `PUT`. Auth is a
  `PRIVATE-TOKEN` header (personal/project access token). `issues comments` drops GitLab **system
  notes** (label/state-change activity) so only real comments come back. `issues attach` uploads
  to the project-scoped `/uploads` endpoint and prints the asset path to embed in a body/comment.
  `pr` is a **merge request**; `pr merge` maps `--strategy squash` to the merge endpoint's
  `squash=true`, while `merge`/`rebase` merge with `squash=false` — a true rebase/fast-forward
  merge otherwise follows the project's configured *merge method* (GitLab's merge endpoint has no
  per-request `merge_method`). `ci` is **pipelines**: `ci watch` aggregates all pipelines for the
  SHA (`?sha=`), `--pr` resolves the MR head SHA (`.sha`); pending = created/waiting/preparing/
  pending/running/scheduled/canceling, not-a-failure = success/skipped/manual, `canceled` is counted
  on its own axis (`cancelled=<c>`, verdict `cancelled`), anything else (failed) counts as failure;
  `skipped` is additionally counted on its own axis, so an all-skipped SHA verdicts as `skipped`.
  `ci log` pulls the failed pipeline's failed-job traces (`/jobs/:id/trace`).
  `pr list` is the one backend with a first-class `merged` state and server-side
  `source_branch`/`target_branch` filters; `--state open` is spelled `opened`. It is also the only
  backend with a `locked` state (transient, while a merge is in flight), which `pr get`/`pr list`
  pass through rather than mapping.
  MR **mergeability is computed asynchronously**, so an immediate `pr merge` right after `pr open`
  can transiently 405 until GitLab finishes its merge check — retry briefly (the rig smoke does).
- **Jira backend specifics:** Jira is an **issue-tracker-only** backend (not a git host) — it
  implements **only `issues` + `labels`**; `pr`/`ci` keep resolving to the `code`
  backend. Pair it with a git `code` backend. There is no `jira/pr` adapter file at all, so every
  `pr` verb — `list` included — is unreachable through a Jira tracker (the dispatcher's "no `pr`
  adapter for backend 'jira'"). `branches` treats a `pr list` it cannot get an answer from as
  "no PR evidence" and falls back to the ancestry test alone rather than failing. It targets Jira **Cloud REST v3** with HTTP **Basic**
  `email:api_token` auth (a classic Atlassian API token, not OAuth). The dispatcher threads two
  generic passthroughs for it — `LS_PROJECT` (the selected tracker's `project` key) and
  `LS_EMAIL` (own credential: the tracker's `email`, else `secrets.issueTrackers.<REF>.email`;
  a tracker on `credentialRef: "code"`: `LS_EMAIL` in the env, the tracker's `email`, then
  `secrets.code.email`; a schema-1/2 config: `issues.project` / `issues.email` or `LS_EMAIL`).
  Decisions:
  - **Identifier = key.** The `--number` value is a Jira **key** (`KAN-123`), treated as an opaque
    id; skills print `#<key>` unchanged. `issues create` returns the key.
  - **`set-status` → Jira labels.** Maps a role → a `status/*` **label** (atomic add-target /
    remove-other-status-labels), matching the single-status model — it does **not** drive workflow
    transitions. Jira labels are **single tokens**: status label names in config must be
    **space-free** (e.g. `status/in-progress`, not `status/in progress`).
  - **State is the status *category*, not a flag.** Jira has no open/closed field: `issues get`
    reports `closed` when `.fields.status.statusCategory.key` is **`done`** and `open`
    otherwise. That is the same rule `list` (`statusCategory != Done`) and `close`/`reopen`
    already use, so a project with custom workflow status names maps correctly with no extra
    config — only the category matters.
  - **`close`/`reopen` → workflow transitions.** Labels can't close a Jira issue, so `close` finds
    the transition into a status whose category is **`done`** and posts it; `reopen` transitions
    back to a **`new`** (To-Do) or, failing that, **`indeterminate`** (In-Progress) category. This
    is the one place transitions are unavoidable.
  - **Bodies/comments are ADF.** Jira stores rich text as Atlassian Document Format (ADF) JSON. A
    **minimal** shim converts markdown→ADF for writes (`create`/`update`/`comment`) and ADF→plain
    text for reads (`get`/`comments`): paragraphs, headings (a leading `#`…`######` + space, both
    ways), fenced code blocks, bullet/ordered lists, and `---` rules. Inline marks
    (bold, links) are carried as plain text, not styled.
  - **Labels are thin.** Jira labels are bare strings with no colour/description and no id distinct
    from the name. `labels list` emits `name⇥⇥` (empty colour + description); `labels resolve`
    returns the **name as its own id** (`name⇥name`); `labels create` is a **no-op** that succeeds
    idempotently (labels spring into existence on first use). Jira has no global rename operation,
    so `labels edit` exits non-zero; move issue associations from the old free-text value to the
    new one instead. `issues attach` is **not supported**.
  - **`list` via JQL.** Uses the enhanced-JQL search endpoint `POST /rest/api/3/search/jql` (the
    legacy `POST /rest/api/3/search` was decommissioned by Atlassian). `--state` maps to
    `statusCategory` (open = `!= Done`, closed = `= Done`, all = unfiltered); `--label` adds a
    `labels IN (…)` clause. Jira's JQL index is **eventually consistent** — a just-created/updated
    issue can lag `list` by seconds, though `issues get` reflects it immediately.
