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
- **The Forgejo rig needs the host's docker**, since it brings up its own instance and runner with
  compose; its job therefore runs without a `container:` and probes for `docker compose` first,
  warning and skipping the rig if the runner cannot provide it.
