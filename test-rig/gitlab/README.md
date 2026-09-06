# Flight GitLab test rig

Exercises the GitLab adapter against a **real** project — the one named by `FLIGHT_GITLAB_PROJECT` in `.env`.
**Dev tooling — not part of the plugin.** Requires `curl` + `jq` and a personal/project access
token (scope: **api**), or a fine-grained personal access token with the per-resource permissions
listed under *GitLab* in [`flight/references/backends.md`](../../flight/references/backends.md).

```bash
cp .env.example .env   # gitignored; fill in FLIGHT_GITLAB_TOKEN / _API / _PROJECT
./up.sh        # verify token, seed labels + .gitlab-ci.yml, write .work/ config
./smoke.sh     # exercise every verb against the live project (marker-tagged), with assertions
./down.sh      # close/delete only rig-tagged artifacts; remove .work/
```

- **Worktree-safe:** `up.sh`/`down.sh`/`smoke.sh` resolve `.env` from the **main** repo root
  (`git rev-parse --git-common-dir`) so they work from a linked worktree where the gitignored
  `.env` doesn't exist, falling back to `$RIG_DIR/.env`.
- **Workdir:** `.work/` — gitignored; holds `.flightdirector/config.json` + `.flightdirector/secrets.json` (token).
- **Markers:** rig artifacts carry a `[rig]` title prefix and the `rig` label. `down.sh` only
  touches those. GitLab REST can't delete issues — rig issues are **closed**, not removed.
- The rig only writes to `rig/*` branches and MRs between them; it never writes to the default branch.
- **CI note:** pipelines need an available runner. On gitlab.com, shared-runner minutes may be
  gated per account/project; if none run, `ci watch` in the smoke suite reports a soft warning
  (it correctly times out non-zero rather than hanging).
