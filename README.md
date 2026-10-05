# Flight Director — Claude Code + Codex plugins

**AI Crafting**'s plugin marketplace for **Claude Code** and **Codex** (marketplace name
`flightdirector`, hosted at <https://github.com/AICrafting/FlightDirector>). Add it once, then
install any plugin below.

**Claude Code**

```
/plugin marketplace add https://github.com/AICrafting/FlightDirector.git
/plugin install flight@flightdirector
```

(`/plugin marketplace add AICrafting/FlightDirector` — the GitHub shorthand — works too.)

**Codex**

```
codex plugin marketplace add https://github.com/AICrafting/FlightDirector.git
codex plugin add flight@flightdirector
```

Or open `/plugins` inside Codex, pick the `flightdirector` tab and install *Flight* there. Start
a new session afterwards — bundled skills load at session start.

## Plugins

These are the **Flight Director** family of plugins (`flight` is the first; `launchpad`,
`mission-control`, `telemetry` and friends will follow). `flight` was previously
called `lightspeed` during initial development/testing.

| Plugin | What it does |
|---|---|
| [`flight`](flight/) | Opinionated issue + code workflow for a repo from a session — filing, triaging, and working issues through their lifecycle, plus label bootstrapping — over the forge's REST API (Forgejo/Gitea, GitHub, GitLab; Jira for issues), no MCP server required. |

## Flight at a glance

Flight runs your whole issue-and-code loop — **file → triage → work → promote** — from inside the
agent session, without tabbing over to the forge's web UI. The full story, with install steps and
a worked example, is in the **[Flight User Guide](flight/GUIDE.md)**; here is what it gives you:

- **Issues filed from the conversation, de-duplicated and labeled.** `/issue the export button
  stays clickable mid-download` becomes a real issue drafted from what was discussed, after a
  scan of the open issues for near-duplicates.
  → [File it](flight/GUIDE.md#1-file-it)
- **A pick-list of what is genuinely workable.** "What should I work on?" filters out anything
  already in progress, in review, or in QA. → [Decide what to do next](flight/GUIDE.md#2-decide-what-to-do-next)
- **One branch, one worktree, per issue.** Each issue is worked on `feature/<ref>-<N>-<slug>`
  (e.g. `feature/fj-42-export-button`) in its own `.worktrees/<ref>-<N>-<slug>`, so several can
  be in flight without stashing, and the issue's status label flips at every transition so the
  board never lies.
  → [Work it](flight/GUIDE.md#3-work-it)
- **A human merge gate.** Work stops at *ready to test*; nothing merges until you say "promote".
  When you do, a work-ledger comment (summary, token cost, model) lands on the issue first.
  Name your repo's check command in `code.preflight` and every promotion runs it before merging,
  so a red suite stops the merge even on a hop with no CI.
  → [Work it](flight/GUIDE.md#3-work-it) · [The preflight gate](flight/GUIDE.md#4-promote-toward-release)
- **A promotion pipeline that matches how you ship.** Declare your stages once —
  `feature → develop → qa → main` or just `main` — and the same "promote" advances a branch one
  hop: direct-merge where you want speed, PR + test plan + CI watch where you want a gate. Issue
  status and close follow the stage. → [Promote toward release](flight/GUIDE.md#4-promote-toward-release)
  · [example pipelines at 1–4 hops](flight/references/example-flows.md)
- **Parallel work by zone.** `/queue-batches NxM` dispatches N background agents each working
  M issues sequentially in isolated worktrees, all stopping at the gate; ship the batch in one
  go with `promoting-branches`. → [The workflow at a glance](flight/GUIDE.md#the-workflow-at-a-glance)
- **Any backend, no MCP server.** Skills call one dispatcher (`flight <group> <verb>`); it reads
  `.flightdirector/config.json`, resolves the target (`code` for PRs/CI, or one of the repo's
  named issue trackers — the same repo, another repo or backend, a Jira project — for issues),
  and execs a pure `curl` + `jq` adapter for that backend. Forgejo/Gitea, GitHub, and GitLab at
  full parity; Jira as an issue tracker. A private backlog and a public intake can sit side by
  side: each tracker has a short ref (`FJ-12`, `GH-7`) and one is the default, set up with the
  `add-an-issue-tracker` skill. Your only secrets are per-repo, least-privilege tokens, and
  per-machine differences live in a gitignored
  `config.local.json` layered over the committed config. Everything flight writes to the tracker
  is signed `🤖 via FlightDirector:flight@<version> with <Model/ver>`, so provenance is on the
  record. Runs on Linux, stock macOS, and Windows (Git Bash), all three CI-tested on every change.
  → [backends.md](flight/references/backends.md) · [adapter-contract.md](flight/references/adapter-contract.md)
  · [ADR 0001: why curl over MCP](docs/adr/0001-curl-over-mcp-and-adapter-architecture.md)
- **Same skills in Claude Code and Codex.** One package, two harnesses; natural-language triggers
  in both. → [Install](flight/GUIDE.md#install-in-claude-code) · [First-time setup](flight/GUIDE.md#first-time-setup-once-per-repo)

Reference material — config schema, stage semantics, the label taxonomy, and every dispatcher
verb — lives under [`flight/references/`](flight/references/), starting with
[flight-setup.md](flight/references/flight-setup.md).

## Layout

```
.
├── .claude-plugin/marketplace.json   # marketplace manifest — lists every plugin (read by Claude Code AND Codex)
├── flight/                           # one plugin
│   ├── .claude-plugin/plugin.json    # Claude Code manifest (version source of truth)
│   ├── .codex-plugin/plugin.json     # Codex manifest (kept in lockstep by scripts/bump-version.sh)
│   ├── commands/                     # Claude Code slash commands (`/flight:version`)
│   ├── bin/                          # entrypoints: `flight` (dispatcher), `batch-manifest`, deprecated `lightspeed` shim
│   ├── scripts/                      # dispatcher + adapters/<backend>/ (forgejo, github, gitlab, jira)
│   ├── skills/                       # the skills, shared by both harnesses
│   ├── references/                   # setup, adapter contract, backends, labels
│   └── GUIDE.md · README.md · CHANGELOG.md
├── scripts/                          # repo tooling: bump-version.sh, run-tests.sh, run-checks.sh, checks/, tests/
├── test-rig/                         # live adapter rigs per backend (dev tooling, not shipped)
├── docs/                             # ADRs, dogfooding notes
├── AGENTS.md · CLAUDE.md             # agent instructions (CLAUDE.md imports AGENTS.md)
└── README.md
```

Each plugin lives in its own top-level directory and carries its own `plugin.json` with an
independent `version`, so plugins release on their own cadence — the marketplace just
indexes them. To add a new plugin: create its directory with **both** a
`.claude-plugin/plugin.json` and a `.codex-plugin/plugin.json` (same `name`/`version`;
`scripts/bump-version.sh` keeps them in lockstep), then add an entry to
`.claude-plugin/marketplace.json` — Codex reads that same marketplace file, so no
`.agents/plugins/marketplace.json` is needed.

Working on the tools in this repo? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

FlightDirector generalizes the agent toolchain Aaron built and ran against
[Darkwatch](https://github.com/SilicaGel/darkwatch-toolchain) over five months, with the
project-specific wiring taken out and the design kept. It's being built out here by both
of us.

- **[Aaron Wood](https://aaronwood.dev/)** — original toolchain and design
- **[Dave Wood](https://davewood.com/)** — turned it into a plugin: backends, pipeline, and
  the release machinery
