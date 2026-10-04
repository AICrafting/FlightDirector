# Issue dependencies ("blocked by") — design

**Issue:** FJ-271 · **Date:** 2026-10-03 · **Status:** approved in conversation, awaiting spec review

## Goal

Let flight record that one issue is blocked by another, read that back, and remove it again. It
uses each backend's native relationship where there is one, and falls back to text comments
where there isn't. The board's status follows the relationship unless the caller opts out. The
skills see blockers when they pick up or triage work.

## What the backends offer (checked 2026-10-03)

| Backend | Native "blocked by" | API |
|---|---|---|
| GitHub | yes: issue dependencies | `GET/POST /repos/{o}/{r}/issues/{n}/dependencies/blocked_by` (POST body `{issue_id}`: the blocker's **database id**), `DELETE …/blocked_by/{issue_id}`, `GET …/dependencies/blocking` |
| Forgejo / Gitea | yes, when the repo has `internal_tracker.enable_issue_dependencies` | `GET/POST/DELETE /repos/{o}/{r}/issues/{index}/dependencies` (the issues this one depends on), `GET …/blocks` (the issues it blocks). The body is `{owner, repo, index}` |
| GitLab | Premium / Ultimate only | `GET/POST /projects/:id/issues/:iid/links`, `DELETE …/links/:issue_link_id`; `link_type` is `blocks` or `is_blocked_by`. Free tier (and self-hosted CE) allows only `relates_to` |
| Jira | yes: an issue link whose type reads "is blocked by" inward | `POST /rest/api/3/issueLink`, `DELETE /rest/api/3/issueLink/{id}`, links read from the issue's `issuelinks` field, types from `GET /rest/api/3/issueLinkType` |

No backend can link issues on **two different trackers**, so a cross-tracker link always uses
the text form.

## Architecture

The split follows `issues copy` (FJ-200): **adapters do native calls for one tracker, and a
dispatcher-owned helper does everything else.**

### Adapter verbs (native, one tracker)

Every adapter's `issues` script gains four verbs. They take **native** ids on the adapter's own
tracker. The helper always passes native ids and `--tracker`, so the adapters never see
qualified ids.

| Verb | Args | stdout |
|---|---|---|
| `dep-add` | `--number N --by M` | nothing. Records "N is blocked by M"; succeeds quietly if the link already exists |
| `dep-remove` | `--number N --by M` | nothing. Removes the link; succeeds quietly if there is none |
| `dep-list` | `--number N` | one row per issue blocking N: `number⇥title⇥state` (`state` normalized to `open`/`closed`) |
| `dep-blocking` | `--number N` | one row per issue N blocks, same shape |

When the backend cannot record the relationship, the adapter fails with the new error code
**`unsupported`** (added to `adapters/_errors.sh` and to the code table in `json-output.md`):

- **Forgejo:** before any dependency call, the adapter reads the repo (`GET /repos/{o}/{r}`).
  If `internal_tracker.enable_issue_dependencies` is not `true`, it fails `unsupported`. A repo
  with dependencies switched off answers the dependency endpoints with 404, which would look
  like a missing issue, so the check comes first.
- **GitLab:** `dep-add` posts `link_type: is_blocked_by`. A refusal (HTTP 403, 400 or 422) fails
  `unsupported`, naming the tier. `dep-list` / `dep-blocking` on a Free-tier project return the
  `relates_to` links filtered out, so they print nothing rather than failing. `dep-remove` finds
  the link id from `GET …/links` and deletes it.
- **Jira:** the link type is found through `GET /issueLinkType`: the first type whose `inward`
  text is "is blocked by" (case-insensitive), else one named "Blocks". If there is neither, it
  fails `unsupported`. The direction of `inwardIssue` / `outwardIssue` in the POST is pinned by
  reading the link back from the blocked issue's `issuelinks` (verified on the live Jira rig).
- **GitHub:** `dep-add` / `dep-remove` look up the blocker's database id (`GET /issues/{M}` →
  `.id`) first.

Adapters list only links whose other end is on the **same tracker**: same repo for the forges,
same project for Jira. A cross-repo native link made by hand elsewhere is left out, because the
helper could not name its other end.

### Dispatcher verbs (`flight/scripts/issue-deps`)

The dispatcher hands four verbs to a new helper, `flight/scripts/issue-deps`, the way it hands
`copy` / `resync` to `issue-copy`. The helper reads and writes both issues back through the
dispatcher (`$FLIGHT_SELF … --json`), one tracker per call.

| Verb | Args | stdout (text) |
|---|---|---|
| `block` | `--number ID --by ID [--no-status] [--model M]` | one line: `FJ-12 blocked by GH-3 (native\|text)` |
| `unblock` | `--number ID --by ID [--no-status] [--model M]` | one line: `FJ-12 no longer blocked by GH-3` |
| `blockers` | `--number ID` | one row per blocker: `qualified⇥title⇥state⇥native\|text` |
| `blocking` | `--number ID` | one row per issue it blocks, same shape |

`--number` and `--by` take any id `issues resolve` accepts (`12`, `#12`, `FJ-12`, `GH-3`,
`KAN-7`). `--tracker` is refused, since each id names its own tracker. Blocking an issue on
itself is a `usage` error. Like `copy`, the verbs need config schema 3.

**`block`:**

1. Resolve both ids. Fetch both issues (`issues get --json`), which proves they exist and gives
   the blocker's title.
2. If they are on the **same tracker**, call `issues dep-add`. On success the link is `native`.
   On `unsupported`, say so on stderr (`native dependencies unavailable on FJ: <reason>; using
   a comment`) and continue as `text`. Any other failure stops the verb.
3. If they are on **different trackers**, or step 2 fell back, the link is `text`:
   - post `**Blocked by GH-3**: <blocker title>` on the blocked issue;
   - post `**Blocks FJ-12**: <blocked title>` on the blocker (the mirror).
4. Status, unless `--no-status` (see **Status**).

**`unblock`:**

1. Resolve both ids.
2. Same tracker: call `issues dep-remove`. `unsupported` is not an error here, since there is
   then no native link to remove.
3. If the text record shows the pair as linked, post `**No longer blocked by GH-3**` on the
   blocked issue and `**No longer blocks FJ-12**` on the blocker. If neither a native nor a
   text link existed, say so on stderr and exit 0 (idempotent).
4. Status, unless `--no-status`.

**`blockers` / `blocking`:** the union of the native rows (same-tracker `dep-list` /
`dep-blocking`, skipped on `unsupported`) and the text record. A pair present both ways prints
once, as `native`. Text entries get their title and state from `issues get --json`.

### The text record

Every comment flight posts carries the dispatcher's signature. Ids in these lines are always
**qualified** (`FJ-12`), even in a one-tracker repo, so they stay unambiguous if a tracker is
added later.

| Event | On the blocked issue | Mirror, on the blocker |
|---|---|---|
| block | `**Blocked by GH-3**: <title>` | `**Blocks FJ-12**: <title>` |
| unblock | `**No longer blocked by GH-3**` | `**No longer blocks FJ-12**` |

**Reading it back.** The helper reads `issues comments --json` and keeps a comment only when:

- its `signature` is not null (flight wrote it), and
- its **first line** matches
  `^(\*\*)?(Blocked by|No longer blocked by|Blocks|No longer blocks) ([A-Za-z][A-Za-z0-9]*-[0-9]+)(\*\*)?(:.*)?$`.
  The asterisks are optional because Jira's shim stores bold as literal text.

Per other issue, the **latest** matching comment decides: `Blocked by` / `Blocks` means linked,
and the `No longer` forms mean unlinked. The blocked side's comments drive `blockers`; the
mirror's drive `blocking`. Prose that says "blocked by GH-3" without flight's signature never
counts.

### Status

Status changes by default; `--no-status` skips them. The tracker's `blocked` role is looked up in
its label map (`issues tracker` → `.labels.status.blocked`). If the role isn't configured, the
status steps are skipped with a note on stderr.

**On `block`:**

- If the issue already carries the `blocked` role, nothing changes and nothing is recorded.
- Otherwise the helper sets `blocked` with `issues set-status`, and records the role it replaced
  (or `none`) as a `Status:` line:
  - for a `text` link, as a second line in the `**Blocked by …**` comment:
    `Status: blocked (was in-progress)`;
  - for a `native` link, which posts no comment of its own, as a separate comment on the blocked
    issue: `**Status: blocked** (was in-progress), blocked by GH-3`.

**On `unblock`:** only when **no blockers remain**, native or text, after the removal:

- If the issue no longer carries the `blocked` role (someone moved it by hand), leave it.
- Otherwise restore the role named in the **latest** flight-signed comment containing
  `(was <role>)`. If that role is `none` or no longer configured, or there is no record, fall
  back to the `new` role, or `clear-status` when `new` isn't configured.

A closed blocker stays linked until `unblock`. `blockers` shows its state, and callers decide
what a closed blocker means.

### `issues get --json`

The issue object gains **`blocked_by`**: an array of `{id, title, state, via}` (`via` is
`native` or `text`), filled by the same union `blockers` uses.

- Only `issues get --json` fills it. `issues list --json` rows carry `blocked_by: null`, so the
  key is present on every issue object, as the contract requires. The TSV forms don't change.
- If the lookup fails, `get` still succeeds, with `blocked_by: null` and a warning on stderr.
- **No recursion:** the helper fetches titles with `issues get --json`, so it sets
  `FLIGHT_NO_DEPS=1` on those calls, and the dispatcher skips the `blocked_by` lookup when that
  is set.

### Skills

- **`working-an-issue` Step 1:** after reading the comments, run `issues blockers`. An **open**
  blocker goes in the pickup line (`blocked by GH-3 (open)`), and the agent asks before starting
  work. Closed blockers are mentioned only.
- **`triaging-issues` Step 3:** for each issue on the pick-list that carries the `blocked`
  status, run `issues blockers` and name its open blockers. No per-row lookup for other issues.
- **`filing-issues`:** one pointer: if a new issue depends on another, use `issues block` after
  creating it rather than writing "blocked by" in prose.

### Capability and docs

- Capability token **`issues-deps`** in the dispatcher's `CAPABILITIES`.
- `adapter-contract.md`: the four adapter verbs and the four dispatcher verbs.
- `json-output.md`: `blocked_by`, the `--json` shapes of the four dispatcher verbs, the
  `unsupported` code.
- `GUIDE.md`: a short "Blocked issues" section. `CHANGELOG.md`: an Unreleased entry.

**`--json` shapes:**
- `block` / `unblock`: `{number, by, via, status}`, where `status` is the role set, or null.
- `blockers` / `blocking`: `{issues: [{id, title, state, via}]}`.

## Error handling

- Unknown id, or one on an unconfigured tracker: `not-found`, from `issues resolve`.
- Same issue on both sides: `usage`.
- Native call fails for any reason except `unsupported`: the verb stops with that code. No text
  fallback, since auth or network problems shouldn't silently turn into comments.
- A partial text write (the blocked-side comment posted, the mirror failed): the verb fails and
  says which comment is missing. Rerunning `block` is safe: the record reads "linked" already,
  and the helper posts only the missing mirror.

## Testing

- **`scripts/tests/issue-deps.test.sh`**, with a stub dispatcher like `issue-copy.test.sh`:
  - native success
  - fallback on `unsupported`
  - cross-tracker goes to text
  - the mirror is posted, and a rerun posts only what's missing
  - the latest marker wins; unsigned prose is ignored
  - status set and restored: `(was …)` restore, the `new` fallback, `clear-status` without
    `new`, a manual status change left alone, no `blocked` role, `--no-status`
  - union and dedupe of native + text
  - `--json` shapes; self-link refused
- **Adapter unit tests** (`scripts/tests/issue-deps-adapters.test.sh`) with a fake `curl`, like
  `issues-get-state.test.sh`:
  - GitHub: database-id lookup and paths
  - Forgejo: `{owner, repo, index}` body; dependencies switched off gives `unsupported`
  - GitLab: `is_blocked_by` body; 403 gives `unsupported`; relates_to links filtered out
  - Jira: link type found by inward text; none gives `unsupported`; `issuelinks` parsed both
    ways
- **`issues get --json`:** `blocked_by` filled; `null` on lookup failure; no recursion.
- **Live:** each rig's `smoke.sh` gains block → blockers → blocking → unblock. On GitLab, the
  smoke test reports which path (native or text) the rig's tier took. This pins Jira's link
  direction and GitLab's refusal status.
