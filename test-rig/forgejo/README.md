# Flight Forgejo test rig

A disposable Forgejo instance for exercising the adapters against a real API. **Dev tooling —
not part of the plugin.** Requires `docker` (+ compose) and `jq`.

```bash
./up.sh        # start Forgejo + an Actions runner, provision admin/token/repo/labels, write workdir config
./smoke.sh     # run the adapter verbs against the live instance, with assertions
./down.sh      # stop and remove the containers, their volumes, and the workdir
```

- **Port:** `3000` by default; override with `RIG_PORT=3100 ./up.sh`, or copy `.env.example` to
  `.env` (gitignored) and set it there. The same file can override the admin user/password/email
  and the test repo name (`FLIGHT_FORGEJO_USER` / `_PASS` / `_EMAIL` / `_REPO`) — all defaulted,
  since the instance is disposable.
- **Images:** `code.forgejo.org/forgejo/forgejo:16` and `code.forgejo.org/forgejo/runner:13`
  (pinned to the current majors); override with `FORGEJO_IMAGE=…` / `FORGEJO_RUNNER_IMAGE=…`.
  Forgejo 16 is the floor: `ci log` reads per-job logs from `/actions/jobs/{id}/logs`, which
  arrived in 16.
- **Workdir:** `.work/` — a throwaway git repo holding `.flightdirector/config.json` +
  `.flightdirector/secrets.json` pointed at the rig. Gitignored. Drive the adapters by hand from
  there:

  ```bash
  ( cd test-rig/forgejo/.work && ../../../flight/scripts/flight issues list )
  ```

## CI: the runner, and what the smoke test asserts (#186)

Actions is enabled and the compose file runs a second container, `flight-rig-runner`. `up.sh`
asks Forgejo for a registration token (`forgejo actions generate-runner-token`), registers the
runner with the label `rig`, and the container — which idles until `/data/.runner` exists — then
starts the daemon. Re-running `up.sh` finds it already registered.

- **Host mode, no Docker socket.** The runner executes jobs as plain shell inside its own
  throwaway container (`--labels rig:host`). It is not given the host's Docker socket and does
  not run docker-in-docker, so a CI job cannot reach the host's other containers. The price: no
  node, so no `actions/checkout`. The rig's workflows only `echo`, and the red one asks Forgejo
  for a file over the compose network (`http://forgejo:3000/<repo>/raw/commit/<sha>/rig-fail`)
  instead of checking the branch out.
- **What runs.** The last smoke section opens a PR whose head branch carries
  `workflows/rig-pr-red.yml` + `workflows/rig-pr-green.yml` (written to `.forgejo/workflows/` on
  a `rig/*` branch): a job that fails while a `rig-fail` file exists and one that always passes,
  so one commit holds a red and a green `pull_request` run that started together.
- **What is asserted.** `ci watch --pr` sees both runs and ends at `status=failure`;
  `ci log --pr`, `--sha` and `--failed <branch>` each show the red job's log and not the green
  one's (#138); after `rig-fail` is removed the new head watches green and `ci log --pr` says
  `(no failed jobs …)`. It is the same section the GitHub and GitLab rigs run.
- **If the runner is not online** — registration failed, or the image could not be pulled —
  `up.sh` says so, every non-CI check still runs, and the CI section warns and skips rather than
  failing. Once a run reaches a verdict, the assertions are hard.
- Adds roughly half a minute to `smoke.sh`; the first `up.sh` also pulls the runner image.
