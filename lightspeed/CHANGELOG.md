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

### Added
- **`code.ciWatchTimeout`** config field sets the `ci watch` hang-guard timeout
  in seconds (default `900`; `0` disables). Precedence: `--timeout` flag →
  `LS_CI_WATCH_TIMEOUT` env → `code.ciWatchTimeout` → default.

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
