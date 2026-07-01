# Batch-promote — design

**Issue:** #27 (supersedes #6, the declined one-worktree-per-zone approach)
**Status:** approved design, pre-implementation

## Motivation

A `queue-batches` run leaves N×M unmerged feature branches (one worktree per
issue), each linked to an issue at `to-test`. Promoting them today is M serial
`promoting-a-branch` invocations — the real pain point. #6 proposed collapsing a
zone onto one shared worktree/branch, but that forks the one-issue-one-branch
invariant (independent test/promote/revert per issue) for a minority "issues build
on each other" case. Declined.

**Batch-promote** removes the serial-promotion tedium *without* touching that
invariant: each issue keeps its own branch; a single command promotes a chosen
**group** of them at the first hop, honoring that hop's configured merge strategy.

## Scope

- **First hop only** — `feature → stages[0]`. Promotion *up* the pipeline
  (`develop → qa → main`) stays one-at-a-time via `promoting-a-branch`; there is
  normally only one branch at those hops.
- The first hop's strategy may be **direct** (e.g. `stages[0] = develop`) or **pr**
  (e.g. a 1-hop `stages[0] = main`). Batch-promote handles both.
- Out of scope: shared-worktree/stacked-branch mode (#6), multi-stage jumps.

## Core model — groups

A spoken selection resolves to one or more **groups**, each a set of feature
branches:

| Phrase | Groups |
|---|---|
| "promote each zone" | one group per zone |
| "promote the first zone" | one group (that zone) |
| "promote issues 18, 93, 12" | one group (those branches) |
| "promote all to-test" | one group (everything ready) |

Each group is promoted honoring the first hop's `merge` strategy:

- **direct hop:** every branch in the selection is `git merge --no-ff`'d into
  `stages[0]`, one after another. Grouping is effectively just *which* branches.
- **pr hop:** **one PR per group.** Build an integration branch for the group
  (`batch/<group>` off `stages[0]`), merge the group's issue branches into it, push,
  open one PR into `stages[0]`, watch CI, merge on the gate. So `#groups = #PRs`.

The same phrase does the right thing per repo: a pile of direct merges for a direct
hop; one-PR-per-group for a pr hop.

## Selection & grouping resolution

Batch-promote is a **skill** — it interprets natural-language intent into groups,
then drives promotion. Resolution:

- **Candidate branches** are local `feature/*` branches whose linked issue is at
  `to-test` (the same "ready" set the board shows). A branch whose issue is not at
  `to-test`, or whose worktree is gone, is not a candidate.
- **Explicit issues** ("18, 93, 12") and **all** ("all to-test") resolve straight
  from that candidate set — **stateless**, no manifest needed. Explicit selection is
  one group; "all" is one group.
- **Zone selection** ("each zone" / "the first zone") needs the run's issue→zone
  map, which comes from the **manifest** (below). "each zone" → one group per zone;
  "the first zone" → the first zone (skill disambiguates if several manifests exist).
- A candidate branch that maps to **no** zone, or **multiple** zones, is reported and
  left out of zone-based groups (promote it explicitly instead).

## The manifest

`queue-batches` cannot always derive zones from `.lightspeed/config.json`
`code.zones` — when a repo has no zones configured it **infers** pseudo-zones from
issue bodies at run time. Those inferred groupings live nowhere else, so re-deriving
from config globs is impossible. Hence a manifest.

**Written by `queue-batches` at run start:**

```jsonc
// .lightspeed/batches/<run-id>.json   (run-id = the run's UTC timestamp)
{
  "runId": "2026-07-01T14-22-05Z",
  "stages0": "develop",            // first-hop target at run time (informational)
  "zones": {
    "lightspeed": [18, 93, 12],
    "docs":       [40, 41]
  }
}
```

- Location `.lightspeed/batches/`, **gitignored** (transient local run-state, same
  category as `.worktrees/`). Unique run-id → parallel batches never collide.

**Two decoupled roles** (this is the key to no lingering entries):

1. **Selection input** — read *only* for zone phrasing. Explicit/all selection
   ignores it for *choosing* branches.
2. **Cleanup ledger** — maintained on **every** promotion, whatever the selection
   mode was.

**Maintenance rules:**

- **Consume on promote:** after batch-promote successfully promotes an issue, remove
  that issue from whatever manifest lists it. When a manifest's `zones` become empty,
  delete the file. (So #18/#93/#12 are pruned even when named explicitly, not via a
  zone.)
- **Self-heal on read:** whenever batch-promote loads manifests, first drop any entry
  whose issue is no longer at `to-test` (already promoted — possibly via the normal
  single-branch skill — or otherwise gone), and delete emptied files.

Net: a manifest can only ever shrink. A fully-promoted batch's file disappears on its
own; a partially-promoted one lists exactly what's left; a batch promoted entirely
outside batch-promote is cleaned on the next read.

### Zone-name collisions across manifests

If two live manifests both contain a zone of the same name (parallel batches on the
same zone — unusual, since `queue-batches` warns on overlap), "promote each zone"
treats same-named zones as **one group** (one PR for a pr hop). Same zone = same PR
boundary, which is the desired semantics.

## Per-issue bookkeeping at promotion

For each issue it promotes, batch-promote performs the same promote-time steps as
`working-an-issue` Step 4 / `promoting-a-branch` Step 5, per branch:

- Ensure a **work-ledger** comment exists. `queue-batches` branches already have one
  (`done-<N>.md` posted at `to-test`); for a branch worked outside queue-batches,
  batch-promote writes a short finishing record.
- Add the **`model/<primary>`** label.
- Drive **status/close from the target stage** (`stages[0]`'s `issueStatus` /
  `closesIssues`) — do not hard-code. For a non-terminal `stages[0]` (Dave's
  `develop`) the issue stays open at that stage's status; for a terminal `stages[0]`
  (Aaron's `main`) it closes.
- Remove the issue's **worktree** once its branch is merged.

For a **pr** group, the PR body carries the per-issue `Closes #N` / `Ready #N`
keyword (per the target stage's `closesIssues`) and a test-plan block per issue —
reusing `promoting-a-branch`'s pr-hop rules. **Halt the group** if a resolved issue
has no writable test plan (the existing pr-hop guard).

## Failure handling — continue-and-report

- **direct hop:** promote branches one by one; on a failure (merge conflict, bad
  signature that won't re-sign, gate) skip that branch — leave its issue at
  `to-test`, unmerged — and continue. Report promoted-vs-skipped-with-reason at the
  end.
- **pr hop, building the integration branch:** if one issue branch conflicts while
  assembling a group's integration branch, skip *that branch* (note it), keep the
  rest of the group, and open the PR for the mergeable subset. If CI fails or the
  group can't merge, the whole group stays open and is reported.
- A skipped/failed issue is never removed from its manifest (it wasn't promoted), so
  a re-run naturally retries it.

## Surface / architecture

- **New skill** `promoting-branches` (working name), sibling of `promoting-a-branch`.
  It owns: intent→groups resolution, the per-hop orchestration loop, and the
  summary. It **reuses** `promoting-a-branch`'s per-branch/per-PR mechanics rather
  than reimplementing merge/sign/CI logic.
- **Manifest operations** (write / prune-issue / delete-empty / self-heal / list) are
  deterministic file logic — factor into a small **tested helper** (a script under
  `lightspeed/scripts/`, unit-tested like `bump-version.sh`), not prose in the skill.
  The manifest is local state, so this is **not** a dispatcher verb (the dispatcher
  is backend-only).
- **`queue-batches` change:** write the manifest at run start (issue→zone map). Small,
  additive.
- **`.gitignore`:** add `.lightspeed/batches/`.

## Testing

- **Manifest helper (unit):** a two-/three-manifest sandbox — prune an issue, delete
  when empty, self-heal drops non-`to-test` issues, parallel manifests don't
  interfere, zone-name collision merges. Mirrors `scripts/tests/bump-version.test.sh`,
  run by `runTests.sh`.
- **Grouping resolution (unit where feasible):** given a candidate set + manifests,
  the right groups come out for each phrase (each-zone / one-zone / explicit / all),
  including multi-zone/no-zone branches excluded.
- **Promotion mechanics:** exercised against the `test-rig/` (a direct-hop repo and a
  pr-hop repo) — the existing rig pattern — rather than unit tests, since they touch
  git + backend. Assert: direct hop → N merges into `stages[0]`; pr hop → one PR per
  group; continue-and-report leaves the right issues at `to-test`; manifests shrink
  to nothing.

## Open implementation questions (for the plan, not blockers)

- Exact skill name and its `SKILL.md` shape (mirror `promoting-a-branch`).
- Whether the manifest helper is one script with subcommands or a few tiny scripts.
- Integration-branch naming for pr groups (`batch/<zone>` vs `batch/<run-id>-<zone>`)
  to avoid collisions across re-runs.
