# Multiple named issue trackers

Design for #97, based on the agreed planning discussion. Implementation follows in
separate issues; this change documents the design only. Reviewed against develop
`afefaa7`, including #193's optional starting status.

## Decision and scope

Support an array of named issue trackers with exactly one default. Work an issue
on its originating tracker throughout its lifecycle; adoption into another tracker
is not required. Code, PRs, CI, and the stage pipeline remain configured by `code`.
Copying, mirroring, syncing, and scheduled intake are outside this phase.

This replaces the original two-source intake proposal. A read-only secondary view
would not support working directly on either tracker; mandatory adoption would
create unwanted copies. Named trackers support both public and private workflows
without assuming a fixed number of systems or synchronizing their contents.

## Configuration

Introduce top-level `issueTrackers`, replacing the singular `issues` object and
moving the existing issue label map into each tracker. Schema 3 is the next version
at this design's base; implementation must use the next available schema version
if another migration lands first.

Illustrative entry (the existing `code` and `harnesses` objects remain):

```json
{
  "schemaVersion": 3,
  "issueTrackers": [
    {
      "ref": "FJ",
      "name": "Working backlog",
      "default": true,
      "backend": "forgejo",
      "api": "https://forge.example.com/api/v1",
      "owner": "example",
      "repo": "project",
      "labels": {
        "status": { "new": false, "done": "status/done" },
        "model": { "astra": "model/astra" }
      }
    }
  ]
}
```

The abbreviated label map above is illustrative, not a replacement for the full
existing taxonomy. Move all existing role mappings, including model labels, into
the tracker. Each tracker owns its coordinates, authentication selection, label
map, and any backend-specific workflow settings. Multiple entries may use the same
backend, including different repositories or Jira projects on one host.

`ref` is a stable, case-insensitively unique identifier; `name` is a display name.
Optional aliases must also be unique across references and aliases. Prefer Jira's
configured project key (e.g. `PROJ`), otherwise suggest `GH`, `FJ`, or `GL`.
Resolve collisions during setup, never by guessing at dispatch time. References
must remain stable once used in branches; changing a display name is harmless.

Keep tokens in gitignored secrets, keyed by tracker reference rather than array
position. An explicit credential reference may reuse code credentials when both
targets match; never implicitly send code credentials to a different tracker.
Trackers must support independent tokens, including two trackers of one backend.

## Issue identity and routing

- Bare `1` or `#1` resolves against the default tracker at initial selection.
- `GH1`, `GH-1`, and `GH#1` resolve against the exact reference or alias `GH`,
  case-insensitively. `PROJ-1` resolves to the Jira project tracker and preserves
  the native Jira issue key when calling its adapter.
- Evaluate candidate reference/number splits against configured references. If
  more than one matches, fail with the candidates instead of selecting one.
- Approximate names produce suggestions requiring a user choice; they never
  silently select a read or write target. Conflicting explicit selectors fail.
- After resolution, retain the tracker reference and native issue identifier.
  Comments, work-ledger entries, model labels, status, assignment, and closure all
  use that resolved identity, even if the default changes during the work.

The proposed explicit dispatcher selector is `--tracker <ref>`, supported for
issue and label operations and tracker authentication checks. Existing unqualified
issue commands select the default. PR and CI operations continue to use `code`.
Adapters receive resolved coordinates, credentials, native issue identifiers, and
only the selected tracker's label map. They do not choose a tracker themselves.

Triage offers an all-trackers view with qualified identities and applies each
tracker's own status map. Keep the existing single-tracker list output compatible;
an explicit all-trackers mode adds the source identity. A failed tracker is
reported as unavailable, never presented as an empty backlog.

## Branches and promotion

New branches and worktrees always include the reference, including for the default:
`feature/gh-1-description` and `.worktrees/gh-1-description`. Jira uses
`feature/proj-1-description`, not `feature/jira-1-description`. Batch manifests and
other persisted issue references carry tracker identity as well as the native ID.
Branch parsing, cleanup, promotion, commit conventions, and batch work must share
one identity contract rather than independently extracting a bare number.

For existing unqualified branches/manifests, bind their identity to the migrated
original default before enabling default changes; retain that binding in durable
local work metadata. Never reinterpret old work using whichever default is current.
If a legacy branch has no recoverable binding, require explicit tracker selection.

Stage `issueStatus` values remain semantic roles, mapped through the originating
tracker. Stage `closesIssues` policy remains on the code pipeline. The tracker
adapter performs the appropriate close operation/native transition. Jira currently
uses labels for `set-status`; this design does not silently redefine all statuses
as Jira native workflow transitions. Preserve current behavior and route existing
backend closure behavior to the selected tracker.

Promotion explicitly updates the originating tracker. Generate automatic closing
keywords only when the issue and PR are on the same backend instance and repository
and the destination stage closes issues. Never emit bare `Closes #N` for an issue
from another tracker. Do not publish private issue URLs, bodies, comments, or ledger
contents into a public PR or tracker by default.

## Migration and reconciliation

1. Resolve the old effective issue configuration, including `issues` overrides
   and inherited `code` fields, into one default tracker. Prefer a configured Jira
   project key for its reference; otherwise use the backend shorthand.
2. Move the complete issue label map into that entry, preserving unknown roles and
   `new` as a string, `false`, or absent. Preserve other explicit false/null values
   and unknown config fields. Code coordinates and stage policy stay intact.
3. Migrate issue credential selection in gitignored secrets without exposing tokens
   in config, output, diffs, or documentation. Preserve existing code credentials.
4. Handle tracked config and machine-local overrides separately. Current recursive
   config merging replaces arrays wholesale: preserve that documented behavior,
   make overrides supply a complete tracker array, and never persist local/private
   effective values into tracked config. Detect conflicting mixed old/new forms
   before changing files; report a repairable error instead of losing data.
5. Validate the complete result, write recoverably, and advance `schemaVersion` and
   the running harness's Flight `reconciledWith` stamp only on successful migration.
   Preserve other harness/plugin stamps; an older runtime must reject unsupported
   schemas rather than rewriting them. Migration must be retry-safe after failure.
6. Repeated reconciliation preserves existing tracker arrays, references, default,
   secrets associations, and label decisions. It must not append another default.

## Setup skills

Create `add-an-issue-tracker` as the shared tracker setup flow: coordinates, unique
reference and aliases, credential selection/check, label adoption and reconciliation,
and tracker-specific options. Reuse existing equivalent labels without renaming or
deleting them. Offer `new` using #193's gap-check semantics: absence asks; `false`
means declined; a string means configured.

`setting-up-a-repo` owns code and pipeline setup, then delegates initial tracker
creation to this skill and marks that first tracker default. On rerun it preserves
all existing trackers and the chosen default, delegates tracker gap checks, and
does not recreate the first tracker. Adding a tracker never switches the default
unless explicitly requested. Update setup breadcrumbs and reference documentation
to describe both code and named issue trackers without disclosing private hosts.

## Delivery and verification

Implement in dependency order: configuration/migration and dispatch foundation;
tracker-aware work lifecycle; shared tracker setup. Land the setup and lifecycle
consumers with the foundation before releasing the new schema to existing users.

Verification must exercise legacy inherited/split configurations, independent
secrets, local overrides, migration retries/idempotence, unchanged harness stamps,
and all three `new` cases. Test duplicate/ambiguous references, Jira keys, two
trackers with issue 1, and a default change during active work. Verify comments,
labels, ledgers, promotion, closure, batch identity, and cleanup remain attached to
the correct tracker; verify cross-tracker PRs cannot close a same-number code issue.
Setup scenarios cover first run, rerun, adding a second tracker, and label adoption.

Follow-up issues:

- #197 — named tracker configuration, migration, and dispatcher routing.
- #198 — tracker identity across issue work, batches, and promotion; depends on #197.
- #199 — shared tracker setup and repo setup delegation; depends on #197.
- #200 — separate copy/sync investigation, outside this phase.

Related existing work:
#118 covers an offline tracker and sync dump; #193 supplies the starting-status
behavior this design preserves; #196 concerns auth diagnostics from worktrees.
