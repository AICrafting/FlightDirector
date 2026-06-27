---
name: triaging-issues
description: Use when the user asks what to work on next — "what should I work on", "what's next", "any quick wins", "show me the open issues", "what's in the backlog", "pick something to do". Lists and filters open Forgejo issues for selection. Read-only — it never creates or modifies anything.
---

# Triaging Issues

List open issues on a Forgejo repo and filter them down to what's actually workable, so
the user can pick. Through the forgejo MCP server.

**Setup and repo coordinates:** see [forgejo-setup.md](../../references/forgejo-setup.md).

## Read-only

This skill only reads. It never creates, edits, comments on, or closes issues. If the
user wants to file or change something, that's `filing-issues`.

## Step 1: Read repo coordinates

Get `owner`/`repo` (see setup reference). Ask if unset and not obvious from context.

## Step 2: Fetch open issues

```
mcp__forgejo__list_repo_issues(owner, repo, state="open", type="issues", limit=50)
```

Results land in context — keep `limit` reasonable and paginate (`page=2`, …) only if a
full page came back.

## Step 3: Apply the workable filter

**Exclude** any issue carrying a status label that means it isn't pickable right now — the
in-progress, awaiting-test, blocked, and deferred roles. Use **this repo's** names for those
roles from `.lightspeed.json` if present (e.g. it may call awaiting-test `status/qa`);
otherwise fall back to the plugin defaults:

- `status/in progress` — already in flight
- `status/to test` — built, awaiting verification
- `status/blocked` — can't be started
- `status/deferred` — intentionally not now

(The MCP `labels` filter only *includes* labels, so do the exclusion while scanning the
fetched results.)

This filter is **specific to "what can I work on" listings.** It does NOT apply to dedupe
checks or general triage — those see everything.

## Step 4: Present the pick-list

Show a concise, scannable list — number, title, and the labels that help the user choose
(e.g. `quick-win`, `high-value`, `bug`, `critical`). Don't dump full bodies. If useful,
group by something meaningful (quick wins vs. larger work, or by feature-area label), and
offer a recommendation if one stands out.

## Common mistakes

- Applying the workable filter when the user actually asked for *all* open issues or a
  general overview — the filter is only for "what should I work on."
- Dumping full issue bodies into a wall of text. Keep it a pick-list.
- Pulling hundreds of issues into context with a huge `limit`. Paginate.
