# Multiple Issue Trackers Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans within each assigned Flight batch zone. Stop at the to-test gate; no push or promotion.

**Goal:** Implement #197–199 as one coordinated batch, retaining each issue's tracker throughout setup and work.

**Architecture:** The dispatcher resolves named tracker identities and supplies adapters with scoped configuration. Workflow helpers retain resolved identities; setup uses the same config and routing contract. Three isolated issue branches start from refreshed develop and are verified together before release.

**Tech Stack:** Bash (including 3.2 compatibility), jq, existing shell test harness and adapter mocks.

**Spec:** ../specs/2026-09-20-multiple-issue-trackers-design.md

## Global constraints

- Exactly one default tracker; stable case-insensitively unique references and aliases.
- No copying/syncing issues; #200 is separate.
- Preserve `new` as string, false, or absent, including #193 behavior.
- Independent secrets remain gitignored; no private hosts in shared docs.
- One issue branch/worktree per issue. All git calls use explicit `-C`.
- No pushes or stage merges; default changes must not redirect existing work.

## Review focus

- Machine-local array overrides must not expose local values in tracked config.
- Alias parsing must reject ambiguity and conflicting explicit selections.
- Legacy branches must retain original tracker identity after default changes.
- PR closing keywords must not target an unrelated same-number code issue.
- Setup reruns must not change default or re-ask explicitly declined settings.

## Shared contract

- Top-level `issueTrackers` entries use `ref`, `name`, `default`, backend coordinates, `labels`, optional `aliases` and explicit credential selection.
- Gitignored secrets associate tracker credentials by stable reference, never array index. The foundation owner documents the exact credential selection fields before consumers finalize.
- `flight issues <verb> --tracker REF --number N` and `flight labels <verb> --tracker REF` select one tracker. `flight auth check --tracker REF` verifies that tracker.
- `flight issues resolve --number INPUT [--tracker REF]` returns JSON with `tracker`, `number` (native ID as a string), `qualified` (canonical REF-N), and `branchPrefix` (lowercase ref plus numeric suffix). No secrets or private URLs.
- `flight issues list --all-trackers` returns qualified identities while ordinary list retains its existing TSV contract.
- Lifecycle helpers are separate scripts. #197 owns dispatcher wiring; #198 sends any required new dispatcher entrypoint contract to #197 rather than editing its files independently.
- Consumers pass a resolved explicit tracker on all later issue/label writes.

## Zone foundation — #197

Own `flight/scripts/flight`, new tracker configuration/resolution helpers, necessary adapter changes, and new/updated dispatcher/config tests under `scripts/tests/`. Report exact schema and CLI contracts to both other zones before they finalize docs.

- [ ] Read issue body/comments and the spec. Record baseline checks from develop.
- [ ] Add failing shell tests for effective legacy config migration, independent secrets, local overrides, interrupted retry, schema guards, stamp preservation, and `new` string/false/absent.
- [ ] Implement validated, recoverable migration into the tracker array without changing unrelated code config or leaking effective local overrides.
- [ ] Add failing tests for exact/alias references, ambiguous splits, Jira native keys, default selection, explicit conflicts, all-tracker partial failure, and two trackers on one backend.
- [ ] Implement `--tracker`, `issues resolve`, and `--all-trackers` against the shared contract; propagate only selected tracker configuration to adapters.
- [ ] Run affected existing config/reconcile/auth/default-status tests and new tests, then the repository's applicable checks. Commit only after passing checks.

## Zone lifecycle — #198

Own `flight/scripts/branches`, `flight/scripts/batch-manifest`, new lifecycle identity helpers, their tests, and working/filing/triaging/queue/promoting/cleanup skills and queue worker templates. Do not edit the dispatcher or setup skills. Coordinate legacy identity binding with #197's migration.

- [ ] Read issue body/comments and spec; inspect every bare-number extraction in branch and batch consumers.
- [ ] Add failing tests for qualified branches and manifests, same-number issues, durable legacy bindings, and default changes during active work.
- [ ] Implement a shared retained-identity helper and extend batch/branch consumers without guessing legacy identities that cannot be recovered.
- [ ] Update workflow skills to resolve once and use explicit tracker/native ID for every later write, including ledger/model labels.
- [ ] Add coverage for same-code-repository closing keyword eligibility and cross-tracker promotion safety; retain semantic stage roles and backend closure behavior.
- [ ] Run affected branch/batch tests and applicable checks. Report combined-foundation verification needs before marking ready. Commit after checks pass.

## Zone setup — #199

Own `flight/skills/setting-up-a-repo/SKILL.md`, new `flight/skills/add-an-issue-tracker/SKILL.md`, setup-specific tests, `flight/references/flight-setup.md`, `flight/references/adapter-contract.md`, skill inventories and public guides. Other zones send contract documentation requirements here.

- [ ] Read issue body/comments, spec, and updated #193 setup behavior.
- [ ] Create the shared tracker setup skill with unique reference/alias selection, independent auth, tracker-specific label adoption and gap checks.
- [ ] Delegate first tracker creation from repo setup, retaining code/pipeline ownership and preserving existing defaults on reruns.
- [ ] Preserve explicit `new:false`, unanswered absence, and configured labels independently for each tracker.
- [ ] Update config/CLI references and skill discovery inventories using #197's finalized contract; update breadcrumb examples with tracker-qualified branches.
- [ ] Validate first run, rerun, second tracker, Jira project references, collisions, credentials, and label adoption with the repository's applicable skill/document checks and focused scenarios. Commit after passing checks.

## Batch integration and handoff

- [ ] Record the three zones in the Flight batch manifest and stream worker progress.
- [ ] Inspect all diffs and combine patches in a disposable verification checkout, without merging or promoting issue branches.
- [ ] Run relevant existing and new shell suites together. Check end-to-end migration → resolve → work identity → default change → original tracker write, plus setup contract consistency.
- [ ] Send failures to the owning zone and rerun affected checks after fixes.
- [ ] Mark each completed issue to-test, report commits and validation, and leave branches unmerged for user-directed serial promotion (#197 before #198/#199).
