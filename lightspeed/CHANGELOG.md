# Changelog

All notable changes to the **lightspeed** plugin are recorded here. Entries are
written for *consumers* of the plugin — what a repo using lightspeed would
notice — not every internal commit.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the plugin aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Heads-up for consumers:** the Claude Code plugin CLI has no version pinning —
> `marketplace update` pulls whatever the marketplace currently advertises. This
> changelog is the record of *what moved* when that happens.

## [Unreleased]

_Nothing yet._

## [0.8.0] - 2026-08-02

### Added

- `issues assign --number N --user LOGIN` (repeatable) and `issues unassign --number N`
  verbs on all four backends (#52). Assign **replaces** the assignee set. Forgejo/GitHub
  take logins as-is; GitLab resolves login → id via the instance `/users` lookup; Jira
  resolves email/display name → accountId and enforces its single-assignee model.
- `ci log` on Forgejo now fetches real logs (#54): the run is resolved via Forgejo 16's
  `/actions/runs` API and each failed job's plaintext log is dumped from
  `/actions/jobs/{id}/logs` — no more "open the web UI" pointer, no host access needed.
- `setting-up-a-repo` finishes by writing an "Issue tracking — lightspeed" breadcrumb
  into the repo's `CLAUDE.md` (#50) — backend + host + dispatcher pointers, plus workflow
  red lines that survive model switches and context compaction (#51). Existing repos can
  retrofit it with "add the lightspeed breadcrumb" (jumps straight to that step).

### Fixed

- `ci watch` on Forgejo sees runs still in `waiting` state (#53): it now polls
  `/actions/runs` (runs exist the moment they're created) instead of `/actions/tasks`
  (entries only appear once a runner picks the job up). Short `--sha` prefixes keep
  working on both `watch` and `log`.
- `ci watch` no longer counts superseded runs as failures (#43): only the latest
  attempt per (workflow, trigger event) is scored, and a newest manual re-dispatch
  (GitLab: `web` pipeline) supersedes that workflow's earlier runs — a retried-to-green
  flake now watches green, matching the providers' own UIs.

## [0.7.1] - 2026-07-09

### Fixed

- Skills now invoke the dispatcher as a bare `lightspeed` (and `batch-manifest`)
  command instead of `"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"`. `CLAUDE_PLUGIN_ROOT`
  is **not** exported to the Bash tool (only to hook/MCP/LSP/monitor subprocesses),
  so in real projects every dispatcher call failed with `exit 127`
  (`/scripts/lightspeed: no such file`). The plugin now ships `bin/lightspeed` and
  `bin/batch-manifest` entrypoints; Claude Code adds a plugin's `bin/` to the Bash
  tool `PATH`, so the bare command resolves reliably in any project. No config or
  setup change is required.

## [0.7.0] - 2026-07-03

### Added
- **Supported-backends reference** ([`references/backends.md`](references/backends.md)) covering all
  four backends — forgejo, github, gitlab, jira — each with a worked `.lightspeed/config.json`
  fragment, the provider's token-creation URL, and the **minimum** scopes/permissions the adapter
  actually needs (Forgejo `write:repository`+`write:issue`; GitHub fine-grained Contents/Issues/Pull
  requests + Actions-read for CI; GitLab `api`; Jira via the account's project role, since classic
  API tokens are unscoped). Linked from the guide.
- **`setting-up-a-repo` now detects existing backends and offers a confirm-and-go setup.** Before
  the manual prompts, the skill infers the `code` backend from the git remote host
  (github.com→github, GitLab→gitlab, Forgejo/Gitea→forgejo), reuses an existing
  `.lightspeed/config.json`, and reads Jira project keys (`ABC-123`) in commits/branches as a
  signal to pair a `jira` issues-axis backend — presenting the detected config for one-shot
  confirmation, and falling back to the existing manual flow when detection is inconclusive.
- **GitLab backend adapter** (`backend: "gitlab"`) at full parity with forgejo/github —
  `issues`, `labels`, `pr` (merge requests), and `ci` (pipelines). Point an axis at GitLab with
  `backend`/`owner`/`repo`/`api` (`https://gitlab.com/api/v4`) and a `PRIVATE-TOKEN`-scoped token
  in secrets. `pr merge --strategy squash` maps to GitLab's squash merge; `ci watch` aggregates
  all pipelines for a SHA and `ci log` pulls the failed job traces. See the adapter contract's
  "GitLab backend specifics" and the setup reference's "GitLab backend" section for the details
  (project-path addressing, issue `iid`s, scoped-status labels, async MR mergeability).
- **Jira backend adapter (issues-axis-only).** You can now point the `issues`
  axis at Jira Cloud (`issues.backend = "jira"`) while a git `code` backend keeps
  handling `pr`/`ci`. Implements `issues` + `labels` against Jira Cloud REST v3
  with HTTP Basic `email:api_token` auth. Config takes `issues.project` (the
  project key) and `issues.email`; the token goes in `issues.token`. Notable
  behaviours: the `--number` is a Jira **key** (`KAN-123`); `set-status` maps to
  `status/*` **labels** (which on Jira must be space-free single tokens);
  `close`/`reopen` drive real workflow **transitions** (Done ⇄ To-Do); issue
  bodies and comments round-trip through a minimal markdown⇄ADF shim; Jira labels
  are thin (no colour/description, name is its own id). See the setup reference
  and `adapter-contract.md` → *Jira backend specifics*.

## [0.6.0] - 2026-07-02

### Fixed
- **`ci watch` no longer hangs on an unpushed commit.** Promotions now watch CI
  by `--pr <n>` (the adapter resolves the PR's head SHA — the exact commit the
  run reports) instead of the local `git rev-parse HEAD`. Previously, if your
  local branch tip was ahead of what was pushed, the watcher polled forever for
  a SHA that had no CI run. As a backstop, `ci watch` now takes a `--timeout`
  and exits non-zero with a clear message rather than polling indefinitely.
  `promoting-a-branch` also now stops before opening a PR if local `$BRANCH` is
  ahead of `origin/$BRANCH`, so a promotion can't silently ship a PR that omits
  your latest commit.

### Changed
- **`ci watch` now aggregates *all* CI runs for a commit**, not just one. If a
  PR triggers several workflows, it stays watching until none are pending and
  reports `failure` if any run failed (previously it latched onto a single run
  and could announce success while another was still running or had failed). The
  output line is now `ci runs=<n> pending=<p> failed=<f> status=<…>`.
- **`setting-up-a-repo`** now also gitignores `.lightspeed/batches/` (the per-run
  batch manifests `queue-batches` writes) alongside `.lightspeed/secrets.json`
  and `.worktrees/`, so batch state isn't accidentally committed.
- **`setting-up-a-repo`** notes the optional Forgejo label-exclusivity guard
  (set `status/*` exclusive, `model/*` non-exclusive) — lightspeed doesn't need
  it (`set-status` already enforces one status), so it's left to preference.

### Added
- **`code.ciWatchTimeout`** config field sets the `ci watch` hang-guard timeout
  in seconds (default `900`; `0` disables). Precedence: `--timeout` flag →
  `LS_CI_WATCH_TIMEOUT` env → `code.ciWatchTimeout` → default.
- **`references/example-flows.md`** — worked promotion pipelines at 1/2/3/4 hops
  with contrasting `direct`/`pr`, merge-strategy, and issue-status setups, plus
  how batch-promote differs by first-hop strategy. Linked from `GUIDE.md`.

## [0.5.0] - 2026-07-02

### Added
- **`promoting-branches` skill** — batch-promote several first-hop feature
  branches at once ("promote each zone", "promote the first zone", "promote
  issues 18, 93, 12", "promote all to-test"), honoring the first hop's merge
  strategy (direct → N merges; pr → one PR per group). Complements
  `queue-batches`, which now hands the batch off to it instead of prompting for
  serial `promoting-a-branch` runs.

### Changed
- **`queue-batches`** writes a per-run issue→zone manifest at dispatch (under a
  gitignored `.lightspeed/batches/`) so `promoting-branches` can honor "promote
  each zone", and its completion hand-off now points at `promoting-branches`.

## [0.4.0] - 2026-06-30

### Added
- `issues comments --number N` read verb on the dispatcher (Forgejo + GitHub) —
  fetches an issue's comments (`author⇥timestamp` header + body per comment), so
  discussion and decisions are no longer invisible to the normal issue lookup.
- `CHANGELOG.md` (this file).
- A **Credits** section in the README.
- `docs/plugin-marketplace-dogfooding.md` — how to publish vs. dogfood the plugin
  via a two-marketplace split.

### Changed
- `working-an-issue` now reads an issue **and its comments** when picking up work,
  so later clarifications/corrections in comments aren't missed ("later comment
  wins").

## [0.3.0] - 2026-06-28

### Changed
- **Config moved to a `.lightspeed/` folder** (hard cut): `config.json` and
  `secrets.json` now live under `.lightspeed/` instead of loose files. Consuming
  repos must move their config accordingly.

### Fixed
- Forgejo setup requests the correct token scopes (dropped the unneeded
  `write:misc`).

## [0.2.0]

### Added
- **GitHub backend adapter** — lightspeed now drives either Forgejo or GitHub
  through the same dispatcher/skill surface (full parity, including CI watch).

### Changed
- `bootstrapping-labels` renamed to **`setting-up-a-repo`** and broadened from
  label-seeding to full first-run repo setup (backend coordinates, stage
  pipeline, worker model, then labels).

## [0.1.0]

### Added
- Initial release. The curl/dispatcher architecture (no MCP server required) and
  the core workflow skills: `filing-issues`, `triaging-issues`,
  `working-an-issue`, `promoting-a-branch`, and `queue-batches` (parallel,
  zone-gated issue work). Forgejo backend.
