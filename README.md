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
`preflight`, `mission-control`, `telemetry` and friends will follow). `flight` was previously
called `lightspeed` during initial development/testing.

| Plugin | What it does |
|---|---|
| [`flight`](flight/) | Opinionated issue + code workflow for a repo from a session — filing, triaging, and working issues through their lifecycle, plus label bootstrapping — over the backend's REST API (Forgejo today), no MCP server required. |

## Layout

```
.
├── .claude-plugin/marketplace.json   # marketplace manifest — lists every plugin (read by Claude Code AND Codex)
├── flight/                           # one plugin
│   ├── .claude-plugin/plugin.json    # Claude Code manifest (version source of truth)
│   ├── .codex-plugin/plugin.json     # Codex manifest (kept in lockstep by scripts/bump-version.sh)
│   ├── bin/                          # entrypoints: `flight` (dispatcher), `batch-manifest`, deprecated `lightspeed` shim
│   ├── scripts/                      # dispatcher + adapters/<backend>/ (forgejo, github, gitlab, jira)
│   ├── skills/                       # the skills, shared by both harnesses
│   ├── references/                   # setup, adapter contract, backends, labels
│   └── GUIDE.md · README.md · CHANGELOG.md
├── scripts/                          # repo tooling: bump-version.sh, runTests.sh, runChecks.sh, checks/, tests/
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

- **Aaron Wood** — *The original ideast* 🤣
- **[Dave Wood](https://davewood.com/)** — *AI wrangler*
