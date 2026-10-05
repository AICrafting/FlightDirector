---
name: copying-an-issue
description: Use when copying an issue from one configured issue tracker to another, or bringing an earlier copy up to date — "copy FJ-12 to GH", "pull GH-3 into Forgejo", "put this on Jira too", "move this issue over to the public tracker", "resync the copy", "bring the GitHub copy up to date". Copies the title plus optional body, comments, labels and status, refuses a second copy of the same issue, and later posts only the comments the copy is missing. Never closes the source.
---

# Copying an Issue

Before the first command, follow [runtime preflight](../../references/runtime.md).

Copy one issue from the tracker it lives on to another configured tracker, or resync an earlier
copy with the comments added to the source since. Everything goes through the dispatcher:
`flight issues copy` and `flight issues resync` read and write each side with that tracker's own
credential and label map, and record the link in the git-ignored
`.flightdirector/copies.jsonl` ledger. Verb details:
[adapter-contract.md](../../references/adapter-contract.md) → *`issues copy` / `issues resync`*.

## Red flags — STOP

- **Never skip the duplicate scan.** The dispatcher refuses a second copy it has recorded, but
  only on this machine. Copies made by hand, by someone else, or on another clone are found
  only by scanning the target tracker (Step 2).
- **Preview before writing.** Always show the `--dry-run` plan and get the user's OK before the
  real copy. A copy is visible on the target at once, and on a public tracker it is public.
- **Copy, never move.** Closing or relabelling the source is a separate, explicit request — not
  part of "move this over". Say so if the user asked to move it.
- **Private → public needs a word.** When the target is the public tracker (or the user's
  wording suggests the source is private), point out that the body and comments become visible
  there, and offer `--no-comments` / `--no-body`. The footer and back-link stay off unless asked:
  they name the source issue.
- **Never pass `--force` on your own.** It exists for a deliberate second copy; use it only when
  the user says so after seeing the existing copy.

## Step 1: Resolve both ends

```bash
ISSUE="$(flight issues resolve --number "$INPUT")"     # FJ-12, GH#3, PROJ-7, or a bare number (default tracker)
QUALIFIED="$(jq -r '.qualified' <<<"$ISSUE")"; DISPLAY="$(jq -r '.display' <<<"$ISSUE")"
DST_T="$(flight issues tracker --tracker "<what the user named>" | jq -r '.ref')"
```

An unknown tracker name is an error listing the configured trackers: ask, never guess. If
`DST_T` is the issue's own tracker, there is nothing to copy; say so.

## Step 2: Duplicate scan on the target (copy only)

```bash
flight issues get --number "$QUALIFIED"
flight issues list --tracker "$DST_T" --state open --limit 100
```

Pick a few specific words from the source title and scan the target's titles for them. If the
stderr warning says rows were held back (`showing 100 of N`), list again with a higher
`--limit`. When a title looks close, pull it with `issues get --number <ID>` (the list's id column) and ask the
user: *"GH-7 looks like the same issue: [title]. Copy anyway, resync that one instead, or stop?"*
A tracker reported `unavailable` was not scanned: say so rather than "no duplicates".

## Step 3: Preview

```bash
flight issues copy --from "$QUALIFIED" --to "$DST_T" --dry-run [component flags]
```

Components: body, comments, labels and status are copied by default. `--no-body`,
`--no-comments`, `--no-labels` and `--no-status` turn them off. `--footer` (a "Copied from …"
line in the copy) and `--back-link` (a "Copied to …" comment on the source) are off unless the
user asks. Show the plan as printed. It lists what will be copied, how the status maps, and the
labels the target lacks, which are skipped: labels are never created on the target. If the
dispatcher says the issue was already copied there, offer a resync (Step 5) instead.

## Step 4: Copy

After the user agrees:

```bash
flight issues copy --from "$QUALIFIED" --to "$DST_T" [the same component flags] --model <your-model-id>
```

It prints the new issue's id (`GH-5`); skipped labels or status are named on stderr. Report:
*"Copied FJ-12 to GH-5 (body, 3 comments, labels bug; status to-test). Skipped: area/app (GH
doesn't have it)."* If it stops partway through the comments, it says so, and the ledger
already holds what landed. Run the resync it names to finish the job.

## Step 5: Resync an earlier copy

```bash
flight issues resync --from "$QUALIFIED" --to "$DST_T" --dry-run
flight issues resync --from "$QUALIFIED" --to "$DST_T" --model <your-model-id>
```

Resync posts the source comments the copy doesn't have yet, oldest first, and touches nothing
else: not the title, body, labels or status, and not comments edited after they were copied. It
prints how many it posted (`0` = up to date). "No copy … in this clone's ledger" means the copy
was made elsewhere or never: there is nothing to resync from here.

## Common mistakes

- Treating the dispatcher's refusal as the whole duplicate check. It only knows this clone's copies.
- Copying without the preview because the request sounded certain.
- Closing the source after a "move". That needs its own explicit go-ahead.
- Adding `--footer` / `--back-link` by default. They reveal the source's id on the target.
