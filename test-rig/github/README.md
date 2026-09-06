# Flight GitHub test rig

Exercises the GitHub adapter against a **real** repo (`DaveWoodCom/FlightTestTarget`).
**Dev tooling — not part of the plugin.** Requires `curl` + `jq` and a token (scope: **repo +
workflow**).

```bash
export FLIGHT_GH_TOKEN=ghp_…   # or: cp .env.example .env (gitignored) and fill it in
./up.sh        # verify token, seed labels + ci workflow, write .work/ config
./smoke.sh     # exercise every verb against the live repo (marker-tagged), with assertions
./down.sh      # close/delete only rig-tagged artifacts; remove .work/
```

- **Workdir:** `.work/` — gitignored; holds `.flightdirector/config.json` + `.flightdirector/secrets.json` (token).
- **Markers:** rig artifacts carry a `[rig]` title prefix and the `rig` label. `down.sh` only
  touches those. GitHub REST can't delete issues — rig issues are **closed**, not removed.
- The rig only writes to `rig/*` branches and PRs between them; it never writes to `main`.
