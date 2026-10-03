# Copy issues between named trackers

Design for FJ-200, agreed in the 2026-10-03 planning discussion. Builds on the named-tracker
foundation from #97 (#197–#199, shipped in 0.17.0), whose design left copying and syncing out of
scope. Reviewed against develop `702b454`.

## Decision and scope

Add an explicit, user-triggered **copy** of one issue from any configured tracker to any other,
and a **resync** that later brings the copy up to date with comments added on the source. Every
supported backend pair works (Forgejo, GitHub, GitLab, Jira, in either direction, including two
trackers on the same backend). Each copied component is optional.

Out of scope: scheduled or webhook sync, two-way sync, resyncing title/body/labels/status,
chasing edits to already-copied comments, copying assignees or the open/closed state,
re-uploading attachments, and moving (closing the source). Work keeps happening on whichever
tracker an issue lives on; nothing here makes adoption into another tracker part of the normal
workflow.

## Commands

Two dispatcher-owned verbs in the `issues` group. Like `branches` and `issues resolve`, they are
implemented once in the dispatcher (a new `flight/scripts/issue-copy` helper it delegates to) on
top of the existing adapter verbs, so no adapter changes and every backend pair is covered:

```
flight issues copy   --from <ID> --to <TRACKER> [component flags] [--force] [--dry-run] [--json] [--model <id>]
flight issues resync --from <ID> --to <TRACKER> [--dry-run] [--json] [--model <id>]
```

- `--from` takes any issue id `issues resolve` accepts (`FJ-12`, `GH#3`, `PROJ-7`, a bare number
  for the default tracker). `--to` takes a tracker ref or alias. Copying an issue to its own
  tracker is an error.
- `copy` prints the new issue's display id (`GH-5`); `--json` prints
  `{"source", "target", "copied": {...}, "skipped": {...}}`.
- `resync` prints the number of comments posted (`0` is success); `--json` gives the same
  `copied`/`skipped` shape.
- `--dry-run` reads both sides and prints the plan (components, mapped labels and status, labels
  and roles that will be skipped, comment count) without writing anything, including the ledger.
- Reads go through `issues get --json` and `issues comments --json` (stable comment ids); writes
  through `issues create`, `issues comment`, `issues set-status`. Each call carries its own
  `--tracker`, so each side uses its own credential and label map.

### Components

| Component | Default | Flag | Behaviour |
|---|---|---|---|
| title | always | — | copied verbatim |
| body | on | `--no-body` | copied as text; Jira bodies arrive through the existing ADF→text conversion and leave through markdown→ADF |
| comments | on | `--no-comments` | posted oldest-first, each opening with an attribution line: `**<author>** commented on <YYYY-MM-DD>:` (the copy is posted by the target token's user, so authorship must be stated) |
| labels | on | `--no-labels` | non-status source labels whose **exact name** exists on the target are applied at creation; the rest are skipped and reported. Labels are never created on the target |
| status | on | `--no-status` | the source's status label → its role in the source tracker's `labels.status` map → the target tracker's label for that role. A role the target doesn't define (or defines as `false`) is skipped and reported. When no status is copied, the target's `new` starting status applies as for any created issue |
| footer | off | `--footer` | appends `Copied from <source display id>` to the copy's body |
| back-link | off | `--back-link` | posts `Copied to <target display id>` as a comment on the source issue |

Status labels are handled only by the status mapping, never as plain labels. The footer and
back-link name issues by tracker ref and id only — never a URL or host — and are off by default,
so by default a copy from a private tracker to a public one reveals nothing about the source.

Signatures need no special handling: the dispatcher already drops a trailing flight signature and
re-signs every body it writes, so the copy and its comments end with this run's signature, not a
stacked one.

## The copy ledger

Links between sources and copies live in a local, git-ignored ledger:
`<main checkout>/.flightdirector/copies.jsonl` — the same `.flightdirector/` the config and
prompt log use, so every worktree of the repo shares it. Copied issues carry no hidden markers.

One JSON object per line, append-only:

```json
{"source": "FJ-12", "target": "GH-5", "at": "2026-10-03T08:00:00Z",
 "components": ["body", "comments", "labels", "status"], "comments": ["17969", "17970"]}
```

- `source` / `target` are qualified ids. The latest record for a `source` → target-tracker pair
  wins; `comments` is the complete set of source comment ids already **handled** — copied, or
  deliberately left out by a `--no-comments` copy (which records every comment that existed at
  copy time).
- `copy` writes a record immediately after the issue is created and a new one after each comment
  is posted. A failure partway (comment 4 of 7) leaves a ledger that lists comments 1–3, so the
  next `resync` posts only 4–7.
- Lines that fail to parse are ignored with a warning; the file is never rewritten by flight.
- The ledger is per machine. On another machine `resync` reports that it knows no copy for the
  pair; the soft duplicate check (below) is what catches copies made elsewhere.

## Duplicate prevention

Two layers:

1. **Hard (dispatcher).** `copy` refuses when the ledger already holds a copy of the source on
   the target tracker, naming it (`FJ-12 was already copied to GH-5 — use 'issues resync', or
   --force for a second copy`). Exit code and `--json` error follow the `_errors.sh` conventions
   (`code: "already-copied"`).
2. **Soft (skill).** Before copying, the skill scans the target tracker's open issues for titles
   that look like the source, as `filing-issues` does, and asks the user when one is close. This
   catches copies made by hand, on another machine, or before the ledger existed.

## Resync

`resync` finds the latest ledger record for the pair, re-reads the source's comments, and posts
those whose ids are not in the record, oldest-first, with the same attribution line, recording
each as it goes. It touches nothing else on either side. A source comment that was edited after
being copied is not re-posted. After a `--no-comments` copy, resync posts only comments added to
the source since the copy, because the ledger records the earlier ones as handled.

## Errors

- Unknown/ambiguous `--from` or `--to`, or `--to` equal to the source tracker → usage error
  listing the configured trackers.
- Either tracker unreachable → stop before writing, naming the tracker.
- A failed write after creation → stop, report what was copied (the ledger already reflects it)
  and that `resync` can finish the comments. Labels/status failures are reported as skipped, not
  fatal, since the issue itself exists.

## Skill: copying-an-issue

A new skill, triggered by "copy FJ-12 to GH", "pull GH-3 into Forgejo", "move this issue over to
Jira" (copy only — closing the source stays a separate, explicit action), "resync the copy". It:

1. Resolves the source and the target tracker (asking on an unknown name, never guessing).
2. Runs the soft duplicate scan on the target tracker.
3. Shows the `--dry-run` plan: components, label/status mapping, what will be skipped.
4. Runs `copy` (or `resync`) after the user agrees, passing `--model`.
5. Reports the new id and anything skipped.

`filing-issues` gains a one-line pointer to it for copy requests.

## Testing

- `scripts/tests/issue-copy.test.sh` with stub trackers (the pattern the existing dispatcher
  suites use): each component flag on and off; label matching and skipping; status role mapping
  including a role the target lacks and `new` applying when no status is copied; the ledger
  refusal and `--force`; partial failure followed by a resync that posts only the remainder;
  resync posting nothing when up to date; `--dry-run` writing nothing; a Jira-shaped source body.
- Live: on this repo, copy GH-3 → FJ and an FJ scratch issue → GH, add a source comment, resync,
  then clean up the scratch issues.

## Documentation

`adapter-contract.md` (the two dispatcher verbs), `json-output.md` (the `--json` shapes and the
`already-copied` error code), `flight-setup.md` (the ledger file), GUIDE, CHANGELOG.
