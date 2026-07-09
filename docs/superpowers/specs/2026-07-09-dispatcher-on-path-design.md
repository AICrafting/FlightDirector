# Dispatcher on PATH via `bin/` — design

**Issue:** #45 — Skills fail in real projects: `$CLAUDE_PLUGIN_ROOT` is unset in the Bash shell (exit 127).
**Date:** 2026-07-09

## Problem

Every lightspeed skill tells the model to invoke the dispatcher as
`"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed" <group> <verb> …` (and `…/scripts/batch-manifest …`).
In a real user project the Bash tool's shell has **no** `CLAUDE_PLUGIN_ROOT`, so the command expands
to `/scripts/lightspeed` and fails with exit 127. It only ever appeared to work where the variable
happened to be present.

### Root cause (authoritative)

Per Claude Code's plugin reference, `${CLAUDE_PLUGIN_ROOT}` is substituted/exported **only** to:
hook processes (`hooks/hooks.json`), MCP/LSP server subprocesses (`.mcp.json`/`.lsp.json`), and
monitor commands (`monitors/monitors.json`). It is **not** exported to the general Bash tool, and
Claude Code performs **no** text substitution of `${CLAUDE_PLUGIN_ROOT}` inside `SKILL.md` — the
literal string reaches the model. Confirmed empirically: `echo "$CLAUDE_PLUGIN_ROOT"` is empty in
the Bash tool, and env vars do not persist between Bash tool calls (only the cwd does).

Therefore relying on `$CLAUDE_PLUGIN_ROOT` from a skill's Bash command is an unsupported pattern.

## Approach

Adopt the officially-blessed mechanism: a plugin's **`bin/` directory is auto-added to the Bash
tool's `PATH`** while the plugin is enabled. (Verified: lightspeed's `bin/` and superpowers' `bin/`
are already on `PATH` in-session; lightspeed's is simply empty today.) Skills then call the tool as a
**bare command**, with no environment variable involved.

### Why this over the alternatives

Considered and rejected: a one-time `export` (dies — env doesn't persist between calls); a
self-healing cache file in `$HOME` (unwanted home-folder artifact); a repo-local cache resolved via
`git-common-dir` (extra machinery, per-repo artifact); a setup-time wrapper (migration for existing
repos, staleness on update); model-resolves-absolute-path (depends on the model reproducing the path
each call). The `bin/`-on-PATH approach beats all of them: **no env var, no cache, no `$HOME`
artifact, cwd/worktree-independent** (PATH is not cwd-based, so it works from `.worktrees/`), **no
setup migration**, and it is the documented convention other plugins use.

## Design

### 1. Ship `lightspeed/bin/` with two thin wrappers

`bin/lightspeed` and `bin/batch-manifest`, each an `exec` shim to the real script under `scripts/`:

```bash
#!/usr/bin/env bash
# bin/lightspeed — PATH entrypoint; delegates to the real dispatcher.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/../scripts/lightspeed" "$@"
```

(`bin/batch-manifest` is identical with `batch-manifest` substituted.)

**Why wrappers, not moving the scripts:** the dispatcher resolves its adapters relative to its own
location (`SELF_DIR="$(dirname "$0")"; ADAPTERS_DIR="$SELF_DIR/adapters"`). `exec`-ing the real
script preserves `$0` as `…/scripts/lightspeed`, so adapter resolution and the existing
`scripts/`+`adapters/` layout are untouched. Wrappers also keep the change additive.

**Executable bit:** the repo has `core.fileMode=false`, so `chmod +x` won't stick in git — set it
with `git update-index --chmod=+x lightspeed/bin/lightspeed lightspeed/bin/batch-manifest` so the
wrappers ship executable.

### 2. Rewrite every invocation to the bare command

- `"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"` → `lightspeed` (42 occurrences)
- `"$CLAUDE_PLUGIN_ROOT/scripts/batch-manifest"` → `batch-manifest` (4 occurrences)

Command substitution and flags are unaffected, e.g.
`BASE="$(lightspeed config '.code.stages[0].name')"`, `lightspeed issues list --state open`.

**Files (46 occurrences):**
- Skills (7): `working-an-issue` (9), `filing-issues` (9), `promoting-a-branch` (11),
  `promoting-branches` (4), `queue-batches` (5), `setting-up-a-repo` (3), `triaging-issues` (2).
  `queue-batches`/`promoting-branches` also carry the `batch-manifest` calls.
- Docs (3): `references/adapter-contract.md` (2 — the documented invocation contract),
  `references/lightspeed-setup.md` (1), `README.md` (1).

Historical material under `docs/…/plans/` and `docs/…/specs/` is left as-is (point-in-time record).

### 3. Documentation

Update `adapter-contract.md`'s "Invocation" section: skills call the dispatcher as a bare
`lightspeed <group> <verb>` command, available because the plugin's `bin/` is on `PATH`; drop the
`$CLAUDE_PLUGIN_ROOT` framing. Note the same for `batch-manifest`.

## Interfaces & boundaries

- **`bin/` wrappers** — sole responsibility: expose the entrypoints on `PATH`. Depend only on the
  sibling `scripts/` dir; no config/token knowledge. Adapters and `scripts/` are unchanged.
- **Skills** — now depend on a bare command being on `PATH` (a documented plugin guarantee) instead
  of an env var that was never guaranteed.

## Error handling

If the plugin is disabled/not installed, the bare command is simply not found — a clear
`command not found` rather than today's misleading `/scripts/lightspeed: no such file`. No new
failure modes.

## Testing / verification

The dev marketplace install is a **symlink** to the repo's `lightspeed/`, and its `bin/` path is
already on `PATH`, so a new `bin/` is picked up in-session without reinstall.

1. **Unit:** `bin/lightspeed config '.code.stages[0].name'` and `bin/batch-manifest --help` (or
   equivalent) succeed and behave identically to the `scripts/` versions.
2. **Bare command on PATH:** from the repo root, `command -v lightspeed` resolves to the `bin/`
   wrapper; `lightspeed issues list --state open` works with **no** `CLAUDE_PLUGIN_ROOT` set.
3. **Worktree-independence:** from inside a `.worktrees/<slug>/` cwd, the bare `lightspeed` command
   still works (PATH is not cwd-based).
4. **Real-project check (the actual bug):** in an unrelated project that has lightspeed configured,
   invoke a skill and confirm the dispatcher calls succeed as bare commands.
5. **Grep gate:** no remaining `CLAUDE_PLUGIN_ROOT` references in `lightspeed/skills/` or the three
   docs.

## Considerations / limitations

- **Global command namespace.** `lightspeed` and `batch-manifest` share the Bash `PATH` namespace;
  both names are distinctive enough that collision with a user's own tools is not a realistic
  concern. If it ever were, the wrappers could be renamed with a prefix without touching the
  `scripts/` layout.
- **Manifest.** No `plugin.json` change is required — `bin/` is auto-added to `PATH` by convention
  (confirmed: it was on `PATH` even while empty and undeclared).

## Out of scope

Renaming/relocating the `scripts/` dispatcher or adapters; changing the dispatcher's config/token
resolution; hooks or MCP delivery.
