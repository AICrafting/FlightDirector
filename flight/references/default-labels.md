# Default label taxonomy

The `setting-up-a-repo` skill reads this file and reconciles it against a repo's
existing labels, creating only the ones that are missing (or whose equivalent isn't
already present). **This is the one place to edit the defaults** — change a color, add a
label, drop one — without touching skill prose.

Conventions (decided for this plugin):
- **Type/category labels are flat**: `bug`, `feature`, `tech-debt`.
- **`model/*` and `area/*` are namespaced.**
- `model/*` is an extensible provenance namespace. Setup seeds common labels, and ledger
  finalization lazily creates a missing label for the active model family without changing an
  existing label.
- `area/*` is **project-dependent** — the skill proposes a starter set and confirms with
  the user before creating any; it never assumes these.
- **One colour per categorical prefix group.** Every `model/*` label shares one colour and
  every `area/*` label shares another, so the prefix reads as a colour family at a glance in
  the issue list. The same rule extends to any future namespaced prefix (e.g. `tool/*`).
- **`status/*` is the deliberate exception**: each state keeps its own distinct, semantic
  colour (blocked reads red, qa reads teal, …) because the colour *is* the signal there.
- **Prefix-less type/category labels each keep their own distinct colour.**

## Type / category labels (flat)

| Label | Color | Description | Treat as already-present if the repo has… |
|---|---|---|---|
| `bug` | `#d73a4a` | Something is broken | `type/bug`, `kind/bug`, `defect` |
| `feature` | `#0e8a16` | New capability | `type/feature`, `enhancement`, `kind/feature` |
| `tech-debt` | `#9a6700` | Internal code quality, no user impact | `techdebt`, `debt`, `refactor` |
| `security` | `#7c2d12` | Security concern | `type/security`, `vuln` |
| `performance` | `#0aa1b0` | Speed or resource usage | `perf` |
| `ux` | `#d4c5f9` | User-facing presentation or feel | `ui`, `design` |
| `polish` | `#c2e0c6` | Minor visual refinement | — |
| `regression` | `#e11d48` | Something that used to work | — |
| `quick-win` | `#bfdadc` | Small effort, clear win | `quickwin`, `good-first-issue` |
| `high-value` | `#6f42c1` | High impact, worth prioritizing | `priority/high` |
| `critical` | `#b60205` | Blocks users or the app | `priority/critical`, `blocker` |

## Model labels (seeded defaults; extensible at runtime)

One colour for the whole group — Claude's coral, `#d97757`.

The dispatcher normalizes a model identifier to a stable family (`gpt-5.6-sol` → `sol`,
`claude-opus-4.7` → `opus`) through `labels model-family` / `labels ensure --model`. Unknown
families use a lowercase, hyphenated form of the reported identifier with a warning.

| Label | Color | Description | Treat as already-present if the repo has… |
|---|---|---|---|
| `model/opus` | `#d97757` | Issue was worked on using Opus | `opus` |
| `model/sonnet` | `#d97757` | Issue was worked on using Sonnet | `sonnet` |
| `model/haiku` | `#d97757` | Issue was worked on using Haiku | `haiku` |
| `model/fable` | `#d97757` | Issue was worked on using Fable | `fable` |
| `model/sol` | `#d97757` | Issue was worked on using Sol | `sol` |
| `model/terra` | `#d97757` | Issue was worked on using Terra | `terra` |
| `model/luna` | `#d97757` | Issue was worked on using Luna | `luna` |
| `model/astra` | `#d97757` | Issue was worked on using Astra | `astra` |

## Area labels (project-dependent — confirm before creating)

Starter suggestions only. The skill should inspect the repo and **ask the user** which
areas fit before creating any. Do not seed these blindly. Whatever set is chosen, **every
`area/*` label takes the one group colour** — Tailwind blue, `#3b82f6`.

| Label | Color | Description | Treat as already-present if the repo has… |
|---|---|---|---|
| `area/app` | `#3b82f6` | Client / frontend app | `frontend`, `client` |
| `area/server` | `#3b82f6` | Backend / API server | `backend`, `api` |
| `area/db` | `#3b82f6` | Database / schema / migrations | `database`, `schema` |

## Status labels (optional — used by `triaging-issues`)

The `triaging-issues` workable filter and the `working-an-issue` lifecycle both use these.
Listed here so a bootstrap can offer to create them too, but they're optional — skip if you
don't use a status workflow.

Each status label fills a **role** the skills reference (e.g. the "awaiting-test" role).
The name below is the plugin default; if a repo already has an equivalent, bootstrap adopts
**that** name for the role and records it in the per-repo config (see flight-setup.md), so
the skills use your name, not the plugin's.

| Role | Default label | Color | Description | Adopt the repo's label if it has… |
|---|---|---|---|---|
| in-progress | `status/in progress` | `#1f9d55` | In flight | `status/doing`, `in-progress`, `wip` |
| awaiting-test | `status/to test` | `#e3a008` | Built, awaiting the user's verification | `status/testing`, `to-test`, `ready-for-test` |
| blocked | `status/blocked` | `#d11149` | Can't be started | `blocked` |
| deferred | `status/deferred` | `#6b7280` | Intentionally not now | `status/later`, `deferred`, `icebox` |
| review | `status/review` | `#8957e5` | In an open PR awaiting review | `review`, `in-review`, `under-review` |
| qa | `status/qa` | `#0e7490` | Merged, awaiting real-world verification | `qa`, `awaiting-qa` |
| done | `status/done` | `#216e39` | Shipped / released — the terminal close state | `done`, `shipped`, `released`, `complete` |

**Terminal `issueStatus`.** A terminal stage may set `issueStatus: "done"` so that closing an
issue also relabels it to `status/done` (the atomic `set-status` drops the prior `status/qa` on
the way to closing). Without it, a closed issue keeps its last in-flight status label, which reads
as still-in-progress — set the `done` role on the terminal stage to avoid that.
