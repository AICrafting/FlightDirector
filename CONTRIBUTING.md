# Contributing

Notes for people working **on** the tools in this repo. If you just want to *use*
flight in your own repo, that's [`flight/GUIDE.md`](flight/GUIDE.md) —
nothing here (bumping versions, adapters, the test rigs) is something a plugin
*user* ever does.

Rule of thumb for where a doc belongs: *"would someone who only installed the
plugin ever do this?"* If no, it goes here; if yes, it goes in `GUIDE.md`.

## Repo layout

This is a monorepo of Claude Code tools. Each tool owns its own directory and its
own docs/changelog; shared tooling lives at the root.

```
.
├── flight/                  # the flight plugin
│   ├── .claude-plugin/plugin.json
│   ├── GUIDE.md                 # user-facing guide
│   ├── README.md
│   ├── CHANGELOG.md             # this plugin's changelog
│   ├── skills/                  # the skills (filing-issues, working-an-issue, …)
│   ├── scripts/
│   │   ├── flight           # the dispatcher (single entrypoint)
│   │   └── adapters/<backend>/  # per-backend adapters (forgejo, github, …)
│   └── references/              # adapter-contract.md, flight-setup.md, default-labels.md
├── .claude-plugin/marketplace.json   # published marketplace manifest (all plugins)
├── scripts/                     # repo-wide tooling (checks, tests, release)
├── test-rig/                    # per-backend integration rigs
├── docs/                        # repo docs + docs/adr/ (architecture decision records)
├── CHANGELOG.md                 # root index → each tool's changelog
├── CONTRIBUTING.md              # this file
└── README.md
```

A **second tool** would slot in as a sibling of `flight/` (its own dir with a
`plugin.json`), gain an entry in `.claude-plugin/marketplace.json`, its own
`CHANGELOG.md`, and a line in the root `CHANGELOG.md` index.

## Dev setup / dogfooding

This repo dogfoods flight on itself via a **two-marketplace split** (a published
git-source marketplace and a local directory-source one symlinked to the live tree).
The full setup, the refresh cycle after you change the plugin, and the gotchas are in
**[docs/plugin-marketplace-dogfooding.md](docs/plugin-marketplace-dogfooding.md)**.
Read that before your first change — the CLI has no version pinning, so knowing how
the cache refreshes matters.

## Running the checks and tests

There are three distinct layers — keep them straight:

| What | Where | Runs | Purpose |
|---|---|---|---|
| **Pre-push checks** | `scripts/checks/*.sh` via `scripts/runChecks.sh` | `.githooks/pre-push` (local), on demand | Working-tree cleanliness: `lint.sh` (yamllint + shellcheck), `verifyGitLogs.sh` (commit signatures) |
| **Script unit tests** | `scripts/tests/*.test.sh` via `scripts/runTests.sh` | CI (`.forgejo/workflows/tests.yml`), on demand | Unit tests for the repo's own scripts (e.g. `bump-version.test.sh`) |
| **Integration rigs** | `test-rig/<backend>/` | on demand | Per-backend adapter smoke tests (see below) |

```bash
scripts/runChecks.sh    # lint + signature checks (what the pre-push hook runs)
scripts/runTests.sh     # all scripts/tests/*.test.sh
```

Enable the pre-push hook once per clone:

```bash
git config core.hooksPath .githooks
```

CI runs two workflows on push to `develop` and on PRs: **`lint`** (yamllint +
shellcheck) and **`tests`** (`runTests.sh`).

**Adding a check or test.** A pre-push check is any `*.sh` in `scripts/checks/`
(`runChecks.sh` runs each that is executable). A unit test is any `*.test.sh` in
`scripts/tests/` (`runTests.sh` runs each). Keep unit tests out of `scripts/checks/`
— the pre-push path is for cleanliness, not for testing individual scripts.

**Executable bit — important.** This repo has `core.fileMode = false`, so a plain
`chmod +x` is **not** recorded by git; a fresh clone would get a `644` file and
directly-run scripts (and the pre-push hook) would break. Commit the bit explicitly:

```bash
git update-index --chmod=+x scripts/your-new-script.sh
git ls-files -s scripts/your-new-script.sh   # verify it shows 100755
```

## Adapter development

All backend access goes through the **dispatcher** (`flight/scripts/flight`)
— never raw API calls or MCP. It routes `<group> <verb>` to a per-backend adapter and
resolves coordinates/tokens from `.flightdirector/config.json`.

```
flight/scripts/adapters/<backend>/
  _common.sh    # shared helpers for the backend
  issues        # the four groups, one executable each
  labels
  pr
  ci
```

The contract every adapter implements — the groups, verbs, arguments, and output/exit
conventions — is
**[flight/references/adapter-contract.md](flight/references/adapter-contract.md)**.
Adding a backend means adding `adapters/<backend>/{issues,labels,pr,ci}` (an
issues-axis-only backend implements just `issues` + `labels`); the dispatcher picks it
up by name with no dispatcher changes.

Prove parity with a **rig** under `test-rig/<backend>/`: `up.sh` provisions a throwaway
target (a disposable container for self-hostable backends, an ephemeral repo/token for
SaaS ones) leaving a gitignored `.work/`; `smoke.sh` runs the adapter verbs against it;
`down.sh` tears it down. See [test-rig/README.md](test-rig/README.md). Open backend
work: GitLab (#12) and Jira (#13).

## Branch / PR conventions

flight develops itself through its own pipeline: **feature → develop → qa → main**
(`code.stages` in `.flightdirector/config.json`). Use the skills:

- **`working-an-issue`** — one branch + worktree per issue under `.worktrees/`, status
  labels that track the board, an explicit human merge gate.
- **`promoting-a-branch`** — advances a branch one hop, applying that hop's merge
  strategy and gate; the `feature → develop` hop is a direct `--no-ff` merge.

Other conventions:

- **Signed commits are required.** The pre-push `verifyGitLogs.sh` rejects any unpushed
  commit whose signature isn't good (`%G?` of `G`/`U`). Merge commits occasionally sign
  badly (`B`) — re-sign with `git commit --amend --no-edit -S` before pushing.
- **Commit trailers** — see [CLAUDE.md](CLAUDE.md) for the required `Co-Authored-By` /
  session trailers.
- **Code style** — tabs (width 4); trailing whitespace trimmed on save (except `.md`);
  leave one final newline. See [CLAUDE.md](CLAUDE.md).

## Cutting a release

When you bump a plugin's version, three things must move together and its changelog
needs rolling. `scripts/bump-version.sh` does the in-repo mechanical part in one pass —
it takes the **plugin name**, so it works for any plugin in this repo:

```bash
scripts/bump-version.sh flight 0.5.0
```

It resolves the plugin's directory from its `source` in `.claude-plugin/marketplace.json`,
then:

- updates the version in **`<plugin>/.claude-plugin/plugin.json`** and that plugin's
  entry in the published **`.claude-plugin/marketplace.json`** (only that entry — other
  plugins are left alone);
- rolls **`<plugin>/CHANGELOG.md`**: the top `## [Unreleased]` becomes
  `## [0.5.0] - <today>`, with a fresh empty `## [Unreleased]` seeded above it. It warns
  (but doesn't stop) if `[Unreleased]` was empty when you rolled it.

The **dev-marketplace cache refresh** stays a manual step — it lives outside the repo;
see [docs/plugin-marketplace-dogfooding.md](docs/plugin-marketplace-dogfooding.md).

## Writing skills

The skills under `flight/skills/` follow the superpowers **`writing-skills`**
conventions (a skill is a directory with a `SKILL.md` plus any `references/` or
`templates/`). Invoke that skill when creating or editing a skill, and mirror the voice
and structure of the existing skills (red-flags section, numbered lifecycle,
common-mistakes table).
