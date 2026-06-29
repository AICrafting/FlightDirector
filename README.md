# Cerebral Gardens — Claude Code plugins

A [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins).
Add it once, then install any plugin below.

```
/plugin marketplace add <this-repo> (eg: https://hostname/owner/repo.git [.git is required]) 
/plugin install lightspeed@cerebralgardens
```

## Plugins

| Plugin | What it does |
|---|---|
| [`lightspeed`](lightspeed/) | Opinionated issue + code workflow for a repo from a session — filing, triaging, and working issues through their lifecycle, plus label bootstrapping — over the backend's REST API (Forgejo today), no MCP server required. |

## Layout

```
.
├── .claude-plugin/marketplace.json   # lists every plugin in this repo
├── lightspeed/                       # one plugin (its own .claude-plugin/plugin.json)
│   ├── .claude-plugin/plugin.json
│   ├── references/
│   └── skills/
└── README.md
```

Each plugin lives in its own top-level directory and carries its own `plugin.json` with an
independent `version`, so plugins release on their own cadence — the marketplace just
indexes them. To add a new plugin: create its directory with a `.claude-plugin/plugin.json`,
then add an entry to `.claude-plugin/marketplace.json`.
