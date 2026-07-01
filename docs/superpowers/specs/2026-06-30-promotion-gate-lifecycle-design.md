# Stage-driven issue lifecycle / promotion-gate revamp

**Issue:** cerebralgardens/claude-tools#7
**Date:** 2026-06-30
**Status:** Design approved — ready for implementation plan

## Problem

With a multi-stage pipeline (e.g. `develop → qa → main`), a linked issue is **closed at
the first merge** and is therefore already closed by the time the branch reaches a later
stage that wants it open. The two skills disagree on lifecycle:

- **`working-an-issue`** hard-closes the issue (`clear-status` + `issues close`) on the
  approved merge to `stages[0]` — the *first* hop.
- **`promoting-a-branch`** `post-merge-qa` hop is built to keep issues *open* (`Ready #N`,
  move to `status/qa`) and close only when a later promotion carries them to the final
  stage. It moves an already-closed issue.

This is a **plugin product bug**, not a config gap in this repo. This repo deliberately runs
a 2-hop `develop → main` pipeline with no `qa` stage, so the bug is invisible while
dogfooding. A *consuming* repo configured `develop → qa → main` (develop pre-merge, qa
post-merge) is broken: the issue is closed at the develop merge, so the qa machinery has
nothing open to move.

## Core decision

An issue's **open/closed state** and **status label** become a function of its **stage
position** in the pipeline, instead of being hardcoded to close at the first merge. The
**work ledger** (summary + cost + tokens + model) is decoupled from both and accumulates
per work episode.

## Model

Three concerns that are tangled together today get cleanly separated:

| Concern | Driven by | When it happens |
|---|---|---|
| **Status label** (`to-test`, `qa`, …) | the stage the issue currently sits in | set on *entering* a stage (on promotion) |
| **Open / closed** | whether that stage is terminal, overridable per stage | close on entering a stage whose effective `closesIssues` is true |
| **Work ledger** (summary + cost + tokens + `model/*`) | each work episode, independently | appended whenever an agent finishes a chunk of work |

## Config schema — two optional per-stage fields

Each `code.stages[*]` entry gains two optional fields:

```jsonc
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
  { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
  { "name": "main",    "merge": "pr" }                                       // terminal → closes
]
```

- **`issueStatus`** — a **status role name** (as in `labels.status`). On *entering* this
  stage, the promotion runs the existing **atomic `set-status --status <role>`** (adds the
  new status, drops the others in one call — preserving the "board can never show two
  states" invariant). Omit to leave the issue's status untouched on entry.
- **`closesIssues`** — boolean. **Defaults to "true iff this is the terminal (last) stage."**
  Set explicitly to override:
  - `false` on the terminal stage → issues stay **open** even after the final stage.
  - `true` on a non-terminal stage → issues close **early** at that stage (e.g. close at
    `develop`, treat `main` as a pure release cut).

Both fields are optional; existing configs keep working unchanged.

### Why typed fields and not a `startTasks`/`endTasks` DSL

A declarative action-list DSL (`["applyLabel:status/qa", "closeIssue", …]`) was considered
and rejected for this scope:

1. It discards the **atomic `set-status` invariant** — a hand-authored
   `removeLabel`+`applyLabel` pair is non-atomic and mis-orderable, so the board can show
   two statuses (or none) on a typo.
2. `endTasks` is nearly dead weight: stages only transition by promotion, so "leaving
   develop" *is* "entering qa" — one event. The entry side suffices; you never leave the
   terminal stage.
3. It pushes a safety-critical, ~90%-identical policy into hand-written, runtime-fail-prone
   config; the typed fields make the common case a zero-config default.
4. It needs a parser + a frozen verb vocabulary wired to dispatcher calls — surface area
   for a capability no concrete second use case needs yet.

The fields are **forward-compatible**: if a real need for arbitrary, non-status actions
appears later (post a comment, ping, `released` label, reopen-on-regression), an optional
`onEnter` task list can be added *alongside* the fields without breaking the defaults.

## Skill changes

### `promoting-a-branch` — owns status + close

Centralize lifecycle transitions here, since it performs every hop and knows the target
stage. After a successful merge into the target stage, for each resolved `#N`:

- target stage `issueStatus` set → atomic `set-status --status <role>`.
- effective `closesIssues` true → `issues close --number N`; else leave open.

This **replaces** today's special-cased `post-merge-qa` block (Step 5) with one stage-driven
rule that applies to every hop, `direct` and `pr` alike.

### `working-an-issue` — stops closing; ledger only

- **Remove** the `clear-status` + `issues close` from step 4. It no longer closes issues.
- **Keep** the work-ledger responsibility: append the finishing comment (summary + token
  cost + tokens + `model/*` label) for the episode it just finished, then delegate the
  promotion to `promoting-a-branch` (which sets status / closes per the target stage).
- Worktree removal on merge stays.

### Work ledger — per episode

The ledger is decoupled from merge/close entirely. **Any** agent that completes a chunk of
work on an issue appends its own comment (summary + token cost + tokens + model) and adds
the `model/*` label (idempotent). Initial code at `develop`, follow-up code, and QA at the
`qa` stage each leave their own entry. The issue's comment thread is the running ledger —
consistent with #8's "later comment wins."

## PR keyword rule

On a `pr` hop, derive the PR's issue keyword from the **target stage**, not the gate:

- target stage effectively `closesIssues` true → `Closes #N`
- otherwise → `Ready #N`

The backend's auto-close fires exactly when config says close, never prematurely. This
generalizes today's `Ready`/`Closes` split, which was keyed on the `post-merge-qa` gate.

## Backwards compatibility

- **Single-trunk** (`stages: [{ name: "main", "merge": "pr" }]`): `main` is terminal →
  `closesIssues` defaults true → closes at the first merge. **No behavior change, no new
  config.**
- **This repo's 2-hop** (`develop → main`): issues now stay **open** at `develop` and close
  at the `main` release PR. Accepted change. To preserve today's close-at-develop, set
  `"closesIssues": true` on the `develop` stage.
- The `gate` field is unchanged and remains orthogonal — it governs *merge* policy
  (`pre-merge` needs the user's go-ahead; `post-merge-qa` merges then verifies), not issue
  lifecycle.

## Scope / outputs

This issue is the decision/spec. It spawns implementation work (one issue or a small
cluster — decided at planning time):

1. **Config schema** — add `issueStatus` + `closesIssues` to `code.stages[*]`;
   `setting-up-a-repo` offers/writes them; document in `lightspeed-setup.md`.
2. **`promoting-a-branch`** — stage-driven status/close for all hops; PR keyword rule;
   remove the `post-merge-qa` special case.
3. **`working-an-issue`** — stop closing; ledger-only finishing; keep worktree removal.
4. **Docs** — `lightspeed-setup.md` stages section + any GUIDE references.

## Open follow-ups (not this issue)

- Coordinates with **#10** (sync source branch down after promotion) and **#9** (document
  `--strategy`) — the promotion-semantics cluster.
