# Lightspeed Codex Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Lightspeed installable and usable from Claude Code and Codex from one source tree, with per-harness reconciliation metadata and on-demand model labels.

**Architecture:** Keep the dispatcher, backend adapters, references, and skill workflows shared. Add a Codex manifest and local marketplace metadata, expose idempotent dispatcher operations for compatibility reconciliation and label creation, and isolate the small amount of harness-specific worker orchestration in references selected by the active harness.

**Tech Stack:** Bash, jq, JSON plugin manifests, Markdown skills, shell unit tests

**Spec:** Approved in the 2026-09-04 conversation; no separate design document was requested.

## Global Constraints

- Preserve the existing Claude Code plugin and workflow behavior.
- Keep one shared implementation rather than maintaining independent Claude and Codex copies.
- Treat model labels as runtime provenance and create missing `model/*` labels lazily.
- Use `harnesses.<name>.reconciledWith` for plugin/config compatibility, not model discovery.
- Never overwrite or delete an existing repository label during reconciliation.
- Do not modify unrelated existing or untracked user files.

---

### Task 1: Idempotent label creation

**Files:**
- Create: `scripts/tests/labels-ensure.test.sh`
- Modify: `lightspeed/scripts/adapters/forgejo/labels`
- Modify: `lightspeed/scripts/adapters/github/labels`
- Modify: `lightspeed/scripts/adapters/gitlab/labels`
- Modify: `lightspeed/scripts/adapters/jira/labels`
- Modify: `lightspeed/references/adapter-contract.md`

**Interfaces:**
- Consumes: Existing adapter `_api` and `label_id` helpers.
- Produces: `lightspeed labels ensure --name NAME --color COLOR [--description TEXT]`, returning the existing or newly created label identifier.

- [ ] Write a shell test with a fake adapter API that proves an existing label is preserved and a missing label is created.
- [ ] Run the test and verify it fails because `ensure` is unknown.
- [ ] Implement `ensure` in every label adapter, including Jira's thin-label no-op semantics and create-race recovery for network backends.
- [ ] Run the focused test and the complete script test suite.

### Task 2: Harness reconciliation metadata

**Files:**
- Create: `scripts/tests/reconcile.test.sh`
- Modify: `lightspeed/scripts/lightspeed`
- Modify: `lightspeed/skills/setting-up-a-repo/SKILL.md`
- Modify: `lightspeed/references/lightspeed-setup.md`

**Interfaces:**
- Consumes: Plugin manifest version, `.lightspeed/config.json`, and explicit `--harness claude|codex`.
- Produces: `lightspeed reconcile --harness NAME`, preserving unknown config keys and atomically recording `schemaVersion` plus `harnesses.<name>.reconciledWith`.

- [ ] Write tests for missing metadata, current metadata, unknown-key preservation, and invalid harness names.
- [ ] Run the test and verify it fails because reconciliation is absent.
- [ ] Implement atomic, idempotent reconciliation in the dispatcher.
- [ ] Document and seed the metadata in first-run setup.
- [ ] Run focused and complete tests.

### Task 3: Dual-harness packaging and executable discovery

**Files:**
- Create: `lightspeed/.codex-plugin/plugin.json`
- Create: `.agents/plugins/marketplace.json`
- Modify: `scripts/bump-version.sh`
- Modify: `scripts/tests/bump-version.test.sh`
- Modify: all `lightspeed/skills/*/SKILL.md`
- Modify: `lightspeed/references/adapter-contract.md`

**Interfaces:**
- Consumes: Shared `skills/`, `scripts/`, `bin/`, and references.
- Produces: Codex-installable packaging and a documented absolute dispatcher-resolution preflight that does not rely on Codex adding `bin/` to `PATH`.

- [ ] Extend version-bump tests to require synchronized Claude and Codex manifests.
- [ ] Verify the updated test fails before changing the bump script.
- [ ] Add the Codex manifest and marketplace while preserving the Claude files.
- [ ] Update the bump script to keep both manifests synchronized.
- [ ] Add a shared skill preflight for harness identification, reconciliation, and dispatcher path resolution.
- [ ] Run manifest parsing, focused tests, and the complete suite.

### Task 4: Portable ledger labels and batch orchestration

**Files:**
- Modify: `lightspeed/skills/working-an-issue/SKILL.md`
- Modify: `lightspeed/skills/promoting-branches/SKILL.md`
- Modify: `lightspeed/skills/queue-batches/SKILL.md`
- Modify: `lightspeed/skills/queue-batches/templates/agent-prompt.md`
- Create: `lightspeed/skills/queue-batches/references/dispatch-claude.md`
- Create: `lightspeed/skills/queue-batches/references/dispatch-codex.md`
- Modify: `lightspeed/references/default-labels.md`

**Interfaces:**
- Consumes: Active model identity and the new `labels ensure` verb.
- Produces: Normalized, dynamically created `model/<family>` provenance labels and harness-selected parallel worker instructions.

- [ ] Add static validation assertions for forbidden Claude-only orchestration in the shared queue workflow and for required lazy-label steps.
- [ ] Verify those assertions fail against the current files.
- [ ] Move orchestration details into Claude and Codex references while retaining shared zoning/status policy.
- [ ] Define conservative model-family normalization and call `labels ensure` before `label-add` in every ledger path.
- [ ] Run lint, static validation, and all tests.

### Task 5: User-facing documentation and final verification

**Files:**
- Modify: `lightspeed/README.md`
- Modify: `lightspeed/GUIDE.md`
- Modify: `lightspeed/CHANGELOG.md`

**Interfaces:**
- Consumes: Implemented dual-harness behavior.
- Produces: Accurate installation, invocation, permission, and compatibility guidance for Claude Code and Codex users.

- [ ] Update terminology and provide separate Claude and Codex installation/invocation instructions.
- [ ] Document Codex sandbox/network approval expectations and multi-agent requirements.
- [ ] Record the unreleased compatibility changes.
- [ ] Run JSON validation, shell syntax checks, repository lint, and all unit tests.
