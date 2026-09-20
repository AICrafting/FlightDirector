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
across rigs — only provisioning differs. If/when a second rig lands, the shared assertions are
a candidate to extract up to this level, driven by each backend's `up`/`down`. Not extracted
yet (one rig — nothing to share against).
