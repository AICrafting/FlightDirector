# GitHub adapter + test rig — design

Add a **GitHub backend** to lightspeed behind the existing adapter contract
([adapter-contract.md](../../lightspeed/references/adapter-contract.md), ADR 0001), plus a live
test rig pointed at the real repo `git@github.com:DaveWoodCom/LightspeedTestTarget.git`. Full
parity with the Forgejo backend: `issues` + `labels` + `pr` + `ci`.

## Decisions (locked during brainstorming)

1. **Scope = full parity incl. `ci`** (GitHub Actions watch/log).
2. **Zero dispatcher changes.** The dispatcher already resolves the backend from config and execs
   `adapters/<backend>/<group>` purely from the exported `LS_*` env. Setting `backend: "github"`
   + `api: "https://api.github.com"` routes to the new adapter with nothing changed above the
   adapter boundary. The rig writes the token into the gitignored secrets file at runtime, so the
   dispatcher reads it via the normal secrets path — no token-precedence edit.
3. **Rig model = seed + marker-based surgical cleanup** against the persistent hosted repo (not a
   disposable container).
4. **Secret storage:** never in a tracked file. Rig reads `$LIGHTSPEED_GH_TOKEN` (or a gitignored
   `test-rig/github/.env` it sources) and writes it into the gitignored
   `test-rig/github/.work/.lightspeed.secrets.json`. Real use → the target repo's gitignored
   `.lightspeed.secrets.json` under `code.token`. `.gitignore` already covers `test-rig/*/.work/`
   and `.env`/`.env.*`.
5. **Out of scope (deferred):** teaching `bootstrapping-labels` to offer GitHub as a backend
   choice. Documented as a follow-up; the rig writes config directly, so the adapter is testable
   without it.

## Architecture

The dispatcher contract is unchanged. The GitHub backend is a sibling of `adapters/forgejo/` with
the **same executable names and same CLI verb signatures**; all GitHub-specific API differences are
absorbed *inside* the adapter so skills are byte-for-byte identical across backends.

```
lightspeed/scripts/adapters/github/
  _common.sh    # Bearer auth, GitHub headers, _api(), urlenc(), label helpers (sourced)
  issues        # list get create update comment attach set-status clear-status label-add close
  labels        # list resolve create
  pr            # open merge
  ci            # watch log
test-rig/github/
  up.sh         # ensure labels + ci.yml, write gitignored .work/ config
  smoke.sh      # exercise every verb against the live repo, marker-tagged, with assertions
  down.sh       # surgical marker-only cleanup
  workflows/ci.yml   # the trivial workflow up.sh seeds into the target repo (source copy)
```

## Components

### `adapters/github/_common.sh`

Mirrors Forgejo's `_common.sh` shape (consumes `LS_*`, never parses config), with GitHub
specifics:

- **Auth + headers** on every request: `Authorization: Bearer ${LS_TOKEN}`,
  `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
- `REPO_API="${LS_API%/}/repos/${LS_OWNER}/${LS_REPO}"` — with `LS_API = https://api.github.com`.
- `_api METHOD PATH [JSON_DATA]` — identical signature/behavior to Forgejo's (stdout = body,
  non-zero exit on HTTP ≥ 400, one-line `.message` error to stderr via `die`).
- **No numeric-id label machinery.** GitHub's label endpoints use names. Helpers:
  - `urlenc <s>` — percent-encode a label name for path use (names contain spaces / `/`).
  - `label_exists <name>` — `GET /labels/<urlenc name>` → 0 if 200, 1 if 404 (used by `create`
    validation and `labels resolve`).
  - `_all_labels` (cached) — `GET /labels?per_page=100`, for name→id projection in `resolve`.

### `adapters/github/issues`

Same verbs/flags as Forgejo. GitHub deltas:

| Verb | GitHub specifics |
|---|---|
| `list` | `GET /issues?state=&labels=a,b&per_page=N`; **filter out PRs** with `select(.pull_request|not)`; project `number⇥title⇥comma,labels`. |
| `get` | `GET /issues/N` → `number⇥title`, blank line, body. |
| `create` | Validate each `--label` exists first (GitHub 422s on unknown labels), then `POST /issues {title,body,labels:[names]}` → `.number`. |
| `update` | `PATCH /issues/N` with only the passed fields. |
| `comment` | `POST /issues/N/comments {body}`. |
| `attach` | **Unsupported** — `die "issues attach: not supported on GitHub (no REST API for issue attachments)"`. |
| `set-status` | role→name via `LS_LABELS_JSON` `.status`; remove every *other* managed status name on the issue via `DELETE /issues/N/labels/<urlenc name>`; add target via `POST /issues/N/labels {labels:[name]}`. |
| `clear-status` | Remove every managed `status` name present on the issue (name-based DELETE). |
| `label-add` | Validate names exist, then `POST /issues/N/labels {labels:[names]}`. |
| `close` | `PATCH /issues/N {state:"closed"}`. |

`set-status`/`clear-status` reuse the exact `LS_LABELS_JSON` role-resolution logic from the
Forgejo adapter; only the add/remove mechanics change (names, not ids).

### `adapters/github/labels`

| Verb | GitHub specifics |
|---|---|
| `list` | `GET /labels?per_page=100` → `name⇥color⇥description` (GitHub color has no leading `#`). |
| `resolve` | For each `--name`: emit `name⇥<github numeric id or empty>` (empty = not found), preserving the contract's "empty id = not found" shape. |
| `create` | `POST /labels {name,color,description}` — **strip a leading `#`** from `--color` (GitHub wants 6 bare hex). Return the new label's `.id`. |

### `adapters/github/pr`

| Verb | GitHub specifics |
|---|---|
| `open` | `--base` defaults to `LS_TRUNK`; `POST /pulls {head,base,title,body}` → `number⇥html_url`. |
| `merge` | `PUT /pulls/N/merge {merge_method: merge\|squash\|rebase}` (maps the contract's `--strategy`). |

### `adapters/github/ci`

| Verb | GitHub specifics |
|---|---|
| `watch` | Poll `GET /actions/runs?head_sha=SHA&per_page=20`; take the most recent run for the SHA; emit `task-<id> status=<state>` on each change; terminal when `status=="completed"` (then exit 0). `--status-file` writes `{"sha","status"}` like Forgejo. Resilient: a transient API/jq blip is swallowed and polling continues. |
| `log` | Resolve the run for `--sha` (or the latest failed run for `--failed BRANCH`); for each **failed job**, `GET /actions/jobs/<id>/logs` (plain text, follow the redirect with `curl -L`) and stream to stdout. Avoids the run-level `.zip`. Host-access dependent, same caveat as Forgejo's `ci log`. |

## Test rig (`test-rig/github/`)

Independent `curl` + `jq` (no `gh` dependency), mirroring the Forgejo rig's `up`/`smoke`/`down`
triptych, adapted for a **persistent hosted** target.

### `up.sh`
1. Resolve token: `$LIGHTSPEED_GH_TOKEN`, else source a gitignored `test-rig/github/.env`
   (`LIGHTSPEED_GH_TOKEN=…`); `die` with guidance if absent.
2. Verify: `GET /user` (token valid) and `GET /repos/DaveWoodCom/LightspeedTestTarget` (access).
3. **Idempotently ensure** the seed status labels exist (create any missing via the labels API),
   matching the same label set the Forgejo rig seeds.
4. **Idempotently ensure** `.github/workflows/ci.yml` exists on the default branch — a trivial
   workflow that runs on push to `rig/**` branches (so `ci watch`/`log` have a real run to
   observe). Create it via the contents API if absent. Source kept at `test-rig/github/workflows/ci.yml`.
5. Write gitignored `.work/.lightspeed.json` (`backend:"github"`, `api:"https://api.github.com"`,
   owner/repo, `code.stages` or `trunkBranch`, the `labels` map) + `.work/.lightspeed.secrets.json`
   (`code.token`).

### `smoke.sh`
Runs the dispatcher verbs from `.work/`, asserting behavior (pass/fail counter like Forgejo's).
**Everything it creates is marker-tagged: a `[rig]` title prefix and a dedicated `rig` label**, so
`down.sh` can find and remove exactly its own artifacts. Coverage:
- `issues`: create (`[rig]` title, `rig` label) → list/get → set-status single-status invariant →
  comment → label-add/clear-status → close.
- `labels`: resolve (existing → id, unknown → empty), create.
- `pr`: create a `rig/<ts>` branch with one commit (contents API), `pr open` → `pr merge`.
- `ci`: push the `rig/<ts>` branch to trigger the seeded workflow, `ci watch --sha <sha>` to a
  terminal state; assert it streams `task-<id> status=…` and exits.

### `down.sh`
Surgical, marker-only:
- Close every open issue carrying the `rig` label (GitHub REST cannot *delete* issues — closing is
  the cleanup; the label keeps them findable for manual pruning).
- Close any open `[rig]` PRs; delete every `rig/*` branch (`DELETE /git/refs/heads/rig/…`).
- `rm -rf .work/`.
- **Leave** the seed labels + workflow in place (idempotent `up.sh` re-ensures them).

Token scope required: **repo + workflow**.

## Docs (additive)

- `references/adapter-contract.md` — short note: GitHub uses name-based labels; `issues attach` is
  unsupported on GitHub.
- `references/lightspeed-setup.md` — a `backend: "github"` config example (api base
  `https://api.github.com`, no `/api/v1`; token in `.lightspeed.secrets.json`).

## Error handling

Adapters follow the contract exactly: stdout is the only data channel (TSV / minimal), stderr
carries one-line human errors, non-zero exit on any failure (network, HTTP ≥ 400, bad args). The
GitHub `_api` extracts `.message` from error bodies. `issues attach` is a deterministic non-zero
exit with a clear "unsupported on GitHub" reason.

## Testing / verification

No unit framework — the repo's established pattern:
- `shellcheck -x` clean on every new script (`_common.sh`, the four adapters, the three rig
  scripts).
- Offline argument/usage checks where feasible (unknown-verb/missing-flag `die` paths).
- The live `test-rig/github` smoke (gated on a staged `$LIGHTSPEED_GH_TOKEN`) as the integration
  verification — every verb exercised against the real repo, then cleaned up.

## Out of scope

- `bootstrapping-labels` GitHub backend selection (deferred follow-up — hand-edit `.lightspeed.json`
  for now; documented in lightspeed-setup.md).
- Pagination beyond `per_page` caps (single-page `--limit` is sufficient for current use).
- Fork-based PR heads (`owner:branch`) — same-repo branch heads only, as today.
