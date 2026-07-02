# Plugin marketplaces: publishing + dogfooding the live tree

How Claude Code plugin marketplaces actually resolve, and the two-marketplace
split we use so that **published consumers** (other repos, real users) and
**local dogfooding** (editing the plugin in this repo) never cross.

Written while untangling `lightspeed`. Applies to the **second plugin** too —
same mechanics, same setup.

---

## The problem this solves

A marketplace registered from a **`directory` source** points at your *live
working tree*. If you register `cerebralgardens` that way and then another repo
(e.g. `other_project`) "adds the marketplace like a normal user," it does **not**
get the published plugin — it reaches straight into your dev checkout. Your
uncommitted edits leak into that repo. That's the crossing.

The fix is **two marketplaces with different names**, split by source:

| Marketplace | Source | Resolves to | Enabled in |
|---|---|---|---|
| `cerebralgardens` | **git** (forgejo URL) | published `develop` snapshot | other repos + real users |
| `cerebralgardens-dev` | **directory** (+ symlink to live tree) | your live `lightspeed/` tree | this repo (dogfood) |

---

## Hard facts about the CLI (verified, not guessed)

These drove every design decision. Re-verify with `--help` if a CC version changes.

> **Paths below are relative to `$CLAUDE_CONFIG_DIR`, not a hardcoded `~/.claude`.** Claude Code's
> config home is **profile-specific**: it defaults to `~/.claude`, but the `claude` CLI honours the
> `CLAUDE_CONFIG_DIR` env var, so a machine running multiple profiles (e.g. a personal
> `~/.claude-dave` and a work `~/.claude-work`) keeps a separate registry/cache under each. Under a
> non-default profile, `~/.claude/plugins/…` is empty/misleading — the real files live under
> `$CLAUDE_CONFIG_DIR/plugins/…`. Everywhere this doc writes `$CLAUDE_CONFIG_DIR`, substitute your
> active profile dir. In scripts, default it safely with `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` (use
> `$HOME`, not `~` — a tilde doesn't expand inside a quoted parameter default). Commands that shell
> out to `claude` inherit `CLAUDE_CONFIG_DIR` and hit the right profile automatically.

1. **`marketplace add` takes a single `<source>` argument.** The marketplace
   **name comes from the manifest's `name` field**, NOT the CLI. There is **no
   `--name` flag**.
   - ✅ `claude plugin marketplace add https://codeberg.org/cerebralgardens/claude-tools.git`
   - ❌ `claude plugin marketplace add cerebralgardens https://…`  ← the extra
     `cerebralgardens` is swallowed as the *source* (a nonexistent local path),
     the URL is ignored, and **it fails silently** (no output, registry
     unchanged). This is the exact trap that cost an hour.

2. **No version pinning anywhere.** `install` has only `--config` and `--scope`
   (no `--version`, no `plugin@marketplace@version`). `marketplace add` has only
   `--scope` and `--sparse` (no `--ref`/`--branch`/`--tag`). A plugin install
   takes whatever version the manifest *currently* advertises; `marketplace
   update` re-pulls the source's latest. To freeze a consumer at a known-good
   point, pin the **git source ref** (tag/branch on the repo), not a plugin
   version.

3. **Marketplace registration is user-global; *enablement* is per-project.**
   Registry lives in `$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json`. Which plugins
   a project enables lives in that project's `.claude/settings.local.json`
   (`enabledPlugins`). Two marketplaces with the **same manifest name collide** —
   `--scope` only picks which settings file declares it, the name still clashes.
   Hence the two must have **different names**.

4. **Plugin `source` in a marketplace manifest** accepts **only a `./`-relative
   path inside the marketplace root**. Not absolute paths, not `..` traversal,
   not an object form. That's why the dev marketplace uses a **symlink** named
   `lightspeed` pointing at the live tree, with `"source": "./lightspeed"`.

5. **`plugin install` snapshots a COPY into a version-keyed cache** at
   `$CLAUDE_CONFIG_DIR/plugins/cache/<marketplace>/<plugin>/<version>/` (real files,
   different inodes from the live tree). The running plugin reads that cache, **not**
   the symlink. So even with the dev symlink, **live edits are NOT automatically
   picked up** — see refresh recipe below.

6. **`plugin update` is version-gated and defaults to `--scope user`.**
   - If the manifest version is unchanged it reports "already at the latest
     version" and does **not** re-copy — so editing skill files (which doesn't
     bump the version) is invisible to `update`.
   - It defaults to scope `user`; a `--scope local` install needs
     `plugin update … --scope local` or you get
     `Plugin "…" is not installed at scope user`.
   - **`plugin uninstall` has the same default** — it too assumes `--scope user`,
     so uninstalling a local-scope install needs `plugin uninstall … --scope local`
     or it errors with the same "not installed at scope user" message.
   - **Bumping the manifest version did NOT reliably force a re-snapshot either**
     (tested). The only thing that reliably works is deleting the cache dir.

---

## One-time setup

### 1. Published marketplace (git source)

```bash
# If a directory-source entry of the same name exists, remove it first:
claude plugin marketplace remove cerebralgardens
# Single-arg form — name comes from the manifest:
claude plugin marketplace add https://codeberg.org/cerebralgardens/claude-tools.git
```

### 2. Dev marketplace (directory + symlink)

```bash
DEVMP=~/.claude-marketplaces/cerebralgardens-dev
mkdir -p "$DEVMP/.claude-plugin"
# symlink makes "./lightspeed" resolve to the live tree:
ln -sfn /path/to/ClaudeSkills/lightspeed "$DEVMP/lightspeed"

cat > "$DEVMP/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "cerebralgardens-dev",
  "owner": { "name": "Cerebral Gardens", "email": "dave@cerebralgardens.com" },
  "metadata": { "description": "LOCAL DEV checkout of Cerebral Gardens' plugins (dogfooding the live tree)." },
  "plugins": [
    { "name": "lightspeed", "source": "./lightspeed", "version": "0.3.0", "description": "Live-tree lightspeed for dogfooding." }
  ]
}
JSON

claude plugin validate "$DEVMP"                 # expect: ✔ Validation passed
claude plugin marketplace add "$DEVMP"          # single arg again
```

### 3. Enable the right one per repo

```bash
# THIS repo (dogfood) — run from the repo root:
claude plugin install lightspeed@cerebralgardens-dev --scope local

# A consuming repo (e.g. other_project) — run from that repo:
claude plugin install lightspeed@cerebralgardens --scope local
```

### 4. Verify + reload

```bash
claude plugin marketplace list   # claude-plugins-official + cerebralgardens + cerebralgardens-dev
claude plugin list               # this repo: lightspeed@cerebralgardens-dev (enabled)
```
Then `/reload-plugins` (or restart the session) — `list` shows stale
enabled/disabled state until you reload.

---

## Dogfood refresh cycle (THE important part)

After editing skill/plugin files in this repo, the loaded plugin is the **cached
copy** and is stale. Neither `/reload-plugins` alone nor `plugin update` picks up
the edits (see fact #5/#6). The **reliable** refresh is to delete the
version-keyed cache dir and reinstall:

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # your profile dir; defaults to ~/.claude when unset
VER=0.6.0                                   # = the version in the dev manifest (keep in sync when it bumps)
rm -rf "$CFG/plugins/cache/cerebralgardens-dev/lightspeed/$VER"
claude plugin uninstall lightspeed@cerebralgardens-dev --scope local
claude plugin install   lightspeed@cerebralgardens-dev --scope local
# then:
/reload-plugins      # or restart the session
```

Tested matrix (live edit → did it reach the cache?):

| Refresh attempt | Result |
|---|---|
| `/reload-plugins` only | ✗ reads stale cache |
| `marketplace update` + `plugin update --scope local` | ✗ "already at latest version" |
| `uninstall` + `install` (cache dir left in place) | ✗ reuses existing cache |
| bump manifest version + reinstall | ✗ (did not re-snapshot reliably) |
| **`rm -rf` the version cache dir + reinstall** | **✔ propagates** |

> If this churn gets annoying for a second plugin, wrap it in a tiny
> `scripts/refresh-dev-plugin.sh` that takes the marketplace/plugin/version.

---

## Gotchas / don't-break list

- **The `disabled` line in `plugin list` may belong to another repo.**
  `installed_plugins.json` is global; `plugin list` shows all local-scope
  installs and marks them enabled/disabled relative to the *current* project. An
  entry like `lightspeed@cerebralgardens (local) ✘ disabled` here is
  other_project's legitimate install (its record carries
  `projectPath: …/other_project`). **Do not delete it** — it's not stale cruft for
  this repo, and removing it breaks `other_project`.
- **Keep `$DEVMP/lightspeed` a symlink.** Replace it with a copy and the dev
  marketplace freezes.
- **Don't register the published plugin as a `directory` source.** That's the
  original leak. Published = git source only.
- Marketplaces are global, enablement is per-project: enabling here never
  affects another repo, and vice versa.

---

## Reusing this for the second plugin

1. Put the plugin folder in this repo (alongside `lightspeed/`), with its own
   `.claude-plugin/plugin.json`. It ships from the **same published marketplace**
   (`cerebralgardens`) — just add it to the published `marketplace.json`'s
   `plugins` array.
2. Add a matching entry + symlink to `cerebralgardens-dev` so you can dogfood it
   here:
   ```bash
   ln -sfn /…/ClaudeSkills/<plugin2> ~/.claude-marketplaces/cerebralgardens-dev/<plugin2>
   # add { "name": "<plugin2>", "source": "./<plugin2>", "version": "…" } to the dev manifest
   claude plugin marketplace update cerebralgardens-dev
   claude plugin install <plugin2>@cerebralgardens-dev --scope local
   ```
3. Everything above (single-arg `add`, version-keyed cache, the `rm -rf` refresh)
   applies identically.
