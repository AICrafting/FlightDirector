# Contributing

Notes for people working **on** the plugins in this repo (not for people *using*
lightspeed in their own repo — that's [`lightspeed/GUIDE.md`](lightspeed/GUIDE.md)).

> This file is intentionally minimal for now. More to come — dev setup, running
> the checks, adapter development, the test rigs, and branch/PR conventions.

## Cutting a release

When you bump a plugin's version, three things must move together and its changelog
needs rolling. `scripts/bump-version.sh` does the in-repo mechanical part in one pass
— it takes the **plugin name**, so it works for any plugin in this repo:

```bash
scripts/bump-version.sh lightspeed 0.5.0
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
