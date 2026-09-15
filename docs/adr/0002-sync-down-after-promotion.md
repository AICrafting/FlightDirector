# 2. Sync the source stage back down after a promotion

- **Status:** Accepted
- **Date:** 2026-09-11
- **Decided in:** #10 (exploration); implementation tracked separately

## Context

Flight promotes one hop at a time up a configured stage pipeline (`develop → qa → main`).
`promoting-a-branch` merges the source into the target and pushes; it does nothing to the
source afterwards. With the default `merge` strategy the target gains a merge commit the source
never sees, so after every promotion the lower stage is one commit behind the stage it just fed.
Release tags land on `main` and are invisible from `develop`; a human comparing tips sees drift.

The drift is cosmetic under `merge`, because the source stays an ancestor of the target. It is
not cosmetic under `squash` or `rebase` (#9): those write new SHAs onto the target, the source
stops being an ancestor, and the next promotion re-presents the same changes. It is also not
cosmetic whenever a target stage receives work of its own — a conflict resolved during the
promotion, a hotfix on `main` — because nothing carries that work back down and it resurfaces
as a conflict at the next promotion.

This repo's own history (3 stages, ~15 promotions) shows the merge-only case: every hop is a
true merge commit and every lower stage is a strict ancestor of the one above it.

## Decision

### 1. Policy: merge the target back into the source, and cascade

After a promotion into `stages[i]` succeeds (`i ≥ 1`, i.e. the source is itself a stage),
`promoting-a-branch` walks `j = i-1 … 0` and merges `stages[j+1]` into `stages[j]`.

- The back-merge is always a **true merge**: fast-forward when the lower stage is a strict
  ancestor (the common case, adding no commits), a merge commit otherwise.
- It is **strategy-agnostic**. Under `merge` it is a pure fast-forward. Under `squash`/`rebase`
  both sides carry the same changes, git merges them cleanly, and the one merge commit realigns
  the merge base so the next promotion presents only new work.
- It **cascades**: promoting `qa → main` syncs `main → qa`, then `qa → develop`, so every lower
  stage is level after one promotion.
- A **conflict stops the cascade**. The merge is aborted (or the PR is left open), the state is
  reported, and the user decides. The agent never resolves conflicts, never rebases, and never
  resets a stage onto another tip.
- **Feature hops never sync down.** A feature branch is leftovers after promotion;
  `cleaning-up-branches` deletes it. The batch promoter (`promoting-branches`) is feature-only
  and is unaffected.

### 2. Surface: per-stage `syncDown`, defaulting to the stage's own `merge`

Each stage may declare how it **receives** a back-merge:

```
{ "name": "qa", "merge": "pr", "syncDown": "pr" | "direct" | "none" }
```

- **Default is the stage's own `merge` value**, so a stage that is written by PR is also
  synced by PR, and a direct-merge stage is synced by direct push. This repo needs no config
  change: `develop` syncs by push, `qa` by a PR from `main`.
- **`none`** opts the stage out and stops the cascade there (stages below it are not synced
  either, since they would need this stage's tip).
- The field lives on the **receiving** stage because it describes a write into that branch,
  exactly as `merge` does for promotions into it.

### 3. Mechanics per mode

- **Freshness check first** on the receiving stage, with the existing table from
  `promoting-a-branch` Step 4a: behind → fast-forward; ahead or diverged → STOP.
- **`direct`:** `git merge --ff <upper>` in the checkout holding the lower stage, then push. If
  that checkout is dirty and the merge refuses, fork a throwaway worktree from
  `origin/<lower>`, merge there, push `HEAD:<lower>`, and report that the local checkout is
  now behind (it fast-forwards at the next freshness check).
- **`pr`:** open a PR `<upper> → <lower>`, watch CI, and **auto-merge on green** with the
  `merge` method — never the stage's promotion `strategy`, because squashing a back-merge
  re-diverges the branches. The content is already on a higher stage, so there is nothing new
  to gate on; red CI or a conflict leaves the PR open and stops. The PR body carries no
  `Closes`/`Ready` lines; issue lifecycle is driven by the promotion, not the sync.
- The sync runs as a final step of `promoting-a-branch`, after the issue-lifecycle step.

## Consequences

- Lower stages stay level with the stages above them; `git describe` on `develop` sees release
  tags; the mental model `develop ≤ qa ≤ main` holds by construction.
- `squash`/`rebase` become usable at a hop without poisoning the next one.
- A PR-synced stage gains one back-merge commit per promotion above it. That is the GitFlow
  "merge back from release" cost and is accepted.
- A stage that rejects direct pushes but is configured `merge: direct` will fail the push;
  set `syncDown: "pr"` or `"none"` on it.
- Every git write in the sync is anchored (`git -C …`), fetched first, and stops on
  ahead/diverged, so the sync inherits the same safety posture as the promotion itself.

## Alternatives considered

- **Fast-forward only.** Cleanest, but invalid the moment the source moved on or the hop used
  `squash`/`rebase`. Kept as the preferred outcome of the true merge, not as the policy.
- **One hop only (no cascade).** Leaves `develop` behind after every `qa → main` release and
  needs a manual second step, which is the drift this decision exists to remove.
- **Realign the source (reset onto the target tip) after squash/rebase.** Rewrites shared
  history on an integration branch; rejected outright, not even as an option.
- **Single global `code.syncDown` switch.** Cannot exclude one protected stage; per-stage
  matches the schema every other promotion knob already uses.
- **Status quo plus documentation.** Correct but leaves the squash/rebase divergence and
  target-side fixes as recurring manual work.
