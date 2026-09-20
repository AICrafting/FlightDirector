# Test rigs

One rig per backend, each under its own folder, because the rigs are **not** uniform:

- **Self-hostable** backends (`forgejo/`) run a disposable container (plus an Actions runner) —
  `compose.yaml` + `up.sh`/`down.sh`.
- **SaaS** backends (`github/`, `gitlab/`, `jira/`) can't be containerized; their rigs run
  against a real throwaway repo/project named in a gitignored `.env`, tag everything they create
  (`[rig]`, `rig/*`), and tear only that down — no `compose.yaml`.

What every rig has in common is the *output*: `up.sh` leaves a `.work/` directory — a throwaway
git repo holding `.flightdirector/config.json` + `.flightdirector/secrets.json` pointed at the rig — which the
adapters then run against. `.work/` is gitignored for every backend.

```
test-rig/
  forgejo/    compose.yaml  up.sh  down.sh  smoke.sh  workflows/  README.md   (container + runner)
  github/     up.sh  down.sh  smoke.sh  workflows/  README.md                 (real repo, no compose)
  gitlab/     up.sh  down.sh  smoke.sh  gitlab-ci*.yml  README.md             (real project)
  jira/       up.sh  down.sh  smoke.sh  README.md                             (issues axis only)
```

Scripts that sit at *this* level are backend-free — they need no `up.sh`, no container, and no
token, so they run anywhere:

- `smoke-worktree-anchor.sh` — regression test for the nested-worktree bug (#57). Builds a
  throwaway repo, proves a cwd-relative `worktree add` nests under the previous worktree, and
  proves the `ROOT=` idiom extracted from `working-an-issue/SKILL.md` defeats it. Because it
  greps the idiom out of the shipped skill, it fails if that snippet drifts.

The adapter contract is backend-agnostic, so the `smoke.sh` assertions are largely the same
across rigs — only provisioning differs. All three code rigs now carry the same `ci watch` /
`ci log` section (#138, #186); extracting the shared assertions up to this level, driven by each
backend's `up`/`down`, is the obvious next step and has not been done yet.

## Running the rigs from CI (#187)

The `rigs` workflow (`.github/workflows/rigs.yml`) runs them on the forge: **Actions → `rigs` →
Run workflow**, with the input `all`, or a space-separated subset (`github gitlab`).

- **Manual only (`workflow_dispatch`).** Each rig waits minutes on real CI and writes to a shared
  throwaway repo, so it must not fire on every push. Running them is instead part of
  [cutting a release](../CONTRIBUTING.md#cutting-a-release), and `scripts/tag-release.sh` prints
  the reminder.
- **Secrets.** The SaaS rigs read `FLIGHT_GH_REPO` / `FLIGHT_GH_TOKEN` and `FLIGHT_GITLAB_TOKEN` /
  `_API` / `_PROJECT` from the repo's Actions secrets — scoped to the throwaway test repos only,
  and they expire, so check the dates when a rig starts failing on auth. A job whose secrets are
  missing **skips with a notice** instead of failing, which is also what keeps the workflow inert
  on the public GitHub mirror, where those secrets do not exist. (`FLIGHT_GH_API` is only needed
  for GitHub Enterprise Server.)
- **`RIG_STRICT=1`.** Locally, a rig that cannot reach a CI verdict — no runner, or CI too slow —
  warns and carries on. Unattended, a warning nobody reads is a silent skip, so the workflow sets
  `RIG_STRICT=1` and those cases fail the job instead. `up.sh`/`smoke.sh` honour it anywhere.
- **Teardown always runs**, so a red smoke test cannot leave rig branches and open PRs behind.
- **One run at a time.** The workflow takes a `live-test-rigs` concurrency group, because every
  `down.sh` deletes *all* `rig/*` branches and closes *all* `[rig]` issues/PRs — two concurrent
  runs would tear down each other's work. That cannot protect against someone running a rig
  **locally** while CI runs: the two would collide the same way, so don't.
- **The forge token has to be unshadowed.** A Forgejo Actions job is handed `FORGEJO_TOKEN` in
  its environment, and the dispatcher resolves `LS_TOKEN` / `FLIGHT_TOKEN` / `FORGEJO_TOKEN`
  ahead of the repo's `secrets.json` without reporting which won (#177) — so a rig would
  authenticate to GitHub or GitLab with a *Forgejo* token and 401 on every call, while its own
  `up.sh` (which uses its own variable and curl directly) provisions happily. Each rig step
  therefore `unset`s the three names first. Remove that once #177 lands.
- **The Forgejo rig drives the runner host's docker**, since it brings up its own instance and
  Actions runner with compose. This forge runs jobs in a container that has the docker **socket**
  but no docker **CLI**, so that job runs without a `container:` of its own and installs a
  pinned, checksummed client (plus compose and `jq` — it cannot assume the image has them). The
  daemon it talks to is the host's, which has two consequences worth knowing:
  - the rig's containers are **siblings on the runner host**, not children of the job, so a run
    that dies before teardown leaves `flight-rig-*` containers there; the job clears them before
    it starts, and tears down in an `always()` step;
  - the published port lands on the **host**, so `localhost` inside the job is the wrong address.
    The job passes `RIG_HOST` (its default gateway, read from `/proc/net/route` — it is not the
    same address every run) and `RIG_PORT=3737`. The compose network is unaffected: the runner
    container still reaches Forgejo as `http://forgejo:3000`.
