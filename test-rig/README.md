# Test rigs

One rig per backend, each under its own folder, because the rigs are **not** uniform:

- **Self-hostable** backends (`forgejo/`, and later `gitlab/`) run a disposable container —
  `compose.yaml` + `up.sh`/`down.sh`.
- **SaaS** backends (later `github/`, `jira/`, `asana/`) can't be containerized; their rigs
  provision an ephemeral repo/token against a real test account via API, then tear it down —
  no `compose.yaml`.

What every rig has in common is the *output*: `up.sh` leaves a `.work/` directory — a throwaway
git repo holding `.flightdirector/config.json` + `.flightdirector/secrets.json` pointed at the rig — which the
adapters then run against. `.work/` is gitignored for every backend.

```
test-rig/
  forgejo/    compose.yaml  up.sh  down.sh  smoke.sh  README.md   ← current
  github/     up.sh  down.sh  smoke.sh  README.md                 (future, no compose)
  …
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
