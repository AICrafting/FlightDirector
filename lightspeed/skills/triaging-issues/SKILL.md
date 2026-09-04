---
name: triaging-issues
description: Use when the user asks what to work on next — "what should I work on", "what's next", "any quick wins", "show me the open issues", "what's in the backlog", "pick something to do". Lists and filters open issues for selection. Read-only — it never creates or modifies anything.
---

# Triaging Issues

Before the first command, follow [runtime preflight](../../references/runtime.md).

List open issues and filter them down to what's actually workable, so the user can pick.

All backend access goes through the **lightspeed dispatcher** — never raw API calls, never MCP:

```
lightspeed <group> <verb> [--flag value …]
```

The dispatcher reads `.lightspeed/config.json` for the backend, coordinates, and the
label-name map, so this skill never touches owner/repo or tokens. Verb set:
[adapter-contract.md](../../references/adapter-contract.md).

## Read-only

This skill only reads. It never creates, edits, comments on, or closes issues. If the user
wants to file or change something, that's `filing-issues`.

## Step 1: List open issues

```
lightspeed issues list --state open --limit 50
```

Output is one issue per line, tab-separated:

```
<number>⇥<title>⇥<comma,separated,labels>
```

It's already projected to just these fields, so it stays light in context — keep `--limit`
reasonable and raise it only if a full page came back. If there's no `.lightspeed/config.json`, the
dispatcher errors clearly; that's the cue to run `setting-up-a-repo` first.

## Step 2: Apply the workable filter

**Exclude** any issue whose label column carries a status label — carrying *any* of the
configured `labels.status` roles means the issue is already somewhere in the workflow (in
flight, awaiting test, in review, in QA, blocked, or deferred), so it isn't a fresh pick. Use
**this repo's** names from `.lightspeed/config.json` `labels.status` if present (e.g. awaiting-test
may be `status/testing`); otherwise the defaults:

- `status/in progress` — already in flight
- `status/to test` — built, awaiting verification
- `status/review` — in an open PR, under review
- `status/qa` — merged, awaiting real-world verification
- `status/blocked` — can't be started
- `status/deferred` — intentionally not now

Do the exclusion while scanning the third (labels) column of the listing. This filter is
**specific to "what can I work on" listings** — it does NOT apply to dedupe checks or general
triage, which see everything.

## Step 3: Present the pick-list

Show a concise, scannable list — number, title, and the labels that help the user choose
(`quick-win`, `high-value`, `bug`, `critical`). Don't dump full bodies; pull one with
`issues get --number N` only if the user drills into a specific issue. Group by something
meaningful (quick wins vs. larger work, or by feature-area label) if it helps, and offer a
recommendation if one stands out.

## Common mistakes

- Applying the workable filter when the user actually asked for *all* open issues or a
  general overview — the filter is only for "what should I work on."
- Dumping full issue bodies into a wall of text. Keep it a pick-list.
- Pulling hundreds of issues into context with a huge `--limit`. Paginate instead.
