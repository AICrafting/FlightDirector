# GitHub adapter + test rig Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub backend to lightspeed behind the existing adapter contract (`adapters/github/{_common.sh,issues,labels,pr,ci}`) with full parity (issues + labels + pr + ci), plus a marker-based live test rig (`test-rig/github/`) against the real `DaveWoodCom/LightspeedTestTarget` repo.

**Architecture:** The dispatcher is unchanged — it already execs `adapters/<backend>/<group>` from the exported `LS_*` env. The GitHub adapter is a sibling of `adapters/forgejo/` with the **same executable names and CLI verb signatures**; all GitHub API differences are absorbed inside it (Bearer auth, name-based labels, PR-filtering in issue lists, `attach` unsupported, per-job `ci log`). Many verbs are byte-identical to Forgejo's once `_common.sh` is swapped — those are copied; the divergent verbs get full replacement code below.

**Tech Stack:** bash + `curl` + `jq` (adapters/rig), GitHub REST API v3 (`https://api.github.com`, `X-GitHub-Api-Version: 2022-11-28`), a seeded GitHub Actions workflow for `ci` smoke. No new language/dependency.

**Verification model:** This repo has no unit-test framework. Established pattern: `shellcheck -x` clean on every script + offline `die`-path checks (bad/missing args exit non-zero with a reason — no network) + the live rig smoke for functional coverage. Adapter tasks verify with shellcheck + offline checks; the **live** functional verification is the gated rig run (Task 9), which needs `$LIGHTSPEED_GH_TOKEN` staged (token scope: **repo + workflow**).

**Spec:** `docs/superpowers/specs/2026-06-28-github-adapter-design.md`.

**Reference (copy-from source):** the Forgejo adapter at `lightspeed/scripts/adapters/forgejo/` — read each file before copying.

**Phasing:** Phase 1 (Tasks 1–4) the issue/label/pr adapters; Phase 2 (Task 5) the ci adapter; Phase 3 (Tasks 6–9) the rig + a live run; Phase 4 (Task 10) docs. Do them in order.

`$SCRATCH` below = the session scratchpad dir (temp scripts, never committed).

---

## Phase 1 — issues / labels / pr adapters

### Task 1: `adapters/github/_common.sh`

**Files:**
- Create: `lightspeed/scripts/adapters/github/_common.sh`

- [ ] **Step 1: Create the file**

```bash
#!/usr/bin/env bash
#
# Shared helpers for the GitHub adapter — sourced by issues/pr/ci/labels.
# Consumes the LS_* environment exported by the dispatcher; never reads config.
# shellcheck shell=bash

command -v curl >/dev/null 2>&1 || { echo "github adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "github adapter: jq is required" >&2; exit 1; }

: "${LS_API:?LS_API not set (dispatcher must export it)}"
: "${LS_OWNER:?LS_OWNER not set}"
: "${LS_REPO:?LS_REPO not set}"
: "${LS_TOKEN:?LS_TOKEN not set — no token resolved for this axis}"

REPO_API="${LS_API%/}/repos/${LS_OWNER}/${LS_REPO}"

die() { echo "${ADAPTER_NAME:-github}: $*" >&2; exit 1; }

# GitHub auth + content headers applied to every request.
GH_HEADERS=(
  -H "Authorization: Bearer ${LS_TOKEN}"
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

# _api METHOD PATH [JSON_DATA] — stdout is the response body; exits nonzero on HTTP >= 400.
# -L so we follow GitHub's redirects (e.g. log endpoints).
_api() {
  local method="$1" path="$2" data="${3:-}" tmp code msg
  tmp="$(mktemp)"
  if [ -n "$data" ]; then
    code="$(curl -sS -L -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GH_HEADERS[@]}" -H "Content-Type: application/json" \
      --data-binary "$data" "${REPO_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  else
    code="$(curl -sS -L -o "$tmp" -w '%{http_code}' -X "$method" \
      "${GH_HEADERS[@]}" "${REPO_API}${path}")" || { rm -f "$tmp"; die "$method $path: curl failed"; }
  fi
  if [ "$code" -ge 400 ]; then
    msg="$(jq -r '.message // empty' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    die "$method $path → HTTP $code${msg:+: $msg}"
  fi
  cat "$tmp"; rm -f "$tmp"
}

# urlenc <string> — percent-encode for a URL path segment. Label names contain
# spaces and '/', which must be encoded for the DELETE-label-by-name endpoint.
# Handles ASCII (label names are ASCII in this project).
urlenc() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Labels fetched once and cached for the life of the process.
_LABELS_CACHE=""
_all_labels() {
  [ -n "$_LABELS_CACHE" ] || _LABELS_CACHE="$(_api GET "/labels?per_page=100")"
  printf '%s' "$_LABELS_CACHE"
}

# label_id <name> — github numeric id on stdout, empty if the label doesn't exist.
# (GitHub label endpoints use names, not ids; this exists so `labels resolve`
# can return the contract's name⇥id shape and `create` can check existence.)
label_id() {
  _all_labels | jq -r --arg n "$1" '[.[] | select(.name==$n) | .id] | first // empty'
}
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck -x lightspeed/scripts/adapters/github/_common.sh`
Expected: no errors. (It's sourced, so `shellcheck shell=bash` is declared; `LS_*` come from the dispatcher.)

- [ ] **Step 3: Offline sourcing + urlenc smoke**

```bash
cat > "$SCRATCH/gh-common-check.sh" <<'EOF'
set -euo pipefail
export LS_API="https://api.github.com" LS_OWNER=o LS_REPO=r LS_TOKEN=t
source lightspeed/scripts/adapters/github/_common.sh
echo "REPO_API=$REPO_API"                 # expect: https://api.github.com/repos/o/r
echo "enc=$(urlenc 'status/in progress')" # expect: status%2Fin%20progress
EOF
bash "$SCRATCH/gh-common-check.sh"
```
Run: the block above.
Expected: `REPO_API=https://api.github.com/repos/o/r` and `enc=status%2Fin%20progress`.

- [ ] **Step 4: Commit**

```bash
git add lightspeed/scripts/adapters/github/_common.sh
git commit -m "github adapter: _common.sh (Bearer auth, urlenc, name-based label helpers)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: `adapters/github/issues`

**Files:**
- Create: `lightspeed/scripts/adapters/github/issues`

- [ ] **Step 1: Copy the Forgejo issues adapter as the starting point**

```bash
mkdir -p lightspeed/scripts/adapters/github
cp lightspeed/scripts/adapters/forgejo/issues lightspeed/scripts/adapters/github/issues
chmod +x lightspeed/scripts/adapters/github/issues
```
Then change the header line `ADAPTER_NAME="forgejo/issues"` → `ADAPTER_NAME="github/issues"`.
The `get`, `update`, `comment`, and `close` verbs are byte-identical to GitHub's API and need
**no change**. Replace the verbs below.

- [ ] **Step 2: Replace the `list` verb** (GitHub paginates with `per_page`, mixes PRs into `/issues` — filter them out)

Replace the entire `list)` case block with:

```bash
  list)
    state="open"; limit="50"; labels=()
    while [ $# -gt 0 ]; do case "$1" in
      --state) state="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --label) labels+=("$2"); shift 2 ;;
      *) die "issues list: unknown arg '$1'" ;;
    esac; done
    q="state=${state}&per_page=${limit}"
    if [ ${#labels[@]} -gt 0 ]; then
      old="$IFS"; IFS=,; q="${q}&labels=${labels[*]}"; IFS="$old"
    fi
    _api GET "/issues?${q}" \
      | jq -r '.[] | select(.pull_request | not)
               | [(.number|tostring), .title, ([.labels[].name] | join(","))] | @tsv'
    ;;
```

- [ ] **Step 3: Replace the `create` verb** (labels are passed by **name**; validate they exist first)

Replace the entire `create)` case block with:

```bash
  create)
    title=""; body=""; body_file=""; labels=()
    while [ $# -gt 0 ]; do case "$1" in
      --title)     title="$2"; shift 2 ;;
      --body)      body="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --label)     labels+=("$2"); shift 2 ;;
      *) die "issues create: unknown arg '$1'" ;;
    esac; done
    [ -n "$title" ] || die "issues create: --title required"
    if [ -n "$body_file" ]; then
      [ -f "$body_file" ] || die "issues create: --body-file '$body_file' not found"
      payload="$(jq -n --arg t "$title" --rawfile b "$body_file" '{title:$t, body:$b}')"
    else
      payload="$(jq -n --arg t "$title" --arg b "$body" '{title:$t, body:$b}')"
    fi
    if [ ${#labels[@]} -gt 0 ]; then
      for n in "${labels[@]}"; do
        [ -n "$(label_id "$n")" ] \
          || die "issues create: label '$n' not found — create it first (labels create / bootstrapping-labels)"
      done
      names_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s .)"
      payload="$(printf '%s' "$payload" | jq --argjson l "$names_json" '. + {labels:$l}')"
    fi
    _api POST "/issues" "$payload" | jq -r '.number'
    ;;
```

- [ ] **Step 4: Replace the `attach` verb** (unsupported on GitHub)

Replace the entire `attach)` case block with:

```bash
  attach)
    die "issues attach: not supported on GitHub (no REST API for issue attachments)"
    ;;
```

- [ ] **Step 5: Replace the `set-status` verb** (name-based add/remove)

Replace the entire `set-status)` case block with:

```bash
  set-status)
    number=""; role=""
    while [ $# -gt 0 ]; do case "$1" in
      --number) number="$2"; shift 2 ;;
      --status) role="$2"; shift 2 ;;
      *) die "issues set-status: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "issues set-status: --number required"
    [ -n "$role" ]   || die "issues set-status: --status required"

    labels_json="${LS_LABELS_JSON:-}"; [ -n "$labels_json" ] || labels_json='{}'
    target_name="$(printf '%s' "$labels_json" | jq -r --arg r "$role" '.status[$r] // empty')"
    [ -n "$target_name" ] || die "set-status: role '$role' not found in labels.status config"
    [ -n "$(label_id "$target_name")" ] || die "set-status: label '$target_name' does not exist on the repo"

    # Names currently on the issue (JSON array).
    current_names="$(_api GET "/issues/${number}" | jq -c '[.labels[].name]')"
    # Remove every *other* managed status label currently present.
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ "$n" = "$target_name" ] && continue
      if printf '%s' "$current_names" | jq -e --arg n "$n" 'index($n) != null' >/dev/null; then
        _api DELETE "/issues/${number}/labels/$(urlenc "$n")" >/dev/null
      fi
    done < <(printf '%s' "$labels_json" | jq -r '.status // {} | .[]')
    # Add the target by name.
    _api POST "/issues/${number}/labels" "$(jq -n --arg n "$target_name" '{labels:[$n]}')" >/dev/null
    ;;
```

- [ ] **Step 6: Replace the `clear-status` verb** (name-based)

Replace the entire `clear-status)` case block with:

```bash
  clear-status)
    number=""
    while [ $# -gt 0 ]; do case "$1" in
      --number) number="$2"; shift 2 ;;
      *) die "issues clear-status: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "issues clear-status: --number required"
    labels_json="${LS_LABELS_JSON:-}"; [ -n "$labels_json" ] || labels_json='{}'
    current_names="$(_api GET "/issues/${number}" | jq -c '[.labels[].name]')"
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if printf '%s' "$current_names" | jq -e --arg n "$n" 'index($n) != null' >/dev/null; then
        _api DELETE "/issues/${number}/labels/$(urlenc "$n")" >/dev/null
      fi
    done < <(printf '%s' "$labels_json" | jq -r '.status // {} | .[]')
    ;;
```

- [ ] **Step 7: Replace the `label-add` verb** (name-based)

Replace the entire `label-add)` case block with:

```bash
  label-add)
    number=""; labels=()
    while [ $# -gt 0 ]; do case "$1" in
      --number) number="$2"; shift 2 ;;
      --label)  labels+=("$2"); shift 2 ;;
      *) die "issues label-add: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "issues label-add: --number required"
    [ ${#labels[@]} -gt 0 ] || die "issues label-add: at least one --label required"
    for n in "${labels[@]}"; do
      [ -n "$(label_id "$n")" ] || die "issues label-add: label '$n' not found"
    done
    names_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s .)"
    _api POST "/issues/${number}/labels" "$(jq -n --argjson l "$names_json" '{labels:$l}')" >/dev/null
    ;;
```

- [ ] **Step 8: Update the final usage `die` line**

The `*)` catch-all already lists the verbs; leave its text as-is (the verb set is unchanged). Confirm
the file still sources `_common.sh` via the relative `source "$(cd "$(dirname "$0")" && pwd)/_common.sh"`
line (unchanged by the copy).

- [ ] **Step 9: shellcheck + offline die-path checks**

```bash
shellcheck -x lightspeed/scripts/adapters/github/issues
# Offline checks — these die before any network call:
ENV='LS_API=https://api.github.com LS_OWNER=o LS_REPO=r LS_TOKEN=t'
A=lightspeed/scripts/adapters/github/issues
env $ENV "$A" attach --number 1 --file x 2>&1; echo "exit=$?"     # expect: "...not supported on GitHub", exit=1
env $ENV "$A" bogusverb 2>&1; echo "exit=$?"                      # expect: "unknown verb 'bogusverb'", exit=1
env $ENV "$A" set-status --number 1 2>&1; echo "exit=$?"          # expect: "--status required", exit=1
```
Run: the block above.
Expected: shellcheck clean; each offline check prints the quoted reason and `exit=1` (no network attempted, because the `die` fires on argument validation before `_api`). Note: `attach` dies immediately; `set-status --number 1` dies on the missing `--status` before any API call.

- [ ] **Step 10: Commit**

```bash
git add lightspeed/scripts/adapters/github/issues
git commit -m "github adapter: issues (PR-filtered list, name-based labels, attach unsupported)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3: `adapters/github/labels`

**Files:**
- Create: `lightspeed/scripts/adapters/github/labels`

- [ ] **Step 1: Copy the Forgejo labels adapter**

```bash
cp lightspeed/scripts/adapters/forgejo/labels lightspeed/scripts/adapters/github/labels
chmod +x lightspeed/scripts/adapters/github/labels
```
Change `ADAPTER_NAME="forgejo/labels"` → `ADAPTER_NAME="github/labels"`. The `resolve` verb is
identical (it uses `label_id`, which our `_common.sh` defines). Replace `list` and `create` below.

- [ ] **Step 2: Replace the `list` verb** (GitHub uses `per_page`)

Replace the entire `list)` case block with:

```bash
  list)
    _api GET "/labels?per_page=100" | jq -r '.[] | [.name, .color, (.description // "")] | @tsv'
    ;;
```

- [ ] **Step 3: Replace the `create` verb** (GitHub color is bare hex — strip a leading `#`)

Replace the entire `create)` case block with:

```bash
  create)
    name=""; color=""; desc=""
    while [ $# -gt 0 ]; do case "$1" in
      --name)        name="$2"; shift 2 ;;
      --color)       color="$2"; shift 2 ;;
      --description) desc="$2"; shift 2 ;;
      *) die "labels create: unknown arg '$1'" ;;
    esac; done
    [ -n "$name" ]  || die "labels create: --name required"
    [ -n "$color" ] || die "labels create: --color required (e.g. #0088ff or 0088ff)"
    color="${color#\#}"   # GitHub wants 6 bare hex digits, no leading '#'
    payload="$(jq -n --arg n "$name" --arg c "$color" --arg d "$desc" \
      '{name:$n, color:$c} + (if $d == "" then {} else {description:$d} end)')"
    _api POST "/labels" "$payload" | jq -r '.id'
    ;;
```

- [ ] **Step 4: shellcheck + offline checks**

```bash
shellcheck -x lightspeed/scripts/adapters/github/labels
ENV='LS_API=https://api.github.com LS_OWNER=o LS_REPO=r LS_TOKEN=t'
A=lightspeed/scripts/adapters/github/labels
env $ENV "$A" create --name x 2>&1; echo "exit=$?"   # expect: "--color required", exit=1
env $ENV "$A" nope 2>&1; echo "exit=$?"              # expect: "unknown verb 'nope'", exit=1
```
Expected: shellcheck clean; both print the reason + `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add lightspeed/scripts/adapters/github/labels
git commit -m "github adapter: labels (per_page list, bare-hex color on create)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4: `adapters/github/pr`

**Files:**
- Create: `lightspeed/scripts/adapters/github/pr`

- [ ] **Step 1: Copy the Forgejo pr adapter**

```bash
cp lightspeed/scripts/adapters/forgejo/pr lightspeed/scripts/adapters/github/pr
chmod +x lightspeed/scripts/adapters/github/pr
```
Change `ADAPTER_NAME="forgejo/pr"` → `ADAPTER_NAME="github/pr"`. The `open` verb is identical
(GitHub `POST /pulls` returns `.html_url`). Replace `merge` below.

- [ ] **Step 2: Replace the `merge` verb** (GitHub uses `PUT` + `merge_method`)

Replace the entire `merge)` case block with:

```bash
  merge)
    number=""; strategy="merge"
    while [ $# -gt 0 ]; do case "$1" in
      --number)   number="$2"; shift 2 ;;
      --strategy) strategy="$2"; shift 2 ;;
      *) die "pr merge: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "pr merge: --number required"
    case "$strategy" in
      merge|squash|rebase) ;;
      *) die "pr merge: --strategy must be merge|squash|rebase" ;;
    esac
    _api PUT "/pulls/${number}/merge" "$(jq -n --arg m "$strategy" '{merge_method:$m}')" >/dev/null
    ;;
```

- [ ] **Step 3: shellcheck + offline checks**

```bash
shellcheck -x lightspeed/scripts/adapters/github/pr
ENV='LS_API=https://api.github.com LS_OWNER=o LS_REPO=r LS_TOKEN=t'
A=lightspeed/scripts/adapters/github/pr
env $ENV "$A" merge --number 1 --strategy bogus 2>&1; echo "exit=$?"  # expect: "--strategy must be merge|squash|rebase", exit=1
env $ENV "$A" open --head h 2>&1; echo "exit=$?"                      # expect: "--base required..." (no trunk env), exit=1
```
Expected: shellcheck clean; both print the reason + `exit=1`.

- [ ] **Step 4: Commit**

```bash
git add lightspeed/scripts/adapters/github/pr
git commit -m "github adapter: pr (PUT merge with merge_method)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 2 — ci adapter

### Task 5: `adapters/github/ci`

**Files:**
- Create: `lightspeed/scripts/adapters/github/ci`

- [ ] **Step 1: Create the file**

```bash
#!/usr/bin/env bash
#
# GitHub CI adapter — verbs: watch log.  Against the GitHub Actions API.
# See ../../../references/adapter-contract.md.
set -euo pipefail
ADAPTER_NAME="github/ci"
# shellcheck source-path=SCRIPTDIR source=_common.sh
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

verb="${1:-}"; shift || true

case "$verb" in
  # Stream one line per CI state change for a commit, exit on a terminal state.
  # Background-friendly for the Monitor tool. Resilient: a transient API/jq blip
  # is swallowed and the poll continues, rather than killing the watcher.
  watch)
    sha=""; status_file=""
    while [ $# -gt 0 ]; do case "$1" in
      --sha)         sha="$2"; shift 2 ;;
      --status-file) status_file="$2"; shift 2 ;;
      *) die "ci watch: unknown arg '$1'" ;;
    esac; done
    [ -n "$sha" ] || die "ci watch: --sha required"

    _write() {
      [ -n "$status_file" ] || return 0
      mkdir -p "$(dirname "$status_file")"
      printf '{"sha":"%s","status":"%s"}\n' "$sha" "$1" >"$status_file"
    }

    last_id=""; last_state=""
    while true; do
      body="$(curl -sS -L "${GH_HEADERS[@]}" \
        "${REPO_API}/actions/runs?head_sha=${sha}&per_page=20" 2>/dev/null || true)"
      line="$(printf '%s' "$body" | jq -r \
        '[.workflow_runs[]?] | sort_by(.run_started_at) | last
         | select(. != null) | "\(.id) \(.status)"' 2>/dev/null || true)"
      if [ -n "$line" ]; then
        id="${line%% *}"; state="${line##* }"
        if [ "$id" != "$last_id" ] || [ "$state" != "$last_state" ]; then
          echo "task-${id} status=${state}"
          _write "$state"
          last_id="$id"; last_state="$state"
        fi
        # GitHub run status is queued|in_progress|completed.
        [ "$state" = "completed" ] && exit 0
      fi
      sleep 5
    done
    ;;

  # Dump the failed jobs' logs for a commit (or the latest failed run on a branch).
  # Per-job logs are plain text via redirect — avoids the run-level .zip.
  log)
    sha=""; failed_branch=""
    while [ $# -gt 0 ]; do case "$1" in
      --sha)    sha="$2"; shift 2 ;;
      --failed) failed_branch="$2"; shift 2 ;;
      *) die "ci log: unknown arg '$1'" ;;
    esac; done
    [ -n "$sha" ] || [ -n "$failed_branch" ] || die "ci log: --sha or --failed required"

    if [ -n "$sha" ]; then
      run_id="$(_api GET "/actions/runs?head_sha=${sha}&per_page=20" \
        | jq -r '[.workflow_runs[]?] | sort_by(.run_started_at) | last | .id // empty')"
    else
      run_id="$(_api GET "/actions/runs?branch=${failed_branch}&status=failure&per_page=1" \
        | jq -r '.workflow_runs[0].id // empty')"
    fi
    [ -n "$run_id" ] || die "ci log: no workflow run found"

    # Failed job ids for that run.
    job_ids="$(_api GET "/actions/runs/${run_id}/jobs?per_page=100" \
      | jq -r '.jobs[]? | select(.conclusion=="failure") | .id')"
    [ -n "$job_ids" ] || { echo "(no failed jobs for run ${run_id})"; exit 0; }

    while IFS= read -r jid; do
      [ -n "$jid" ] || continue
      echo "── job ${jid} ──"
      # Per-job logs endpoint 302-redirects to plain-text logs; -L follows it.
      curl -sS -L "${GH_HEADERS[@]}" "${REPO_API}/actions/jobs/${jid}/logs" || true
    done <<< "$job_ids"
    ;;

  *) die "unknown verb '${verb}' (ci: watch log)" ;;
esac
```

- [ ] **Step 2: shellcheck + offline checks**

```bash
chmod +x lightspeed/scripts/adapters/github/ci
shellcheck -x lightspeed/scripts/adapters/github/ci
ENV='LS_API=https://api.github.com LS_OWNER=o LS_REPO=r LS_TOKEN=t'
A=lightspeed/scripts/adapters/github/ci
env $ENV "$A" watch 2>&1; echo "exit=$?"   # expect: "ci watch: --sha required", exit=1
env $ENV "$A" log 2>&1; echo "exit=$?"     # expect: "ci log: --sha or --failed required", exit=1
env $ENV "$A" nope 2>&1; echo "exit=$?"    # expect: "unknown verb 'nope'", exit=1
```
Expected: shellcheck clean; each prints the reason + `exit=1`.

- [ ] **Step 3: Commit**

```bash
git add lightspeed/scripts/adapters/github/ci
git commit -m "github adapter: ci (watch Actions runs, per-job log)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 3 — test rig

### Task 6: rig workflow + `up.sh`

**Files:**
- Create: `test-rig/github/workflows/ci.yml`
- Create: `test-rig/github/up.sh`
- Create: `test-rig/github/README.md`

- [ ] **Step 1: Create the seeded workflow source** `test-rig/github/workflows/ci.yml`

```yaml
# Seeded by test-rig/github/up.sh into the target repo at .github/workflows/ci.yml.
# Trivial workflow so `lightspeed ci watch/log` have a real Actions run to observe.
# Runs on push to rig/** branches only (keeps it out of the way of real work).
name: rig-ci
on:
  push:
    branches:
      - 'rig/**'
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo "rig ci ok for ${GITHUB_SHA}"
```

- [ ] **Step 2: Create `test-rig/github/up.sh`**

```bash
#!/usr/bin/env bash
#
# Provision the GitHub test target for lightspeed adapter testing:
#   - verify token + repo access
#   - ensure seed status labels exist
#   - ensure .github/workflows/ci.yml exists (for ci watch/log)
#   - write .work/.lightspeed.json + .lightspeed.secrets.json (gitignored)
#
# Token: $LIGHTSPEED_GH_TOKEN, else a gitignored test-rig/github/.env sourced here.
# Never writes the token to a tracked file. Idempotent; safe to re-run.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
API="https://api.github.com"
OWNER="DaveWoodCom"
REPO="LightspeedTestTarget"
WORK="$RIG_DIR/.work"
REPO_API="$API/repos/$OWNER/$REPO"

say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"

# Resolve token.
[ -n "${LIGHTSPEED_GH_TOKEN:-}" ] || { [ -f "$RIG_DIR/.env" ] && . "$RIG_DIR/.env"; }
TOKEN="${LIGHTSPEED_GH_TOKEN:-}"
[ -n "$TOKEN" ] || die "no token — export LIGHTSPEED_GH_TOKEN or put it in test-rig/github/.env (gitignored). Scope: repo + workflow."

H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

say "Verifying token…"
curl -fsS "${H[@]}" "$API/user" >/dev/null || die "token rejected by GET /user"
say "Verifying repo access ($OWNER/$REPO)…"
curl -fsS "${H[@]}" "$REPO_API" >/dev/null || die "cannot access $OWNER/$REPO (check token scope/repo)"

# Seed status labels (idempotent). name|color(bare hex)|description
say "Ensuring seed labels…"
seed_labels=(
  "status/in progress|1d76db|In flight"
  "status/to test|fbca04|Built, awaiting verification"
  "status/in review|0e8a16|In review"
  "status/in qa|5319e7|In QA"
  "rig|ededed|test-rig artifact (safe to delete)"
)
for row in "${seed_labels[@]}"; do
  n="${row%%|*}"; rest="${row#*|}"; c="${rest%%|*}"; d="${rest#*|}"
  if curl -fsS "${H[@]}" "$REPO_API/labels/$(printf '%s' "$n" | jq -sRr @uri)" >/dev/null 2>&1; then
    :
  else
    curl -fsS "${H[@]}" -X POST "$REPO_API/labels" \
      -d "$(jq -n --arg n "$n" --arg c "$c" --arg d "$d" '{name:$n,color:$c,description:$d}')" >/dev/null \
      && say "  created label '$n'"
  fi
done

# Ensure the CI workflow exists on the default branch (idempotent).
say "Ensuring .github/workflows/ci.yml…"
if ! curl -fsS "${H[@]}" "$REPO_API/contents/.github/workflows/ci.yml" >/dev/null 2>&1; then
  content_b64="$(base64 < "$RIG_DIR/workflows/ci.yml" | tr -d '\n')"
  curl -fsS "${H[@]}" -X PUT "$REPO_API/contents/.github/workflows/ci.yml" \
    -d "$(jq -n --arg m "rig: add ci workflow" --arg c "$content_b64" '{message:$m, content:$c}')" >/dev/null \
    && say "  created .github/workflows/ci.yml"
fi

# Write the gitignored workdir config.
say "Writing workdir config…"
mkdir -p "$WORK"
jq -n --arg api "$API" --arg o "$OWNER" --arg r "$REPO" '{
  code: { backend:"github", owner:$o, repo:$r, api:$api,
          stages:[{name:"main", merge:"pr"}] },
  labels: { status: {
    "in-progress":"status/in progress",
    "to-test":"status/to test",
    "in-review":"status/in review",
    "in-qa":"status/in qa"
  } }
}' > "$WORK/.lightspeed.json"
jq -n --arg t "$TOKEN" '{ code: { token:$t } }' > "$WORK/.lightspeed.secrets.json"

say "Up. Workdir: $WORK"
```

- [ ] **Step 3: Create `test-rig/github/README.md`**

```markdown
# lightspeed GitHub test rig

Exercises the GitHub adapter against a **real** repo (`DaveWoodCom/LightspeedTestTarget`).
**Dev tooling — not part of the plugin.** Requires `curl` + `jq` and a token (scope: **repo +
workflow**).

```bash
export LIGHTSPEED_GH_TOKEN=ghp_…   # or put it in test-rig/github/.env (gitignored)
./up.sh        # verify token, seed labels + ci workflow, write .work/ config
./smoke.sh     # exercise every verb against the live repo (marker-tagged), with assertions
./down.sh      # close/delete only rig-tagged artifacts; remove .work/
```

- **Workdir:** `.work/` — gitignored; holds `.lightspeed.json` + `.lightspeed.secrets.json` (token).
- **Markers:** rig artifacts carry a `[rig]` title prefix and the `rig` label. `down.sh` only
  touches those. GitHub REST can't delete issues — rig issues are **closed**, not removed.
- The rig only writes to `rig/*` branches and PRs between them; it never writes to `main`.
```

- [ ] **Step 4: shellcheck**

Run: `shellcheck test-rig/github/up.sh`
Expected: no errors. (Sourcing `.env` is guarded; `jq -sRr @uri` URL-encodes the label name for the GET existence check.)

- [ ] **Step 5: Commit**

```bash
git add test-rig/github/workflows/ci.yml test-rig/github/up.sh test-rig/github/README.md
git commit -m "github rig: up.sh + seeded ci workflow + README

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 7: rig `smoke.sh`

**Files:**
- Create: `test-rig/github/smoke.sh`

- [ ] **Step 1: Create `test-rig/github/smoke.sh`**

```bash
#!/usr/bin/env bash
#
# Exercise the live GitHub adapter verbs against the rig target and assert behavior.
# Requires ./up.sh to have run first. Everything created is marker-tagged ([rig] title
# + 'rig' label) so ./down.sh can clean up exactly its own artifacts.
# shellcheck disable=SC2015  # 'cond && ok || no' is intentional: ok() returns 0.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../lightspeed/scripts/lightspeed"
[ -f "$WORK/.lightspeed.json" ] || { echo "no workdir config — run ./up.sh first" >&2; exit 1; }

API="$(jq -r '.code.api' "$WORK/.lightspeed.json")"
OWNER="$(jq -r '.code.owner' "$WORK/.lightspeed.json")"
REPO="$(jq -r '.code.repo' "$WORK/.lightspeed.json")"
TOKEN="$(jq -r '.code.token' "$WORK/.lightspeed.secrets.json")"
REPO_API="$API/repos/$OWNER/$REPO"
H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
TS="$(date -u +%Y%m%d%H%M%S)"

lsp() { ( cd "$WORK" && "$DISP" "$@" ); }
pass=0; fail=0
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1)); }
no() { printf '\033[31m  ✗ %s\033[0m  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "── issues create / list / get ──"
N="$(lsp issues create --title "[rig] smoke $TS" --body "hello body" --label rig)"
[[ "$N" =~ ^[0-9]+$ ]] && ok "create returns numeric id ($N)" || no "create returns numeric id" "got '$N'"

OUT="$(lsp issues list)"
grep -q "\[rig\] smoke $TS" <<<"$OUT" && ok "list shows the new issue" || no "list shows the new issue"
cols="$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')"
[ "$cols" = 3 ] && ok "list rows are 3-col TSV" || no "list rows are 3-col TSV" "got $cols cols"

GET="$(lsp issues get --number "$N")"
grep -q "\[rig\] smoke $TS" <<<"$GET" && ok "get returns title line" || no "get returns title line"
grep -q "hello body" <<<"$GET" && ok "get returns body" || no "get returns body"

echo "── labels resolve ──"
id="$(lsp labels resolve --name "status/to test" | awk -F'\t' '{print $2}')"
[[ "$id" =~ ^[0-9]+$ ]] && ok "resolve returns name⇥id ($id)" || no "resolve returns name⇥id" "got '$id'"
empty="$(lsp labels resolve --name "no-such-label" | awk -F'\t' '{print $2}')"
[ -z "$empty" ] && ok "unknown label resolves to empty id" || no "unknown label resolves to empty id" "got '$empty'"

echo "── set-status (single-status invariant) ──"
lsp issues set-status --number "$N" --status in-progress
lsp issues set-status --number "$N" --status to-test
LBLS="$(curl -fsS "${H[@]}" "$REPO_API/issues/$N" | jq -r '[.labels[].name] | map(select(startswith("status/"))) | sort | join(",")')"
[ "$LBLS" = "status/to test" ] && ok "only the latest status label remains ($LBLS)" \
  || no "only the latest status label remains" "got '$LBLS'"

echo "── comment / close ──"
lsp issues comment --number "$N" --body "rig comment" && ok "comment exits 0" || no "comment exits 0"
lsp issues close --number "$N" && ok "close exits 0" || no "close exits 0"

echo "── pr open / merge (rig branches off main; main untouched) ──"
MAIN_SHA="$(curl -fsS "${H[@]}" "$REPO_API/git/ref/heads/main" | jq -r '.object.sha')"
BASE="rig/$TS-base"; HEAD="rig/$TS-head"
for b in "$BASE" "$HEAD"; do
  curl -fsS "${H[@]}" -X POST "$REPO_API/git/refs" \
    -d "$(jq -n --arg r "refs/heads/$b" --arg s "$MAIN_SHA" '{ref:$r, sha:$s}')" >/dev/null
done
# One commit on HEAD via contents API (also triggers the rig/** workflow).
curl -fsS "${H[@]}" -X PUT "$REPO_API/contents/rig-$TS.txt" \
  -d "$(jq -n --arg m "[rig] commit $TS" --arg c "$(printf 'rig %s' "$TS" | base64 | tr -d '\n')" --arg b "$HEAD" \
        '{message:$m, content:$c, branch:$b}')" >/dev/null
HEAD_SHA="$(curl -fsS "${H[@]}" "$REPO_API/git/ref/heads/$HEAD" | jq -r '.object.sha')"
PR="$(lsp pr open --head "$HEAD" --base "$BASE" --title "[rig] pr $TS" --body "rig pr")"
prnum="$(awk -F'\t' '{print $1}' <<<"$PR")"
[[ "$prnum" =~ ^[0-9]+$ ]] && ok "pr open returns number⇥url ($prnum)" || no "pr open returns number⇥url" "got '$PR'"
lsp pr merge --number "$prnum" --strategy squash && ok "pr merge exits 0" || no "pr merge exits 0"

echo "── ci watch (the seeded workflow on the rig push) ──"
LINES="$(timeout 180 bash -c "cd '$WORK' && '$DISP' ci watch --sha '$HEAD_SHA'" || true)"
grep -qE "task-[0-9]+ status=" <<<"$LINES" && ok "ci watch streams task status lines" || no "ci watch streams task status lines" "$LINES"
grep -q "status=completed" <<<"$LINES" && ok "ci watch reaches completed" || no "ci watch reaches completed (may time out if Actions slow)" "$LINES"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck test-rig/github/smoke.sh`
Expected: no errors (the `SC2015` disable is declared for the intentional `cond && ok || no` idiom).

- [ ] **Step 3: Commit**

```bash
git add test-rig/github/smoke.sh
git commit -m "github rig: smoke.sh (marker-tagged, every verb incl. pr + ci watch)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 8: rig `down.sh`

**Files:**
- Create: `test-rig/github/down.sh`

- [ ] **Step 1: Create `test-rig/github/down.sh`**

```bash
#!/usr/bin/env bash
#
# Surgical, marker-only teardown of GitHub rig artifacts. Touches ONLY:
#   - issues carrying the 'rig' label  -> closed (GitHub REST can't delete issues)
#   - open PRs whose title starts '[rig]' -> closed
#   - branches named rig/*             -> deleted
# Leaves seed labels + the ci workflow in place (up.sh re-ensures them). Removes .work/.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }

if [ -f "$WORK/.lightspeed.json" ]; then
  API="$(jq -r '.code.api' "$WORK/.lightspeed.json")"
  OWNER="$(jq -r '.code.owner' "$WORK/.lightspeed.json")"
  REPO="$(jq -r '.code.repo' "$WORK/.lightspeed.json")"
  TOKEN="$(jq -r '.code.token' "$WORK/.lightspeed.secrets.json" 2>/dev/null || echo "")"
  REPO_API="$API/repos/$OWNER/$REPO"
  H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

  if [ -n "$TOKEN" ]; then
    say "Closing open PRs titled '[rig]…'…"
    for p in $(curl -fsS "${H[@]}" "$REPO_API/pulls?state=open&per_page=100" \
                 | jq -r '.[] | select(.title | startswith("[rig]")) | .number'); do
      curl -fsS "${H[@]}" -X PATCH "$REPO_API/pulls/$p" -d '{"state":"closed"}' >/dev/null && say "  closed PR #$p"
    done

    say "Closing open issues labelled 'rig'…"
    for i in $(curl -fsS "${H[@]}" "$REPO_API/issues?state=open&labels=rig&per_page=100" \
                 | jq -r '.[] | select(.pull_request | not) | .number'); do
      curl -fsS "${H[@]}" -X PATCH "$REPO_API/issues/$i" -d '{"state":"closed"}' >/dev/null && say "  closed issue #$i"
    done

    say "Deleting rig/* branches…"
    for ref in $(curl -fsS "${H[@]}" "$REPO_API/git/matching-refs/heads/rig/" | jq -r '.[].ref'); do
      curl -fsS "${H[@]}" -X DELETE "$REPO_API/git/${ref}" >/dev/null && say "  deleted ${ref#refs/}"
    done
  fi
fi

rm -rf "$WORK"
printf '\033[32m✓ Rig torn down (rig issues/PRs closed, rig/* branches deleted, .work/ removed).\033[0m\n'
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck test-rig/github/down.sh`
Expected: no errors. (The unquoted `$(curl … | jq -r …)` in `for` loops is intentional word-splitting over numeric ids / ref names; if shellcheck flags SC2046, leave it — these are whitespace-free tokens — or add a `# shellcheck disable=SC2046` above each loop.)

- [ ] **Step 3: Commit**

```bash
git add test-rig/github/down.sh
git commit -m "github rig: down.sh (marker-only surgical cleanup)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 9: Live rig run (gated verification — no commit)

Functional verification of every verb against the real repo. **Requires `$LIGHTSPEED_GH_TOKEN`
staged** (scope: repo + workflow). If the token is not available in the execution environment, run
the shellcheck sweep in Step 1, then STOP and report that the live run is deferred to the user.

**Files:** (none — verification only)

- [ ] **Step 1: Static sweep**

Run: `shellcheck -x lightspeed/scripts/adapters/github/* && shellcheck test-rig/github/*.sh && echo OK`
Expected: `OK` (all adapter + rig scripts clean).

- [ ] **Step 2: Up + smoke + down (only if token available)**

```bash
cd test-rig/github
./up.sh && ./smoke.sh; rc=$?
./down.sh
cd - >/dev/null
echo "smoke rc=$rc"
```
Expected: `up.sh` provisions labels + workflow + workdir; `smoke.sh` prints `passed=N failed=0`
(the `ci watch reaches completed` line may warn if Actions is slow — that's a soft check, not a
hard failure); `down.sh` closes rig issues/PRs and deletes `rig/*` branches. Record the observed
`passed/failed` counts in the task hand-off. Confirm the main repo `git status` is clean (the rig
writes only into gitignored `.work/`).

- [ ] **Step 3: Report** — no commit. Note pass/fail counts and any soft `ci` timeout.

---

## Phase 4 — docs

### Task 10: Document the GitHub backend

**Files:**
- Modify: `lightspeed/references/adapter-contract.md`
- Modify: `lightspeed/references/lightspeed-setup.md`

- [ ] **Step 1: Note GitHub specifics in `adapter-contract.md`**

Under the `## Notes` section, add:

```markdown
- **GitHub backend specifics:** GitHub label endpoints use label **names**, not numeric ids — the
  github adapter resolves and applies labels by name internally (skills are unchanged). `issues
  attach` is **not supported** on GitHub (no REST API for issue attachments) and exits non-zero
  with that reason. `issues list` filters out pull requests (GitHub returns PRs from the issues
  endpoint). `pr merge` maps `--strategy` to GitHub's `merge_method`. `ci log` streams per-job
  logs (`/actions/jobs/{id}/logs`) rather than the run-level zip.
```

- [ ] **Step 2: Add a GitHub config example in `lightspeed-setup.md`**

Near the backend/coordinates documentation, add:

```markdown
### GitHub backend

Point an axis at GitHub by setting its `backend` + `api` in `.lightspeed.json`:

```jsonc
"code": {
  "backend": "github",
  "owner": "your-org-or-user",
  "repo": "your-repo",
  "api": "https://api.github.com",          // note: no /api/v1 (that's Forgejo)
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

The token goes in the gitignored `.lightspeed.secrets.json` (`code.token`), a GitHub PAT with
**repo** scope (+ **workflow** if you use `ci`). `bootstrapping-labels` does not yet offer GitHub
as a backend choice — configure GitHub repos by hand-editing `.lightspeed.json` for now.
```

- [ ] **Step 3: Verify references**

Run: `grep -nE 'GitHub backend|api\.github\.com|attach.*not supported|merge_method' lightspeed/references/adapter-contract.md lightspeed/references/lightspeed-setup.md`
Expected: matches in both files for the GitHub note and the config example.

- [ ] **Step 4: Commit**

```bash
git add lightspeed/references/adapter-contract.md lightspeed/references/lightspeed-setup.md
git commit -m "docs: GitHub backend (adapter-contract notes + setup config example)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done when

- `lightspeed/scripts/adapters/github/{_common.sh,issues,labels,pr,ci}` exist, shellcheck-clean,
  executable; every verb mirrors the contract with GitHub specifics absorbed inside.
- `test-rig/github/{up.sh,smoke.sh,down.sh,workflows/ci.yml,README.md}` exist, shellcheck-clean.
- Live rig run (Task 9) observed `failed=0` (or deferred to the user with a clear note if no token).
- Docs updated. Ready to merge `feature/github-adapter` → `develop` via
  `finishing-a-development-branch`.
```
