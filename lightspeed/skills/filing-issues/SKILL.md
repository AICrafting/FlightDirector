---
name: filing-issues
description: Use when the user invokes `/issue <description>`, or says "file an issue", "open a ticket", "track this", "add an issue for that", "create an issue", "log a bug" — even if the description is terse or vague. Also use when an existing issue's title/body is now stale and needs updating, or a comment should be added. Operates through the lightspeed dispatcher.
---

# Filing Issues

Create, dedupe-check, and update issues. A 3-word input becomes a useful, specific issue by
drawing on what was actually discussed in the session.

All backend access goes through the **lightspeed dispatcher** — never raw API calls, never MCP:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" <group> <verb> [--flag value …]
```

The dispatcher reads `.lightspeed.json` for the backend, coordinates, and label-name map, so
this skill never touches owner/repo or tokens. Verb set:
[adapter-contract.md](../../references/adapter-contract.md); config:
[lightspeed-setup.md](../../references/lightspeed-setup.md).

## Red flags — STOP

- **Never skip the duplicate check.** "Create an issue" does not mean "create blindly." Always
  list and scan existing issues first (Step 2).
- **Never modify an existing issue without confirming.** Creating is easy to undo; rewriting
  someone's issue isn't. Show the planned change and wait for agreement.
- **Never invent context.** Surface what was actually said in the session; don't pad the body
  with plausible-sounding detail that wasn't discussed.
- **Labels must already exist.** `issues create --label NAME` resolves the name and **errors if
  the label doesn't exist** — create it (`labels create`) or point the user at
  `setting-up-a-repo` first. No silent no-op.

## Step 1: Scan conversation context

Look back through the session and gather what makes the issue specific:
- Bugs mentioned but not fixed; features discussed but deferred
- Concrete details: component names, values, file paths, behaviors, colors
- Things you said like "we should probably…" / "worth noting…" / "a future improvement…"
- Design options or tradeoffs that came up

This is the step that turns a terse input into something useful. Don't invent — surface.

**Note any images** shared with the invocation. In Claude Code, attached screenshots appear
with a local file path (e.g. `[Image: source: /var/.../Screenshot.png]`). Record those paths —
you'll upload them after the issue is created (Step 7).

## Step 2: Dedupe-check against open issues

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues list --state open --limit 50
```

Output is `number⇥title⇥labels` per line — already projected, so it's light in context; raise
`--limit` only if a full page came back. Distill the proposed title + description into a few
specific keywords/phrases a near-duplicate would also use (`advantage|modifier key|shift.click`
beats `roll` — too broad) and scan titles for overlap. Pull a candidate's full text with
`issues get --number N` if a title looks close.

### Classify

| Classification | Meaning | Next action |
|---|---|---|
| **new** | No meaningful overlap | Proceed to Step 3 |
| **duplicate** | Same problem and same ask as an existing issue | Tell the user: *"#N already covers this: [title]. Add a comment there, or create a separate issue anyway?"* |
| **related** | Overlaps but different enough to stand alone | Show the overlap: *"This overlaps with #N — [title]. Comment there, or open a separate issue?"* |
| **update** | An existing issue is now stale (e.g. says "red" but the new direction is "blue") | Plan an update (Step 8) and **confirm before executing** |

Filing two related issues in one turn? Scan and classify each independently.

## Step 3: Clarifying questions (only when needed)

Ask 1–3 focused questions before writing if it's a feature with real technical choices (build
vs. third-party, where UI lives), scope is genuinely unclear, or you have a strong opinion about
the right approach — share it, don't just list options. Otherwise skip and write the issue.

## Step 4: Write the issue

**Title:** clear, specific, action-first ("Add X", "Fix Y so it Z", "Change X to Y").

**Body:**
- What the problem or feature is
- Why it matters / the context behind it (from the session)
- Specific details: component names, values, constraints, edge cases
- For features with choices: note the options briefly, with a recommendation if you have one
- Honest, not padded. If the user said "fix button color" and the session said purple to match
  the border, say exactly that.

Write the body to a temporary file in the session scratchpad and pass it as `--body-file` in
Step 6 — that keeps multi-line markdown and code fences intact without shell-quoting trouble.

## Step 5: Suggest labels

See the real taxonomy, then pick 1–3 of the **most specific** applicable labels:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" labels list
```

Output is `name⇥color⇥description`. Good distinctions: `bug` / `feature` / `ux` / `polish` /
`performance` / `tech-debt` / `security` / `quick-win` / `high-value` / `critical` /
`regression` — use the repo's actual set. If nothing fits, suggest a new label and create it
**only if the user agrees**:

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" labels create --name "new-label" --color "#0088ff"
```

If the repo has few or no labels at all, point the user at `setting-up-a-repo` to seed the
default taxonomy in one pass rather than creating labels one at a time here.

## Step 6: Create the issue

No confirmation needed to create. Labels are applied in the same call (they must already exist):

```
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues create \
  --title "…" --body-file "$SCRATCH/issue-body.md" --label bug --label ux
```

It prints the new issue `number`. Report: *"Created #N: [title]"*.

## Step 7: Attach images (if any were shared)

Upload each recorded image, then embed the returned URL in the body:

```
URL="$("$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues attach --number N \
        --file /path/to/screenshot.png --name screenshot.png)"
# append "## Screenshot\n\n![screenshot]($URL)" to the body file, then:
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues update --number N --body-file "$SCRATCH/issue-body.md"
```

**File notes:** screencapture temp files are deleted within seconds — copy to a stable location
(scratchpad / Downloads) first. If a direct path fails, glob for the newest:
`FILE=$(ls -t ~/Desktop/Screenshot*.png | head -1)`.

## Step 8: Updating an existing issue — confirm first

Only after the user agrees to the planned change:

```
# Update title and/or body (only the fields you pass are changed)
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues update --number N --title "…" --body-file "$SCRATCH/issue-body.md"

# Or add a comment
"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" issues comment --number N --body "…"
```

When rewriting a stale body, show the old content in `~~strikethrough~~` above the new content
so the change history stays visible, and add a comment explaining what changed and why.

## Common mistakes

- Filing a near-duplicate because the dedupe scan used keywords that were too broad — pick
  specific terms, and run a second pass with synonyms if the first comes up empty.
- Passing `--label` for a label that doesn't exist (it errors) — check `labels list` first, or
  create the label.
- Editing an existing issue without confirming, because the user's phrasing sounded like "just
  fix it." Confirm anyway.
- Pulling hundreds of issues into context with a huge `--limit`. Paginate.
