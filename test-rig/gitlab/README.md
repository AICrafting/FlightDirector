# flight GitLab test rig

Exercises the GitLab adapter against a **real** project (`cerebralgardens/lightspeed-test`).
**Dev tooling — not part of the plugin.** Requires `curl` + `jq` and a personal/project access
token (scope: **api**).

```bash
# put creds in test-rig/gitlab/.env (gitignored):
#   FLIGHT_GITLAB_TOKEN=glpat-…
#   FLIGHT_GITLAB_API=https://gitlab.com/api/v4
#   FLIGHT_GITLAB_PROJECT=group/project
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
