# Flight GitHub test rig

Exercises the GitHub adapter against a **real** repo — the one named by `FLIGHT_GH_REPO` in
`.env` (a throwaway repo you own). **Dev tooling — not part of the plugin.** Requires `curl` +
`jq` and a token (scope: **repo + workflow**).

```bash
cp .env.example .env   # gitignored; fill in FLIGHT_GH_REPO=owner/repo and FLIGHT_GH_TOKEN
./up.sh        # verify token, seed labels + ci workflow, write .work/ config
./smoke.sh     # exercise every verb against the live repo (marker-tagged), with assertions
./down.sh      # close/delete only rig-tagged artifacts; remove .work/
```

- **Workdir:** `.work/` — gitignored; holds `.flightdirector/config.json` + `.flightdirector/secrets.json` (token).
- **Markers:** rig artifacts carry a `[rig]` title prefix and the `rig` label. `down.sh` only
  touches those. GitHub REST can't delete issues — rig issues are **closed**, not removed.
- The rig only writes to `rig/*` branches and PRs between them; it never writes to `main`.
- **`ci log` on a red pull request (#138):** the last smoke section opens a second PR whose head
  branch carries `workflows/rig-pr-red.yml` + `workflows/rig-pr-green.yml` — a job that fails while a `rig-fail` file exists and one that always
  passes, so one commit holds a red and a green run that started together, under the PR ref
  rather than the branch. It asserts `ci watch --pr` ends at `status=failure`; that `ci log --pr`,
  `--sha` and `--failed <branch>` each show the red job's log and not the green one's; and, after
  `rig-fail` is removed, that the new head watches green and `ci log --pr` says
  `(no failed jobs …)`. Adds a few minutes of real CI time. If CI never reaches a verdict the
  section warns and skips its checks rather than failing.
