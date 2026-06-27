---
name: working-an-issue
description: Use when starting, progressing, or finishing work on a specific Forgejo issue — "let's work on #N", "start issue #N", "I'll take #N", "this is ready to test", "merge #N", "close out #N". Drives the per-issue branch → status-label → test → merge → finish lifecycle. Enforces: never merge to the trunk branch without explicit user approval.
---

# Working an Issue

The per-issue lifecycle: one branch per issue, status labels that mirror reality on the
board, an explicit human gate before merging, and a finishing record (summary, token cost,
model) left on the issue when it's done.

**Setup, repo coordinates, config:** see
[forgejo-setup.md](../../references/forgejo-setup.md). All issue actions go through
`mcp__forgejo__*` tools; branch/merge are git.

**Read `.lightspeed.json` first.** It gives you, for this repo: the `trunkBranch`, the
`mergeStrategy` (`pr` or `direct`), and the **actual label names** for each role — so on a
repo that calls the awaiting-test state `status/qa`, you use `status/qa`, not the plugin
default. The role names below (`status/in progress`, `status/to test`, …) are defaults;
**substitute this repo's configured names.** If no config exists, fall back to the defaults
and resolve roles against `list_repo_labels` (see setup reference). Resolve every label name
to its numeric ID before an add/remove call.

## Red flags — STOP

- **Never merge to the trunk branch without explicit user approval.** Not when tests pass,
  not when it "obviously works", not to "save a round-trip." The user tests and says merge.
  Until then, the branch stays unmerged. This is the rule the whole skill exists to protect.
- **One branch per issue.** All work for an issue lives on its own branch — never commit an
  issue's work straight onto the trunk branch.
- **Keep the board honest.** Every lifecycle transition updates the `status/*` labels, so
  the issue's state on the board always matches reality. Don't do the work and forget the label.
- **Adding/removing labels needs numeric IDs.** Resolve names → IDs from `list_repo_labels`
  first (see setup reference). Passing a name where an ID is required silently no-ops.

## Lifecycle

### 1. Start work

- Create a branch named for the issue: `feature/<N>-<slug>` or `bug/<N>-<slug>` — pick
  `feature` vs `bug` from the issue's type label (`feature`/`bug`) or its content.
- Set status to in-progress: add the `status/in progress` label.

```
# Resolve the label ID once (see setup reference), then:
mcp__forgejo__add_issue_labels(owner, repo, index=N, labels="<id of status/in progress>")
```

Do the work on that branch.

### 2. Ready for testing

When the work is done and waiting on the user to verify, hand the board over:

- Remove `status/in progress`, add `status/to test`.
- Tell the user it's ready to test, on which branch.

```
mcp__forgejo__remove_issue_labels(owner, repo, index=N, labels="<id of status/in progress>")
mcp__forgejo__add_issue_labels(owner, repo, index=N, labels="<id of status/to test>")
```

### 3. The merge gate — wait for confirmation

**Do not merge until the user has tested and explicitly says to merge.** Leave the issue at
`status/to test` and stop. If unsure whether you have approval, you don't — ask.

### 4. On approved merge — finish the issue

Only after explicit approval:

1. **Merge** per the configured `mergeStrategy`:
   - `"direct"` — local git merge of the issue's branch into `trunkBranch`, then push.
   - `"pr"` — open a Forgejo pull request (`mcp__forgejo__create_pull_request`) from the
     issue's branch into `trunkBranch`, then merge it (`mcp__forgejo__merge_pull_request`).
2. **Remove all `status/*` labels** from the issue (resolve their IDs and pass them to
   `remove_issue_labels`).
3. **Comment a finishing record** on the issue:
   - A summary of the work that was done.
   - **Token cost and model(s).** Preferred source: a `prompt_log.jsonl` in the repo root,
     if one is being maintained (each line has `session_id`, `model`, token counts, and
     `cost_usd`). Filter to this work's `session_id`(s), sum `cost_usd`/tokens for the cost,
     and read `model` for which model(s) ran. If no such log exists, fall back to a rough
     cost estimate and the model you know you're running. (The log is optional and personal
     — never required; it's gitignored and not shipped by this plugin.)
   ```
   mcp__forgejo__create_issue_comment(owner, repo, index=N, body="## Done\n\n<summary>\n\n**Est. token cost:** …\n**Model(s):** …")
   ```
4. **Add the `model/<primary>` label** for the main model used (e.g. `model/opus`) — the one
   with the most tokens/cost in the log when available, else the model you ran. Resolve its
   ID and add it. See the `model/*` set in
   [default-labels.md](../../references/default-labels.md).
5. **Close the issue:**
   ```
   mcp__forgejo__issue_state_change(owner, repo, index=N, state="closed")
   ```

## Common mistakes

- Merging because tests passed, without the user's explicit go-ahead. The gate is the user,
  not the test result.
- Doing the work but leaving the label at `status/in progress` (or never setting it) — the
  board now lies. Transition the label every time.
- Passing label *names* to `add_issue_labels`/`remove_issue_labels` and getting a silent
  no-op. Resolve to numeric IDs first.
- Closing the issue but forgetting the finishing comment (summary / cost / model) — that
  record is the auditable point of the whole workflow.
