# Example promotion flows

`GUIDE.md` walks one issue through file → work → promote on a single pipeline. This doc shows the
**pipeline itself** at four depths, each with a deliberately different setup, so you can pattern-match
your repo onto the closest example. Every flow is just `code.stages` in `.flightdirector/config.json` plus
the label map — the skills (`working-an-issue`, `promoting-a-branch`, `promoting-branches`) read that
config and behave accordingly. Nothing here is new machinery; it's the same hop, configured differently.

See [flight-setup.md](flight-setup.md) for the full config schema and
[adapter-contract.md](adapter-contract.md) for the verbs.

## How to read these

Each hop in `code.stages` is defined by a few knobs:

| Knob | Values | What it controls |
|---|---|---|
| `merge` | `direct` \| `pr` | `direct` = merge `--no-ff` straight into the stage branch. `pr` = open a pull request, watch CI, merge on the gate. |
| `gate` | `pre-merge` *(default)* \| `post-merge-qa` | `pre-merge` waits for your explicit go-ahead before merging. `post-merge-qa` merges then verifies in the stage. Governs **merging only** — not issue lifecycle. |
| `strategy` | `merge` *(default)* \| `squash` \| `rebase` | How a **`pr`** hop merges. `direct` hops always `--no-ff` and ignore this. |
| `issueStatus` | a `labels.status` role | On *entering* this stage, each linked issue is atomically relabelled to this status (old status dropped in the same call). Omit to leave status untouched. |
| `closesIssues` | boolean *(default: true iff terminal stage)* | Whether reaching this stage **closes** linked issues. Override to close early at a non-terminal stage, or keep issues open past the terminal one. |

One more knob lives at the top level, not per stage:

- **`code.ciWatchTimeout`** (seconds; default `900`, `0` disables) — the hang-guard for `ci watch` on
  `pr` hops. If a PR's CI produces no matching run within the window, the watch exits with an error
  instead of polling forever. Precedence: `--timeout` flag → `LS_CI_WATCH_TIMEOUT` env →
  `code.ciWatchTimeout` → default. It's referenced below wherever a `pr` hop has a CI gate.

`stages[0]` is always the **first integration branch** — feature branches fork from it, and that's the
one hop `working-an-issue` and `queue-batches` stop at (the to-test merge gate).

---

## 1 hop — trunk-only, direct

The simplest possible setup: one stage, no PRs. Good for a solo repo or a spike where you commit-review
in the session and integrate straight onto the trunk.

```json
"code": {
  "backend": "forgejo", "owner": "me", "repo": "sketch",
  "stages": [
    { "name": "main", "merge": "direct", "issueStatus": "done" }
  ]
}
```

- **Hops:** feature → `main` (the only hop; `main` is `stages[0]` *and* terminal).
- **Merge:** `direct` (`--no-ff`). No PR, no CI watch, no strategy choice.
- **Issue lifecycle:** `main` is terminal, so `closesIssues` defaults to `true`. On promotion the
  linked issue is relabelled `status/done` **and closed** in one hop.

**What you see:** `working-an-issue` forks `feature/<n>-<slug>` off `main`, sets `status/in progress`,
and stops at the merge gate. On "promote", `promoting-a-branch` merges `--no-ff` into `main`, sets
`status/done`, and closes the issue. That's the whole climb.

---

## 2 hops — `develop → main`, direct then PR

An integration branch plus a release gate. Day-to-day work lands on `develop` with no ceremony; shipping
to `main` goes through a reviewed, CI-checked PR.

```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
  { "name": "main",    "merge": "pr",     "strategy": "squash", "issueStatus": "done" }
]
```

- **Hops:** feature → `develop` (direct) → `main` (pr).
- **`develop` (direct):** merge `--no-ff`; issue → `status/to test`. `closesIssues` defaults to `false`
  here (not terminal), so the issue **stays open** — visible on the board as "to test".
- **`main` (pr):** opens a PR, drafts a test plan per resolved issue, **watches CI** (bounded by
  `code.ciWatchTimeout`), and merges by **`squash`** once green and you approve (`pre-merge` gate is the
  default). `main` is terminal → issue relabelled `status/done` and closed.

**What you see:** the issue climbs open-and-visible (`status/to test`) until the `main` PR merges, then
flips to `status/done` and closes — one reviewed PR per release, individual commits collapsed by squash.

---

## 3 hops — `develop → qa → main`, status per stage

Add a `qa` stage between integration and production. This is the canonical setup for "merged but not yet
verified in a real environment". Each stage carries its own `issueStatus`, so the board mirrors exactly
where an issue sits, and issues stay open until the terminal stage.

```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge",     "issueStatus": "in-progress" },
  { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "strategy": "merge", "issueStatus": "qa" },
  { "name": "main",    "merge": "pr",     "gate": "pre-merge",     "strategy": "squash", "issueStatus": "done" }
]
```

- **feature → `develop` (direct):** `--no-ff`; issue → `status/in progress`, stays open.
- **`develop` → `qa` (pr, `post-merge-qa`):** one PR into `qa`, CI watched (`code.ciWatchTimeout`
  applies), merged with a plain `merge` commit. The `post-merge-qa` gate means it merges then you verify
  in the `qa` environment. Issue → `status/qa`, still open.
- **`qa` → `main` (pr, `pre-merge`):** reviewed PR, CI watched, **squash**-merged on your go-ahead.
  `main` is terminal → `status/done` + closed.

**What you see:** `status/in progress` → `status/qa` → `status/done` — one label per stage (the atomic
`set-status` guarantees only one shows at a time), and the issue closes exactly when it lands on `main`.
`closesIssues` is left default throughout, so only the terminal stage closes.

> **Tip — close early instead.** If your `qa` stage is where you consider work "done" and `main` is a pure
> release cut, set `"closesIssues": true` on the `qa` stage; the issue then closes on entry to `qa` and the
> `main` promotion is purely a branch move.

---

## 4 hops — long pipeline, all three merge strategies side by side

A deeper pipeline that puts `squash`, `merge`, and `rebase` next to each other so the `strategy` knob is
legible. Example: `develop → staging → qa → main`.

```json
"stages": [
  { "name": "develop", "merge": "direct", "gate": "pre-merge",     "issueStatus": "in-progress" },
  { "name": "staging", "merge": "pr",     "gate": "post-merge-qa", "strategy": "squash", "issueStatus": "to-test" },
  { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "strategy": "rebase", "issueStatus": "qa" },
  { "name": "main",    "merge": "pr",     "gate": "pre-merge",     "strategy": "merge",  "issueStatus": "done" }
]
```

- **feature → `develop` (direct):** `--no-ff`; `status/in progress`.
- **`develop` → `staging` (pr, squash):** collapses the integrated work into one commit on `staging`;
  `status/to test`. CI watched.
- **`staging` → `qa` (pr, rebase):** replays commits onto `qa` with no merge commit — a linear `qa`
  history; `status/qa`. CI watched.
- **`qa` → `main` (pr, merge):** a merge commit preserving the branch's commits on `main`; terminal →
  `status/done` + closed.

Every `pr` hop here has a CI gate, so `code.ciWatchTimeout` governs each watch. The three strategies show
their distinct effects on target history: **squash** (one commit), **rebase** (linear, no merge commit),
**merge** (merge commit, commits preserved).

---

## Batch-promote: `direct` vs `pr` first hop

The examples above promote one branch at a time. When a `queue-batches NxM` run leaves many feature
branches (one per issue, grouped into zones), **promoting-branches** promotes a *group* at once into
`stages[0]` — and the **first hop's `merge` strategy changes what "promote" means**. This is the clearest
way to see the direct-vs-pr contrast, so run the *same phrasing* against two repos that differ only in
`stages[0].merge`.

Setup: a `3x5` run → **15 feature branches**, 3 zones of 5.

- **Direct first-hop repo** — `stages[0] = { "name": "develop", "merge": "direct" }`
- **PR first-hop repo** — `stages[0] = { "name": "main", "merge": "pr", "strategy": "squash" }`

| Spoken command | Groups resolved | Direct repo (`develop`) | PR repo (`main`) |
|---|---|---|---|
| "promote each zone" | 3 (one per zone) | 15 `merge --no-ff` into `develop` | **3 PRs** — one per zone, each combining that zone's 5 issues |
| "promote the first zone" | 1 (zone 1) | 5 merges into `develop` | 1 PR combining zone 1's 5 issues |
| "promote issues 18, 93, 12" | 1 (those 3) | 3 merges into `develop` | **1 PR** combining those 3 branches |

**PR mechanism per group:** make an integration branch (e.g. `batch/<zone>`), merge the group's issue
branches into it, open **one** PR into `stages[0]`, watch CI (`code.ciWatchTimeout` applies), merge on the
gate. Failure handling is **continue-and-report**: a conflicting branch or group is skipped and recorded,
and the rest still promote.

So a `direct` first hop fans a group out into N independent merges; a `pr` first hop collapses each group
into a single reviewed, CI-checked PR. Same command, same branches — the pipeline config decides the shape.

---

## See also

- **[promoting-a-branch](../skills/promoting-a-branch/SKILL.md)** — the one-hop promotion these flows are
  built from (merge strategy, gate, and stage-driven issue lifecycle).
- **[promoting-branches](../skills/promoting-branches/SKILL.md)** — the batch (multi-branch) first-hop
  promotion in the section above.
- **[setting-up-a-repo](../skills/setting-up-a-repo/SKILL.md)** — how the `stages` pipeline and label map
  get written in the first place.
- **[flight-setup.md](flight-setup.md)** — the config schema reference.
