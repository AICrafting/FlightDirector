---
name: filing-issues
description: Use when the user invokes `/issue <description>`, or says "file an issue", "open a ticket", "track this", "add an issue for that", "create an issue", "log a bug" — even if the description is terse or vague. Also use when an existing issue's title/body is now stale and needs updating, or a comment should be added. Operates against a Forgejo repo via the forgejo MCP server.
---

# Filing Issues

Create, dedupe-check, and update issues on a Forgejo repo, through the forgejo MCP
server. A 3-word input becomes a useful, specific issue by drawing on what was actually
discussed in the session.

**Setup and repo coordinates:** see [forgejo-setup.md](../../references/forgejo-setup.md).
All calls go through `mcp__forgejo__*` tools — no curl, no tokens. (Adding labels to an
issue still needs numeric label IDs — see setup reference.)

## Red flags — STOP

- **Never skip the duplicate check.** "Create an issue" does not mean "create blindly."
  Always fetch and scan existing issues first (Step 3).
- **Never modify an existing issue without confirming.** Creating is easy to undo;
  rewriting someone's issue isn't. Show the planned change and wait for agreement.
- **Never invent context.** Surface what was actually said in the session; don't pad the
  body with plausible-sounding detail that wasn't discussed.
- **Labels attach in a separate call, by numeric ID.** `create_issue` takes no labels —
  create first, then `add_issue_labels` with comma-separated label **IDs** (resolve names →
  IDs from `list_repo_labels`; see setup reference). A name passed here silently no-ops.

## Step 1: Scan conversation context

Look back through the session and gather what makes the issue specific:
- Bugs mentioned but not fixed; features discussed but deferred
- Concrete details: component names, values, file paths, behaviors, colors
- Things you said like "we should probably…" / "worth noting…" / "a future improvement…"
- Design options or tradeoffs that came up

This is the step that turns a terse input into something useful. Don't invent — surface.

**Note any images** shared with the invocation. In Claude Code, attached screenshots
appear with a local file path (e.g. `[Image: source: /var/.../Screenshot.png]`). Record
those paths — you'll upload them after the issue is created (Step 8).

## Step 2: Read repo coordinates

Get `owner`/`repo` (see setup reference). If unset and not obvious from context, ask
which repo before proceeding.

## Step 3: Fetch open issues + dedupe-check

```
mcp__forgejo__list_repo_issues(owner, repo, state="open", type="issues", limit=50)
```

Paginate (`page=2`, …) only if a full page came back. **These results land in context** —
keep `limit` sane and reason page-by-page rather than pulling hundreds at once.

Distill the proposed title + description into a few specific keywords/phrases a near-
duplicate would also use (`advantage|modifier key|shift.click` beats `roll` — too broad),
and scan the fetched titles and bodies for overlap.

### Classify

| Classification | Meaning | Next action |
|---|---|---|
| **new** | No meaningful overlap | Proceed to Step 4 |
| **duplicate** | Same problem and same ask as an existing issue | Tell the user: *"#N already covers this: [title]. Add a comment there, or create a separate issue anyway?"* |
| **related** | Overlaps but different enough to stand alone | Show the overlap: *"This overlaps with #N — [title]. Comment there, or open a separate issue?"* |
| **update** | An existing issue is now stale (e.g. says "red" but the new direction is "blue") | Plan an update (Step 8) and **confirm before executing** |

Filing two related issues in one turn? Scan and classify each independently.

## Step 4: Clarifying questions (only when needed)

Ask 1–3 focused questions before writing if it's a feature with real technical choices
(build vs. third-party, where UI lives), scope is genuinely unclear, or you have a strong
opinion about the right approach — share it, don't just list options. Otherwise skip and
write the issue.

## Step 5: Write the issue

**Title:** clear, specific, action-first ("Add X", "Fix Y so it Z", "Change X to Y").

**Body:**
- What the problem or feature is
- Why it matters / the context behind it (from the session)
- Specific details: component names, values, constraints, edge cases
- For features with choices: note the options briefly, with a recommendation if you have one
- Honest, not padded. If the user said "fix button color" and the session said purple to
  match the border, say exactly that.

## Step 6: Suggest labels

Call `mcp__forgejo__list_repo_labels(owner, repo)` to see the real taxonomy, then pick
1–3 of the **most specific** applicable labels. Common distinctions that work well:
`bug` / `feature` / `ux` / `polish` / `performance` / `tech-debt` / `security` /
`quick-win` / `high-value` / `critical` / `regression`. (Use your repo's actual set.)

If nothing fits, say so and suggest a new label with a sensible hex color. Create it only
if the user agrees:

```
mcp__forgejo__create_repo_label(owner, repo, name="new-label", color="#0088ff")
```

If the repo has few or no labels at all, point the user at the `bootstrapping-labels`
skill to seed the default taxonomy in one pass rather than creating labels one at a time
here.

## Step 7: Create the issue

No confirmation needed to create. Labels are a **separate** call afterward.

```
# 1. Create — returns the new issue, including its index/number
mcp__forgejo__create_issue(owner, repo, title="…", body="…")

# 2. Resolve your chosen label names → numeric IDs (per-instance), then attach by ID
mcp__forgejo__list_repo_labels(owner, repo)   # find the ids for e.g. bug, ux
mcp__forgejo__add_issue_labels(owner, repo, index=<N>, labels="<id-bug>,<id-ux>")
```

Report: *"Created #N: [title] — [link]"*.

## Step 8: Attach images (if any were shared)

`create_issue_attachment` takes **base64-encoded** bytes. Encode the file, upload, then
embed the returned URL in the body.

```bash
# Encode the screenshot to base64 (use the scratchpad, not the user's project)
base64 -w0 /path/to/screenshot.png > "$SCRATCH/_img.b64"
```

```
mcp__forgejo__create_issue_attachment(owner, repo, index=<N>,
  content=<base64 string>, filename="screenshot.png")
# then embed the returned URL by appending to the body and updating:
mcp__forgejo__update_issue(owner, repo, index=<N>, body="<body>\n\n## Screenshot\n\n![screenshot](<url>)")
```

**Linux/macOS file notes:** screencapture temp files are deleted within seconds — copy to
a stable location (scratchpad / Downloads) first. If a direct path fails (sandbox/iCloud),
glob for the newest instead: `FILE=$(ls -t ~/Desktop/Screenshot*.png | head -1)`.

## Step 9: Updating an existing issue — confirm first

Only after the user agrees to the planned change:

```
# Update title and/or body
mcp__forgejo__update_issue(owner, repo, index=<N>, title="…", body="…")

# Or add a comment
mcp__forgejo__create_issue_comment(owner, repo, index=<N>, body="…")
```

When rewriting a stale body, show the old content in `~~strikethrough~~` above the new
content so the change history stays visible, and add a comment explaining what changed
and why.

## Common mistakes

- Filing a near-duplicate because the dedupe scan used keywords that were too broad — pick
  specific terms, and run a second pass with synonyms if the first comes up empty.
- Passing labels to `create_issue` (it ignores them) instead of `add_issue_labels`.
- Editing an existing issue without confirming, because the user's phrasing sounded like
  "just fix it." Confirm anyway.
- Pulling hundreds of issues into context with a huge `limit`. Paginate.
