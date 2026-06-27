# Cerebral Gardens — Claude Code plugins

A [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins).
Add it once, then install any plugin below.

```
/plugin marketplace add <this-repo>
/plugin install lightspeed@cerebralgardens
```

## Plugins

| Plugin | What it does |
|---|---|
| [`lightspeed`](lightspeed/) | Opinionated workflows for a Forgejo repo from a session — filing, triaging, and working issues through their lifecycle, plus label bootstrapping — via the forgejo MCP server. |

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
