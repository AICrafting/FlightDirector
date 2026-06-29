# `.lightspeed/` config-folder reorg — design

Move lightspeed's per-repo config files out of the repo root and into a single `.lightspeed/`
folder, to cut root-level noise in target repos. **Hard cut** — no fallback to the old root paths.

## Decisions (locked during brainstorming)

1. **Folder layout** (drop the redundant `lightspeed` prefix — the folder namespaces it):
   ```
   .lightspeed/
     config.json      ← was .lightspeed.json          (committed)
     secrets.json     ← was .lightspeed.secrets.json   (gitignored)
     agent-rules.md   ← was .lightspeed-agent-rules.md (committed, optional; queue-batches)
   ```
2. **Hard cut.** The dispatcher reads only the new paths; no dual-path/back-compat shim.
3. **`.worktrees/` stays at the repo root** — it's git plumbing, not config; out of scope.
4. **No migration tooling.** The one existing target repo has already been moved by hand; the
   change ships as code/doc updates only.

## Architecture

The dispatcher's resolution model is unchanged: it still resolves config at the **main repo root**
(parent of `git rev-parse --git-common-dir`, so a linked worktree resolves to the main checkout),
picks the axis, applies `code → issues` inheritance, and exports the same `LS_*` environment to the
adapters. Only the two file *paths* change (root files → files inside `.lightspeed/`). Adapters are
untouched (they never read config). Skills that write or name the files are updated.

## Components / changes

### 1. Dispatcher — `lightspeed/scripts/lightspeed`
- `cfg="$repo_root/.lightspeed/config.json"`, `sec="$repo_root/.lightspeed/secrets.json"`.
- The tracked-secrets git warning checks `.lightspeed/secrets.json`
  (`git -C "$repo_root" ls-files --error-unmatch .lightspeed/secrets.json`).
- Error/usage strings updated: `no .lightspeed/config.json at repo root (…)`, and
  `set code.backend … in .lightspeed/config.json`.
- The header comment referencing the secrets filename updated.
- **No other behavior change**: `config` passthrough, axis resolution, token precedence
  (`LS_TOKEN`/`FORGEJO_TOKEN` env → secrets file), and `LS_*` exports are identical. The `config`
  group now reads `.lightspeed/config.json`.

### 2. `setting-up-a-repo` skill
- Step 1/2/4: `mkdir -p .lightspeed`, then write `config.json` + `secrets.json` inside it.
- The gitignore step adds **`.lightspeed/secrets.json`** (and `.worktrees/`, as today), created
  **before** the secret is written.
- All prose references to the old filenames updated to the new paths.

### 3. `queue-batches` skill
- Default for `code.queueBatches.agentRulesFile` becomes **`.lightspeed/agent-rules.md`**
  (the config-key name is unchanged; only the default path moves). Dispatch-step resolution line
  and the config-schema docs updated.

### 4. Test rigs (forgejo + github)
- `up.sh`: `mkdir -p "$WORK/.lightspeed"`, write `"$WORK/.lightspeed/config.json"` +
  `"$WORK/.lightspeed/secrets.json"`.
- `smoke.sh` (both), `down.sh` (github), `smoke-worktree.sh` (forgejo): read the new paths.
- Rig `README.md`s and `up.sh` header comments updated.
- The rigs `git init` `.work/`, so `.work/.lightspeed/config.json` resolves exactly as in a real
  repo — this is also the end-to-end verification path.

### 5. Reference docs
- `lightspeed/references/lightspeed-setup.md`: the `### .lightspeed.json` / `### .lightspeed.secrets.json`
  section headings + bodies, and the GitHub config example, become `.lightspeed/config.json` /
  `.lightspeed/secrets.json`.
- `lightspeed/references/adapter-contract.md`: the "Reads `.lightspeed.json` / `.lightspeed.secrets.json`"
  line.
- `lightspeed/GUIDE.md` and `lightspeed/README.md`: all references.
- Passing mentions in `filing-issues`, `triaging-issues`, `promoting-a-branch`, `working-an-issue`.

### 6. Plugin repo `.gitignore`
- Update the explicit `.lightspeed.secrets.json` line to `.lightspeed/secrets.json` for
  consistency. (This repo is the plugin source, not a target, so the line is only defensive; the
  `secret*` pattern already incidentally matches `secrets.json`. Update it anyway for clarity.)

## Error handling

Unchanged semantics: a missing `.lightspeed/config.json` is a hard `die` with a clear path in the
message; a tracked `.lightspeed/secrets.json` triggers the loud every-run warning (does not refuse).
The only difference is the paths named in those messages.

## Testing / verification

No unit framework — the established pattern:
- `shellcheck -x` clean on the dispatcher + all rig scripts.
- Offline dispatcher checks against a temp repo with the new layout: `lightspeed config '<jq>'`
  reads `.lightspeed/config.json`; the missing-config `die` names the new path; the tracked-secrets
  warning fires on a committed `.lightspeed/secrets.json`; a worktree resolves config from the main
  root's `.lightspeed/`.
- Live rig smoke (forgejo 13/13, github 15/15) proving the new paths resolve end-to-end.

## Out of scope

- Moving `.worktrees/`.
- Any dual-path / backward-compatibility shim.
- Automated migration of existing repos (the one existing target is already moved).
- `setting-up-a-repo` GitHub-backend support and other pending items (tracked separately).
