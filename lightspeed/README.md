# lightspeed (Claude Code plugin)

Two skills for managing issues on a **Forgejo** repo from within a Claude Code session,
working entirely through the [forgejo MCP server](https://codeberg.org/goern/forgejo-mcp)
— no curl and no token handling. (Adding/removing labels on an issue still takes numeric
label IDs, resolved per-session from `list_repo_labels`; see the setup reference.)

| Skill | Triggers on | Does |
|---|---|---|
| `filing-issues` | "file an issue", "open a ticket", "track this", "log a bug", `/issue …` | Dedupe-check → write → label → create; or confirm-then-update an existing issue |
| `triaging-issues` | "what should I work on", "what's next", "quick wins", "show open issues" | Lists and filters open issues for selection (read-only) |
| `working-an-issue` | "let's work on #N", "start issue #N", "this is ready to test", "merge #N" | Per-issue branch → status-label → test → merge → finish lifecycle, with a human gate before merge |
| `bootstrapping-labels` | "set up labels", "bootstrap labels", "add default labels", or a bare repo during filing | Reconciles a default taxonomy against existing labels, previews, creates only what's missing |

## Default labels

`bootstrapping-labels` seeds a consistent taxonomy on first install, idempotently — it only
adds what's missing and **adopts your existing conventions**: if the repo already calls the
awaiting-test state `status/qa`, it uses `status/qa` for that role rather than creating its
own `status/to test`, and never renames or deletes existing labels. The taxonomy is **data**
in [`references/default-labels.md`](references/default-labels.md) (flat `bug`/`feature`/
`tech-debt`, namespaced `model/*`, project-dependent `area/*` confirmed against the repo).

Bootstrap also asks your **merge strategy** (Forgejo PR vs. direct git merge) and trunk
branch, and writes everything — merge prefs plus the role→your-label-name map — to a
per-repo **`.lightspeed.json`**. The other skills read that file, so they speak your
repo's label names and follow your merge style. (Schema in
[`references/lightspeed-setup.md`](references/lightspeed-setup.md).)

It's a user-triggered skill, not an auto-run install script — because labels are created
through the `forgejo` MCP tools (which only the agent can call), a standalone script would
have to reintroduce the curl + token handling this plugin avoids.

The split is along trigger boundaries: *creating/changing* an issue and *picking work*
have different vocabularies and shouldn't share one description. `filing-issues` keeps
create + update together because they share the dedupe-check decision tree.

## Prerequisite: the forgejo MCP server

This plugin **does not bundle an MCP server** — it depends on one you install and register
yourself, under the server name `forgejo`. See
[`references/lightspeed-setup.md`](references/lightspeed-setup.md) for why (bundling would
collide with the server you already run, and a plugin can't ship a third-party binary),
plus install and configuration details.

## Configuration

- Install goern/forgejo-mcp and register it as `forgejo` (so tools are `mcp__forgejo__*`).
- Run `bootstrapping-labels` once per repo — it autodetects owner/repo from the git remote,
  asks your merge strategy and trunk branch, reconciles labels, and writes
  `.lightspeed.json`. That's the setup; no env vars to set by hand in the normal case
  (`FORGEJO_OWNER`/`FORGEJO_REPO` remain an optional override).

Full details: [`references/lightspeed-setup.md`](references/lightspeed-setup.md).

## MCP-only by design

These skills call MCP tools directly (`create_issue`, `add_issue_labels`,
`list_repo_issues`, …). That choice removes the curl, token handling, and HTTP status-code
discipline the original `issue` skill carried. Two things it does **not** remove: adding or
removing labels on an issue still takes numeric label IDs (resolved per-session from
`list_repo_labels`), and `list_repo_issues` results land in conversation context (handled
by paginating with sane limits).
