---
name: triaging-issues
description: Use when the user asks what to work on next — "what should I work on", "what's next", "any quick wins", "show me the open issues", "what's in the backlog", "pick something to do". Lists and filters open issues for selection. Read-only — it never creates or modifies anything.
---

# Triaging Issues

Before the first command, follow [runtime preflight](../../references/runtime.md).

List open issues and filter them down to what's actually workable, so the user can pick.

All backend access goes through the **flight dispatcher** — never raw API calls, never MCP:

```
flight <group> <verb> [--flag value …]
```

The dispatcher reads `.flightdirector/config.json` for the backend, coordinates, and the
label-name map, so this skill never touches owner/repo or tokens. Verb set:
[adapter-contract.md](../../references/adapter-contract.md).

## Read-only

This skill only reads. It never creates, edits, comments on, or closes issues. If the user
wants to file or change something, that's `filing-issues`.

## Step 1: List open issues

```
flight issues list --all-trackers --state open --limit 50
```

Every configured issue tracker is listed, in config order, each through its own coordinates,
credential and label map. Output is one issue per line, tab-separated — the issue's id, then
that tracker's ordinary row:

```
<id>⇥<native id>⇥<title>⇥<comma,separated,labels>
FJ-12⇥12⇥Fix the login redirect⇥bug,quick-win
JIR-7⇥PROJ-7⇥Rotate the signing key⇥security
```

The id is the one to show and hand on. With several trackers it is qualified (`FJ-12`,
`JIR-7`) — two trackers can both have an issue 12, so a bare number is never enough there. With
a single tracker it is the issue's own name (`#12`, or `PROJ-7` on Jira), because the prefix
would say nothing (#258). A tracker that cannot be reached is named on
stderr (`flight: tracker GH unavailable: …`) and the exit status is non-zero while the other
trackers' rows still print — say that tracker is **unavailable**; never present it as an empty
backlog.

It's already projected to just these fields, so it stays light in context — keep `--limit`
reasonable. The adapter pages underneath it, and warns on **stderr** when the limit hid rows
(`warning: showing 50 of 109 rows for /issues`); that warning, not a full page, is the cue to
raise `--limit` and list again. If there's no `.flightdirector/config.json`, the
dispatcher errors clearly; that's the cue to run `setting-up-a-repo` first.

## Step 2: Apply the workable filter

**Exclude** any issue whose label column carries a workflow status label from its **originating
tracker** — the ref before the `-` in its id (a single-tracker `#12` has only the one
tracker: omit `--tracker`). Read that tracker's names with
`flight issues tracker --tracker "$REF" | jq '.labels.status'` and use only those for its rows,
never another tracker's labels (two trackers may spell `to-test` differently). `false` or absent roles have no label to match. A status label means the issue is
already in flight, awaiting test, in review, in QA, blocked, or deferred. Common defaults are:

- `status/in progress` — already in flight
- `status/to test` — built, awaiting verification
- `status/review` — in an open PR, under review
- `status/qa` — merged, awaiting real-world verification
- `status/blocked` — can't be started
- `status/deferred` — intentionally not now

**The one exception is the `new` role** (`issueTrackers[].labels.status.new`, when configured):
it means *filed and not yet triaged*, which is the most workable state there is, not a stage of
the workflow. **Never exclude it** — excluding every status label blindly would hide exactly the
issues this skill exists to surface, on any repo that turns the role on. It also makes "show me
the untriaged ones" a real filter: for each tracker whose `new` role is a string, list with
`issues list --tracker "$TRACKER" --label "$NEW_LABEL"`, then qualify each result. A tracker
with `new:false` or no `new` role has no starting-status label to filter on.

Do the exclusion while scanning the fourth (labels) column of the listing. This filter is
**specific to "what can I work on" listings** — it does NOT apply to dedupe checks or general
triage, which see everything.

## Step 3: Present the pick-list

Show a concise, scannable list — the id from the first column, title, and the labels that help
the user choose (`quick-win`, `high-value`, `bug`, `critical`). Don't dump full bodies; pull one
with `flight issues get --number "$ID"` (the id routes itself), only if the user drills into a
specific issue. Hand that **id** to `working-an-issue`, which resolves it once and retains it.
With several trackers it is qualified, never a bare number that would mean whichever tracker is
the default; with one tracker the bare `#12` it shows is unambiguous.
Group by something
meaningful (quick wins vs. larger work, or by feature-area label) if it helps, and offer a
recommendation if one stands out.

## Common mistakes

- Applying the workable filter when the user actually asked for *all* open issues or a
  general overview — the filter is only for "what should I work on."
- Dumping full issue bodies into a wall of text. Keep it a pick-list.
- Pulling hundreds of issues into context with a huge `--limit`. Keep it sane and raise it only
  when the adapter's truncation warning says the list was short.
