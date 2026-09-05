# Cerebral Gardens — Claude Code plugins

A [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins).
Add it once, then install any plugin below.

```
/plugin marketplace add <this-repo> (eg: https://hostname/owner/repo.git [.git is required]) 
/plugin install flight@cerebralgardens
```

## Plugins

These are the **Flight Director** family of plugins (`flight` is the first; `launchpad`,
`preflight`, `mission-control`, `telemetry` and friends will follow). `flight` was previously
published as `lightspeed`.

| Plugin | What it does |
|---|---|
| [`flight`](flight/) | Opinionated issue + code workflow for a repo from a session — filing, triaging, and working issues through their lifecycle, plus label bootstrapping — over the backend's REST API (Forgejo today), no MCP server required. |

## Layout

```
.
├── .claude-plugin/marketplace.json   # lists every plugin in this repo
├── flight/                       # one plugin (its own .claude-plugin/plugin.json)
│   ├── .claude-plugin/plugin.json
│   ├── references/
│   └── skills/
└── README.md
```

Each plugin lives in its own top-level directory and carries its own `plugin.json` with an
independent `version`, so plugins release on their own cadence — the marketplace just
indexes them. To add a new plugin: create its directory with a `.claude-plugin/plugin.json`,
then add an entry to `.claude-plugin/marketplace.json`.

Working on the tools in this repo? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

- **Aaron Wood** — *The original ideast* 🤣
- **[Dave Wood](https://davewood.com/)** — *AI wrangler*
