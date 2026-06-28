# Default label taxonomy

The `bootstrapping-labels` skill reads this file and reconciles it against a repo's
existing labels, creating only the ones that are missing (or whose equivalent isn't
already present). **This is the one place to edit the defaults** — change a color, add a
label, drop one — without touching skill prose.

Conventions (decided for this plugin):
- **Type/category labels are flat**: `bug`, `feature`, `tech-debt`.
- **`model/*` and `area/*` are namespaced.**
- `model/*` is a fixed set the plugin owns (Claude-specific).
- `area/*` is **project-dependent** — the skill proposes a starter set and confirms with
  the user before creating any; it never assumes these.

## Type / category labels (flat)

| Label | Color | Description | Treat as already-present if the repo has… |
|---|---|---|---|
| `bug` | `#d73a4a` | Something is broken | `type/bug`, `kind/bug`, `defect` |
| `feature` | `#0e8a16` | New capability | `type/feature`, `enhancement`, `kind/feature` |
| `tech-debt` | `#fbca04` | Internal code quality, no user impact | `techdebt`, `debt`, `refactor` |
| `security` | `#b60205` | Security concern | `type/security`, `vuln` |
| `performance` | `#1d76db` | Speed or resource usage | `perf` |
| `ux` | `#d4c5f9` | User-facing presentation or feel | `ui`, `design` |
| `polish` | `#c2e0c6` | Minor visual refinement | — |
| `regression` | `#e99695` | Something that used to work | — |
| `quick-win` | `#bfdadc` | Small effort, clear win | `quickwin`, `good-first-issue` |
| `high-value` | `#5319e7` | High impact, worth prioritizing | `priority/high` |
| `critical` | `#b60205` | Blocks users or the app | `priority/critical`, `blocker` |

## Model labels (fixed — plugin-owned)

| Label | Color | Description | Treat as already-present if the repo has… |
|---|---|---|---|
| `model/opus` | `#6f42c1` | Issue was worked on using Opus | `opus` |
| `model/sonnet` | `#1d76db` | Issue was worked on using Sonnet | `sonnet` |
| `model/haiku` | `#0e8a16` | Issue was worked on using Haiku | `haiku` |
| `model/fable` | `#e99695` | Issue was worked on using Fable | `fable` |

## Area labels (project-dependent — confirm before creating)

Starter suggestions only. The skill should inspect the repo and **ask the user** which
areas fit before creating any. Do not seed these blindly.

| Label | Color | Description | Treat as already-present if the repo has… |
|---|---|---|---|
| `area/app` | `#fbca04` | Client / frontend app | `frontend`, `client` |
| `area/server` | `#d93f0b` | Backend / API server | `backend`, `api` |
| `area/db` | `#0052cc` | Database / schema / migrations | `database`, `schema` |

## Status labels (optional — used by `triaging-issues`)

The `triaging-issues` workable filter and the `working-an-issue` lifecycle both use these.
Listed here so a bootstrap can offer to create them too, but they're optional — skip if you
don't use a status workflow.

Each status label fills a **role** the skills reference (e.g. the "awaiting-test" role).
The name below is the plugin default; if a repo already has an equivalent, bootstrap adopts
**that** name for the role and records it in the per-repo config (see lightspeed-setup.md), so
the skills use your name, not the plugin's.

| Role | Default label | Color | Description | Adopt the repo's label if it has… |
|---|---|---|---|---|
| in-progress | `status/in progress` | `#0e8a16` | In flight | `status/doing`, `in-progress`, `wip` |
| awaiting-test | `status/to test` | `#fbca04` | Built, awaiting the user's verification | `status/qa`, `status/review`, `ready-for-test` |
| blocked | `status/blocked` | `#d73a4a` | Can't be started | `blocked` |
| deferred | `status/deferred` | `#c5def5` | Intentionally not now | `status/later`, `deferred`, `icebox` |
