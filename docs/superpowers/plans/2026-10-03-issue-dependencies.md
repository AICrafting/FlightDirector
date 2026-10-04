# Issue Dependencies ("blocked by") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `flight issues block|unblock|blockers|blocking`, which record, remove and read "this issue is blocked by that one". They use each backend's native relationship where it exists (GitHub, Forgejo, GitLab Premium, Jira), fall back to signed marker comments where it doesn't (and always across trackers), and move the blocked issue's status unless told not to. Add `blocked_by` to `issues get --json`, and teach three skills to use it.

**Architecture:** Each backend adapter's `issues` script gains four native verbs (`dep-add`, `dep-remove`, `dep-list`, `dep-blocking`) that work on one tracker and fail with a new `unsupported` error code when the backend can't. A new dispatcher-owned helper, `flight/scripts/issue-deps`, owns the user-facing verbs. Like `issue-copy`, it does every read and write back through the dispatcher (`$FLIGHT_SELF … --json`), tries native first, falls back to text comments, and handles status. The dispatcher routes the four verbs to it, adds a `--signature` switch (forces the signature on), and fills `blocked_by` on `issues get --json`.

**Tech Stack:** bash (`set -euo pipefail`), jq, curl in the adapters, the repo's bash test style (`scripts/tests/*.test.sh` with `check`/`section`), shellcheck through `scripts/run-checks.sh`.

**Spec:** `docs/superpowers/specs/2026-10-03-issue-dependencies-design.md`

## Global Constraints

- **Worktree:** all work happens in `.worktrees/fj-271-issue-dependencies` on `feature/fj-271-issue-dependencies`. Every git command is `git -C "$WT" …` with `WT=/home/dave/Documents/Projects/CurrentProjects/AICrafting/flightdirector/Repos/flightdirector/.worktrees/fj-271-issue-dependencies`. Never commit to `develop`.
- **Style:** tabs in new scripts and tests. The adapters' `issues` scripts use two-space indentation; match it there. No trailing whitespace except in `.md`. Exactly one final newline. Kebab-case file names. Tracked scripts carry the exec bit: after creating one, run `git -C "$WT" update-index --chmod=+x <path>` and confirm `git -C "$WT" ls-files -s <path>` shows `100755`.
- **Commits:** scopes `feat(FJ-271): …`, `test(FJ-271): …`, `docs(FJ-271): …`. End every message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Text record (verbatim from the spec):** blocked side `**Blocked by <Q>**: <title>` and `**No longer blocked by <Q>**`; mirror side `**Blocks <Q>**: <title>` and `**No longer blocks <Q>**`. Ids are always **qualified** (`FJ-12`). A comment counts only when it is flight-signed **and** its first line matches `^(\*\*)?(Blocked by|No longer blocked by|Blocks|No longer blocks) ([A-Za-z][A-Za-z0-9]*-[0-9]+)(\*\*)?(:.*)?$`. The latest one per pair wins.
- **Status (verbatim from the spec):** on by default; `--no-status` skips it. `block` sets the `blocked` role and records `(was <role>)`, using `none` when the issue had no status. `unblock` restores only when no blockers remain **and** the issue still carries `blocked`: the latest `(was <role>)`, else `new`, else `clear-status`. A tracker without a `blocked` role skips status with a stderr note.
- **Native-call failures** other than `unsupported` stop the verb. They never fall back to text.
- **Forbidden words:** never mention the two unrelated project/company names listed in `AGENTS.local.md`.
- **No new runtime dependencies:** bash + jq + curl only.
- **Verification gate:** before calling the work done, `./scripts/run-checks.sh && ./scripts/run-tests.sh` must pass from `$WT` (this repo's `code.preflight`).

## Review Focus

1. **Comment bodies with a CRLF first line** (GitHub's web editor writes CRLF): the marker must still be read. Pinned in Task 3 (the `crlf` fixture comment).
2. **Ids in another case** (`--by gh-3`, or a marker someone edited to `fj-12`): they must match the canonical `GH-3` / `FJ-12`. Pinned in Task 3 (`--by gh-1` and the lowercase-marker test).
3. **A marker comment whose blocker issue was deleted:** `blockers` must still list the id, with a null title, instead of failing the whole verb. Pinned in Task 3 (the `FJ-404` test).
4. **A blocked-side comment posted but the mirror failed** (network drop): rerunning `block` must post only the missing mirror. Pinned in Task 3 (`FAIL_COMMENT_ON`).
5. **`issues get --json` when the blockers lookup fails** (a 500 from the backend): `get` still succeeds, with `blocked_by: null` and a stderr warning. Pinned in Task 4.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `flight/scripts/adapters/_errors.sh` | modify | Document the `unsupported` code |
| `flight/scripts/adapters/_json.sh` | modify | `dep_emit`: rows → TSV, or the JSON array under `--json` |
| `flight/scripts/adapters/forgejo/issues` | modify | `dep-*` verbs via `/dependencies` and `/blocks`; repo setting check |
| `flight/scripts/adapters/github/issues` | modify | `dep-*` verbs via `/dependencies/blocked_by` and `/blocking`; database-id lookup |
| `flight/scripts/adapters/gitlab/_common.sh` | modify | `_api_try`: a call whose HTTP error the caller judges |
| `flight/scripts/adapters/gitlab/issues` | modify | `dep-*` verbs via issue links; tier refusal → `unsupported` |
| `flight/scripts/adapters/jira/issues` | modify | `dep-*` verbs via issue links; link type by inward text |
| `scripts/tests/issue-deps-adapters.test.sh` | create | Fake-curl tests for all four adapters |
| `flight/scripts/issue-deps` | create | `block`, `unblock`, `blockers`, `blocking`: native first, text fallback, mirror, status |
| `flight/scripts/flight` | modify | Route the four verbs; `--signature`; JSON verbs; schema gate; capability token; `blocked_by` on `get --json` |
| `flight/scripts/issue-json.jq` | modify | `blocked_by: null` on every finished issue object |
| `scripts/tests/issue-deps.test.sh` | create | Helper tests against a stub dispatcher, plus routing and `get --json` through the real one |
| `scripts/tests/issues-json.test.sh` | modify | The issue key set gains `blocked_by` |
| `flight/skills/working-an-issue/SKILL.md`, `flight/skills/triaging-issues/SKILL.md`, `flight/skills/filing-issues/SKILL.md` | modify | Blocker checks and the `issues block` pointer |
| `scripts/tests/tracker-lifecycle-skills.test.sh` | modify | Pin the new skill lines |
| `flight/references/adapter-contract.md`, `flight/references/json-output.md`, `flight/GUIDE.md`, `flight/CHANGELOG.md` | modify | Docs |
| `test-rig/{forgejo,github,gitlab,jira}/smoke.sh` | modify | Live block → blockers → blocking → unblock round trip |

---

### Task 1: Native verbs on Forgejo and GitHub, plus the shared pieces

**Files:**
- Modify: `flight/scripts/adapters/_errors.sh` (code list in the header comment)
- Modify: `flight/scripts/adapters/_json.sh` (append `dep_emit`)
- Modify: `flight/scripts/adapters/forgejo/issues` (new case before `*)`; header verb list; the `*)` usage line)
- Modify: `flight/scripts/adapters/github/issues` (same three places)
- Create: `scripts/tests/issue-deps-adapters.test.sh`

**Interfaces:**
- Produces, for every adapter (Tasks 1–2), invoked as `issues <verb>` with native ids:
  - `dep-add --number N --by M` → no stdout. Idempotent.
  - `dep-remove --number N --by M` → no stdout. Idempotent.
  - `dep-list --number N` → TSV `number⇥title⇥state` per blocker; under `LS_JSON=1` a JSON array `[{number, title, state}]` (`number` is a string, `state` is `open|closed`).
  - `dep-blocking --number N` → the same shape, for the issues N blocks.
  - On a backend that can't: exit 1 with `fail unsupported "<reason>"` (the code reaches `FLIGHT_ERROR_FILE`).
- Produces in `_json.sh`: `dep_emit` (reads one JSON array on stdin).

- [ ] **Step 1: Write the failing adapter tests**

Create `scripts/tests/issue-deps-adapters.test.sh`:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# The adapters' native dependency verbs (FJ-271): dep-add, dep-remove, dep-list, dep-blocking.
# The network is a fake `curl` that answers from a route table and logs every request, so each
# test can say both what the adapter printed and what it sent.
# Contract: flight/references/adapter-contract.md (issues → dep-*).
set -euo pipefail

unset LS_JSON FLIGHT_ERROR_FILE
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTERS="$REPO_ROOT/flight/scripts/adapters"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

mkdir -p "$SANDBOX/bin" "$SANDBOX/bodies"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl. Routes: lines of METHOD<TAB>URL-REGEX<TAB>STATUS<TAB>BODY-FILE in $ROUTES, first
# match wins. Every request is logged to $CURL_LOG as "METHOD URL DATA".
set -euo pipefail
out=""; method=GET; data=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-X) method="$2"; shift 2 ;;
		--data-binary) data="$2"; shift 2 ;;
		-D|-w|-H|-u) shift 2 ;;
		-sS|-L) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s %s %s\n' "$method" "$url" "$data" >>"${CURL_LOG:?}"
while IFS=$'\t' read -r m re code body; do
	[ "$m" = "$method" ] || continue
	[[ "$url" =~ $re ]] || continue
	cat "$body" >"$out"; printf '%s' "$code"; exit 0
done <"${ROUTES:?}"
printf '{"message":"no route for %s %s"}' "$method" "$url" >"$out"; printf '404'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t LS_PROJECT=ACME LS_EMAIL=a@b.c
export ROUTES="$SANDBOX/routes" CURL_LOG="$SANDBOX/curl.log"

body_n=0
# route METHOD URL-REGEX STATUS JSON — add one answer to the table.
route() {
	body_n=$((body_n + 1))
	printf '%s' "$4" >"$SANDBOX/bodies/$body_n"
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$SANDBOX/bodies/$body_n" >>"$ROUTES"
}
reset() { : >"$ROUTES"; : >"$CURL_LOG"; }
# run ADAPTER VERB ARGS… — stdout of the adapter; its exit status is in $RC and its error
# envelope (if any) in $SANDBOX/err.json.
run() {
	local a="$1"; shift
	rm -f "$SANDBOX/err.json"; RC=0
	OUT="$(FLIGHT_ERROR_FILE="$SANDBOX/err.json" "$ADAPTERS/$a/issues" "$@" 2>/dev/null)" || RC=$?
}
code() { jq -r '.error.code // empty' "$SANDBOX/err.json" 2>/dev/null || true; }
sent() { grep -c -F -- "$1" "$CURL_LOG" || true; }

section "forgejo"
reset
route GET '/repos/o/r$' 200 '{"internal_tracker":{"enable_issue_dependencies":false}}'
run forgejo dep-list --number 5
check "dependencies switched off → unsupported" "$([ "$RC" = 1 ] && [ "$(code)" = unsupported ] && echo 1 || echo 0)" "rc=$RC code=$(code)"

reset
route GET '/repos/o/r$' 200 '{"internal_tracker":{"enable_issue_dependencies":true}}'
route GET '/issues/5/dependencies' 200 '[{"number":7,"title":"Seven","state":"open","repository":{"owner":"o","name":"r"}},{"number":9,"title":"Elsewhere","state":"open","repository":{"owner":"other","name":"r"}}]'
route GET '/issues/5/blocks' 200 '[{"number":11,"title":"Eleven","state":"closed","repository":{"owner":"O","name":"R"}}]'
run forgejo dep-list --number 5
check "dep-list: this repo's blockers only, as TSV" "$([ "$OUT" = "$(printf '7\tSeven\topen')" ] && echo 1 || echo 0)" "$OUT"
run forgejo dep-blocking --number 5
check "dep-blocking reads /blocks; owner/repo match ignores case" "$([ "$OUT" = "$(printf '11\tEleven\tclosed')" ] && echo 1 || echo 0)" "$OUT"
OUT="$(LS_JSON=1 "$ADAPTERS/forgejo/issues" dep-list --number 5)"
check "dep-list --json is an array of {number,title,state}" "$(jq -e '. == [{"number":"7","title":"Seven","state":"open"}]' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "$OUT"

: >"$CURL_LOG"
route POST '/issues/5/dependencies' 201 '{}'
run forgejo dep-add --number 5 --by 8
check "dep-add posts {owner, repo, index}" "$([ "$RC" = 0 ] && [ "$(sent 'POST https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies {"owner":"o","repo":"r","index":8}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run forgejo dep-add --number 5 --by 7
check "dep-add of an existing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent POST)" = 0 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
route DELETE '/issues/5/dependencies' 200 '{}'
run forgejo dep-remove --number 5 --by 7
check "dep-remove sends DELETE with the same body" "$([ "$(sent 'DELETE https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies {"owner":"o","repo":"r","index":7}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run forgejo dep-remove --number 5 --by 8
check "dep-remove of a missing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent DELETE)" = 0 ] && echo 1 || echo 0)"
run forgejo dep-add --number 5 --by abc
check "a non-numeric --by is a usage error" "$([ "$RC" = 1 ] && [ "$(code)" = usage ] && echo 1 || echo 0)"

section "github"
reset
route GET '/issues/5/dependencies/blocked_by' 200 '[{"number":7,"title":"Seven","state":"closed","repository_url":"https://api.github.com/repos/O/R"},{"number":9,"title":"Elsewhere","state":"open","repository_url":"https://api.github.com/repos/x/y"}]'
route GET '/issues/5/dependencies/blocking' 200 '[{"number":12,"title":"Twelve","state":"open","repository_url":"https://api.github.com/repos/o/r"}]'
route GET '/issues/8$' 200 '{"id":4242,"number":8}'
route GET '/issues/7$' 200 '{"id":4141,"number":7}'
route POST '/issues/5/dependencies/blocked_by' 201 '{}'
route DELETE '/issues/5/dependencies/blocked_by/4141' 200 '{}'
run github dep-list --number 5
check "dep-list: this repo's blockers only" "$([ "$OUT" = "$(printf '7\tSeven\tclosed')" ] && echo 1 || echo 0)" "$OUT"
run github dep-blocking --number 5
check "dep-blocking reads /dependencies/blocking" "$([ "$OUT" = "$(printf '12\tTwelve\topen')" ] && echo 1 || echo 0)" "$OUT"
: >"$CURL_LOG"
run github dep-add --number 5 --by 8
check "dep-add posts the blocker's database id" "$([ "$(sent 'POST https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies/blocked_by {"issue_id":4242}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run github dep-add --number 5 --by 7
check "dep-add of an existing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent POST)" = 0 ] && echo 1 || echo 0)"
: >"$CURL_LOG"
run github dep-remove --number 5 --by 7
check "dep-remove deletes by database id" "$([ "$(sent 'DELETE https://forge.invalid/api/v1/repos/o/r/issues/5/dependencies/blocked_by/4141')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then: `git -C "$WT" add scripts/tests/issue-deps-adapters.test.sh && git -C "$WT" update-index --chmod=+x scripts/tests/issue-deps-adapters.test.sh`.

- [ ] **Step 2: Run it and watch it fail**

Run: `bash scripts/tests/issue-deps-adapters.test.sh`
Expected: every check fails ("unknown verb 'dep-list'"), and the script exits 1.

- [ ] **Step 3: Add the shared pieces**

In `flight/scripts/adapters/_errors.sh`, add one line to the code list in the header comment, after `backend`:

```bash
#   unsupported     the backend cannot do this here (a feature switched off, or not in its tier)
```

Append to `flight/scripts/adapters/_json.sh`:

```bash

# dep_emit — one JSON array of {number, title, state} on stdin (FJ-271's dep-list and
# dep-blocking) → one `number⇥title⇥state` row each, or the array unchanged under --json.
dep_emit() {
	if json_mode; then jq -c '.'
	else jq -r '.[] | [.number, .title, .state] | @tsv'
	fi
}
```

- [ ] **Step 4: Forgejo verbs**

In `flight/scripts/adapters/forgejo/issues`, insert before the final `  *) die "unknown verb …` case:

```bash
  dep-add|dep-remove|dep-list|dep-blocking)
    # Issue dependencies (FJ-271): "N is blocked by M", both issues in this repo. A repo with
    # dependencies switched off answers these endpoints with 404, which would read as a missing
    # issue, so the repo setting is checked first and reported as `unsupported`.
    number=""; by=""
    while [ $# -gt 0 ]; do case "$1" in
      --number) number="$2"; shift 2 ;;
      --by) by="$2"; shift 2 ;;
      *) die "issues $verb: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "issues $verb: --number required"
    case "$verb" in
      dep-add|dep-remove)
        case "$by" in ''|*[!0-9]*) die "issues $verb: --by needs an issue number" ;; esac ;;
    esac
    enabled="$(_api GET "" | jq -r '.internal_tracker.enable_issue_dependencies // false')"
    [ "$enabled" = true ] || fail unsupported "issue dependencies are switched off for ${LS_OWNER}/${LS_REPO}"
    # Only links whose other end is in this repo: the caller names issues by this tracker. One
    # page of 50 is enough; an issue with more blockers than that is not worth paging for.
    same_repo='[.[] | select((.repository.owner // "" | ascii_downcase) == ($o | ascii_downcase)
        and (.repository.name // "" | ascii_downcase) == ($r | ascii_downcase))
      | {number: (.number | tostring), title: (.title // ""),
         state: (if .state == "closed" then "closed" else "open" end)}]'
    case "$verb" in
      dep-list|dep-blocking)
        path=dependencies; [ "$verb" = dep-blocking ] && path=blocks
        _api GET "/issues/${number}/${path}?limit=50" \
          | jq -c --arg o "$LS_OWNER" --arg r "$LS_REPO" "$same_repo" | dep_emit
        ;;
      *)
        linked="$(_api GET "/issues/${number}/dependencies?limit=50" \
          | jq -r --arg o "$LS_OWNER" --arg r "$LS_REPO" --arg b "$by" "$same_repo"' | map(select(.number == $b)) | length')"
        if [ "$verb" = dep-add ] && [ "$linked" != 0 ]; then exit 0; fi
        if [ "$verb" = dep-remove ] && [ "$linked" = 0 ]; then exit 0; fi
        method=POST; [ "$verb" = dep-remove ] && method=DELETE
        _api "$method" "/issues/${number}/dependencies" \
          "$(jq -cn --arg o "$LS_OWNER" --arg r "$LS_REPO" --argjson i "$by" '{owner: $o, repo: $r, index: $i}')" >/dev/null
        ;;
    esac
    ;;

```

Then add ` dep-add dep-remove dep-list dep-blocking` to the end of the verb list in the header comment (line 3), and to the `(issues: …)` list in the `*)` usage message.

- [ ] **Step 5: GitHub verbs**

In `flight/scripts/adapters/github/issues`, insert before the final `  *) die …` case:

```bash
  dep-add|dep-remove|dep-list|dep-blocking)
    # Issue dependencies (FJ-271): "N is blocked by M", both issues in this repo. GitHub's POST
    # and DELETE name the blocker by its database id, not its number.
    number=""; by=""
    while [ $# -gt 0 ]; do case "$1" in
      --number) number="$2"; shift 2 ;;
      --by) by="$2"; shift 2 ;;
      *) die "issues $verb: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "issues $verb: --number required"
    case "$verb" in
      dep-add|dep-remove)
        case "$by" in ''|*[!0-9]*) die "issues $verb: --by needs an issue number" ;; esac ;;
    esac
    # Only links whose other end is in this repo: the caller names issues by this tracker.
    same_repo='[.[] | select((.repository_url // "" | ascii_downcase)
        | endswith(("/repos/" + $o + "/" + $r) | ascii_downcase))
      | {number: (.number | tostring), title: (.title // ""),
         state: (if .state == "closed" then "closed" else "open" end)}]'
    case "$verb" in
      dep-list|dep-blocking)
        path=blocked_by; [ "$verb" = dep-blocking ] && path=blocking
        _api GET "/issues/${number}/dependencies/${path}?per_page=100" \
          | jq -c --arg o "$LS_OWNER" --arg r "$LS_REPO" "$same_repo" | dep_emit
        ;;
      *)
        linked="$(_api GET "/issues/${number}/dependencies/blocked_by?per_page=100" \
          | jq -r --arg o "$LS_OWNER" --arg r "$LS_REPO" --arg b "$by" "$same_repo"' | map(select(.number == $b)) | length')"
        if [ "$verb" = dep-add ] && [ "$linked" != 0 ]; then exit 0; fi
        if [ "$verb" = dep-remove ] && [ "$linked" = 0 ]; then exit 0; fi
        blocker_id="$(_api GET "/issues/${by}" | jq -r '.id')"
        if [ "$verb" = dep-add ]; then
          _api POST "/issues/${number}/dependencies/blocked_by" "$(jq -cn --argjson i "$blocker_id" '{issue_id: $i}')" >/dev/null
        else
          _api DELETE "/issues/${number}/dependencies/blocked_by/${blocker_id}" >/dev/null
        fi
        ;;
    esac
    ;;

```

Add the four verbs to the header list and the `*)` usage message, as for Forgejo.

- [ ] **Step 6: Run the tests and watch them pass**

Run: `bash scripts/tests/issue-deps-adapters.test.sh`
Expected: every check passes; `Passed: 14  Failed: 0`.

Run: `bash scripts/tests/lint.test.sh && shellcheck flight/scripts/adapters/forgejo/issues flight/scripts/adapters/github/issues flight/scripts/adapters/_json.sh scripts/tests/issue-deps-adapters.test.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add flight/scripts/adapters/_errors.sh flight/scripts/adapters/_json.sh flight/scripts/adapters/forgejo/issues flight/scripts/adapters/github/issues scripts/tests/issue-deps-adapters.test.sh
git -C "$WT" commit -m "feat(FJ-271): native dependency verbs on Forgejo and GitHub

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Native verbs on GitLab and Jira

**Files:**
- Modify: `flight/scripts/adapters/gitlab/_common.sh` (add `_api_try` after `_api`)
- Modify: `flight/scripts/adapters/gitlab/issues` (new case; header list; usage line)
- Modify: `flight/scripts/adapters/jira/issues` (new case; header list; usage line)
- Modify: `scripts/tests/issue-deps-adapters.test.sh` (two sections before the summary)

**Interfaces:**
- Consumes: `dep_emit` (Task 1), `fail unsupported` (Task 1).
- Produces: the same four verbs as Task 1, with the same output shapes. Jira's `number` values are issue keys (`ACME-7`).

- [ ] **Step 1: Write the failing tests**

Insert before the summary block of `scripts/tests/issue-deps-adapters.test.sh`:

```bash
section "gitlab"
reset
route GET '/projects/o%2Fr$' 200 '{"id":77}'
route GET '/issues/5/links$' 200 '[{"iid":7,"title":"Seven","state":"opened","project_id":77,"link_type":"is_blocked_by","issue_link_id":301},{"iid":8,"title":"Related","state":"opened","project_id":77,"link_type":"relates_to","issue_link_id":302},{"iid":9,"title":"Other project","state":"opened","project_id":12,"link_type":"is_blocked_by","issue_link_id":303},{"iid":10,"title":"Ten","state":"closed","project_id":77,"link_type":"blocks","issue_link_id":304}]'
run gitlab dep-list --number 5
check "dep-list: is_blocked_by links in this project only, opened → open" "$([ "$OUT" = "$(printf '7\tSeven\topen')" ] && echo 1 || echo 0)" "$OUT"
run gitlab dep-blocking --number 5
check "dep-blocking: blocks links" "$([ "$OUT" = "$(printf '10\tTen\tclosed')" ] && echo 1 || echo 0)" "$OUT"
: >"$CURL_LOG"
route POST '/issues/5/links$' 201 '{}'
run gitlab dep-add --number 5 --by 11
check "dep-add posts an is_blocked_by link" "$([ "$RC" = 0 ] && [ "$(sent '{"target_project_id":77,"target_issue_iid":"11","link_type":"is_blocked_by"}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run gitlab dep-add --number 5 --by 7
check "dep-add of an existing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent POST)" = 0 ] && echo 1 || echo 0)"
: >"$CURL_LOG"
route DELETE '/issues/5/links/301$' 200 '{}'
run gitlab dep-remove --number 5 --by 7
check "dep-remove deletes the link by its id" "$([ "$(sent 'DELETE https://forge.invalid/api/v1/projects/o%2Fr/issues/5/links/301')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
reset
route GET '/projects/o%2Fr$' 200 '{"id":77}'
route GET '/issues/5/links$' 200 '[]'
route POST '/issues/5/links$' 403 '{"message":"403 Forbidden"}'
run gitlab dep-add --number 5 --by 11
check "a refused blocking link (Free tier) → unsupported" "$([ "$RC" = 1 ] && [ "$(code)" = unsupported ] && echo 1 || echo 0)" "rc=$RC code=$(code)"
reset
route GET '/projects/o%2Fr$' 200 '{"id":77}'
route GET '/issues/5/links$' 200 '[]'
route POST '/issues/5/links$' 500 '{"message":"boom"}'
run gitlab dep-add --number 5 --by 11
check "any other error stays a backend error" "$([ "$RC" = 1 ] && [ "$(code)" = backend ] && echo 1 || echo 0)" "rc=$RC code=$(code)"

section "jira"
LINKS='{"key":"ACME-5","fields":{"issuelinks":[
	{"id":"501","type":{"id":"10000"},"inwardIssue":{"key":"ACME-7","fields":{"summary":"Seven","status":{"statusCategory":{"key":"new"}}}}},
	{"id":"502","type":{"id":"10000"},"outwardIssue":{"key":"ACME-9","fields":{"summary":"Nine","status":{"statusCategory":{"key":"done"}}}}},
	{"id":"503","type":{"id":"10000"},"inwardIssue":{"key":"OTHER-1","fields":{"summary":"Elsewhere","status":{"statusCategory":{"key":"new"}}}}},
	{"id":"504","type":{"id":"10001"},"inwardIssue":{"key":"ACME-8","fields":{"summary":"Clone","status":{"statusCategory":{"key":"new"}}}}}]}}'
reset
route GET '/rest/api/3/issueLinkType$' 200 '{"issueLinkTypes":[{"id":"10001","name":"Cloners","inward":"is cloned by","outward":"clones"},{"id":"10000","name":"Depends","inward":"Is Blocked By","outward":"blocks"}]}'
route GET '/rest/api/3/issue/ACME-5' 200 "$LINKS"
route POST '/rest/api/3/issueLink$' 201 ''
route DELETE '/rest/api/3/issueLink/501$' 204 ''
run jira dep-list --number ACME-5
check "dep-list: inward links of the renamed type, this project only" "$([ "$OUT" = "$(printf 'ACME-7\tSeven\topen')" ] && echo 1 || echo 0)" "$OUT"
run jira dep-blocking --number ACME-5
check "dep-blocking: outward links, done → closed" "$([ "$OUT" = "$(printf 'ACME-9\tNine\tclosed')" ] && echo 1 || echo 0)" "$OUT"
: >"$CURL_LOG"
run jira dep-add --number ACME-5 --by ACME-6
check "dep-add: the blocker is the inward issue, the type by id" "$([ "$(sent '{"type":{"id":"10000"},"inwardIssue":{"key":"ACME-6"},"outwardIssue":{"key":"ACME-5"}}')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
run jira dep-add --number ACME-5 --by ACME-7
check "dep-add of an existing link sends nothing" "$([ "$RC" = 0 ] && [ "$(sent POST)" = 0 ] && echo 1 || echo 0)"
: >"$CURL_LOG"
run jira dep-remove --number ACME-5 --by ACME-7
check "dep-remove deletes the link by id" "$([ "$(sent 'DELETE https://forge.invalid/api/v1/rest/api/3/issueLink/501')" = 1 ] && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
reset
route GET '/rest/api/3/issueLinkType$' 200 '{"issueLinkTypes":[{"id":"10001","name":"Cloners","inward":"is cloned by","outward":"clones"}]}'
run jira dep-list --number ACME-5
check "no blocking link type on the site → unsupported" "$([ "$RC" = 1 ] && [ "$(code)" = unsupported ] && echo 1 || echo 0)" "rc=$RC code=$(code)"
reset
route GET '/rest/api/3/issueLinkType$' 200 '{"issueLinkTypes":[{"id":"10002","name":"Blocks","inward":"waits on","outward":"holds up"}]}'
route GET '/rest/api/3/issue/ACME-5' 200 '{"fields":{"issuelinks":[]}}'
run jira dep-list --number ACME-5
check "a type named Blocks is used when no inward text matches" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC code=$(code)"
```

- [ ] **Step 2: Run it and watch the new sections fail**

Run: `bash scripts/tests/issue-deps-adapters.test.sh`
Expected: the forgejo and github checks pass; every gitlab and jira check fails.

- [ ] **Step 3: GitLab `_api_try`**

Append after `_api` in `flight/scripts/adapters/gitlab/_common.sh`:

```bash

# _api_try METHOD PATH JSON_DATA OUTFILE — like _api, but an HTTP error is for the caller to
# judge: the status is printed and the body written to OUTFILE. Only curl itself failing
# still stops the adapter. Used where one refusal means "not in this tier" (FJ-271).
_api_try() {
  local method="$1" path="$2" data="$3" out="$4"
  curl -sS -o "$out" -w '%{http_code}' -X "$method" "${GL_HEADERS[@]}" \
    -H "Content-Type: application/json" --data-binary "$data" "${PROJECT_API}${path}" \
    || fail network "$method $path: curl failed"
}
```

- [ ] **Step 4: GitLab verbs**

In `flight/scripts/adapters/gitlab/issues`, insert before the final `  *) die …` case:

```bash
  dep-add|dep-remove|dep-list|dep-blocking)
    # Issue dependencies (FJ-271) as issue links. `blocks` / `is_blocked_by` links need GitLab
    # Premium or Ultimate: the Free tier (self-hosted CE included) refuses them, which is
    # reported as `unsupported` so the caller can fall back to comments. On that tier the
    # listing holds only relates_to links, which are filtered out here.
    number=""; by=""
    while [ $# -gt 0 ]; do case "$1" in
      --number) number="$2"; shift 2 ;;
      --by) by="$2"; shift 2 ;;
      *) die "issues $verb: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "issues $verb: --number required"
    case "$verb" in
      dep-add|dep-remove)
        case "$by" in ''|*[!0-9]*) die "issues $verb: --by needs an issue number" ;; esac ;;
    esac
    project_id="$(_api GET "" | jq -r '.id')"
    links="$(_api GET "/issues/${number}/links")"
    # rows LINK_TYPE — this project's links of that type, with the link id kept for removal.
    rows() {
      jq -c --argjson p "$project_id" --arg t "$1" '[.[] | select(.project_id == $p and .link_type == $t)
        | {number: (.iid | tostring), title: (.title // ""),
           state: (if .state == "closed" then "closed" else "open" end), link: .issue_link_id}]' <<<"$links"
    }
    case "$verb" in
      dep-list)     rows is_blocked_by | jq -c 'map(del(.link))' | dep_emit ;;
      dep-blocking) rows blocks | jq -c 'map(del(.link))' | dep_emit ;;
      dep-add)
        [ "$(rows is_blocked_by | jq --arg b "$by" 'map(select(.number == $b)) | length')" = 0 ] || exit 0
        tmp="$(mktemp)"
        code="$(_api_try POST "/issues/${number}/links" \
          "$(jq -cn --argjson p "$project_id" --arg b "$by" '{target_project_id: $p, target_issue_iid: $b, link_type: "is_blocked_by"}')" "$tmp")"
        msg="$(jq -r '(.message // .error // empty) | tostring' "$tmp" 2>/dev/null || true)"
        rm -f "$tmp"
        case "$code" in
          2??) ;;
          400|403|422) fail unsupported "GitLab refused an is_blocked_by link (HTTP $code${msg:+: $msg}); blocking links need GitLab Premium or Ultimate" ;;
          *) http_fail "$code" "POST /issues/${number}/links → HTTP $code${msg:+: $msg}" ;;
        esac
        ;;
      dep-remove)
        link="$(rows is_blocked_by | jq -r --arg b "$by" 'map(select(.number == $b)) | first | .link // empty')"
        [ -n "$link" ] || exit 0
        _api DELETE "/issues/${number}/links/${link}" >/dev/null
        ;;
    esac
    ;;

```

Add the four verbs to the header list and the `*)` usage message.

- [ ] **Step 5: Jira verbs**

In `flight/scripts/adapters/jira/issues`, insert before the final `  *) die …` case:

```bash
  dep-add|dep-remove|dep-list|dep-blocking)
    # Issue dependencies (FJ-271) as issue links. The link type is found by its inward text
    # ("is blocked by"), else by the name "Blocks": an admin can rename either. Seen from an
    # issue's `issuelinks`, an entry holding `inwardIssue` reads "<this issue> is blocked by
    # <inwardIssue>", and one holding `outwardIssue` reads "<this issue> blocks <outwardIssue>".
    # Creating "N is blocked by M" therefore posts M as the inward issue (pinned on the live
    # rig: test-rig/jira/smoke.sh).
    number=""; by=""
    while [ $# -gt 0 ]; do case "$1" in
      --number) number="$2"; shift 2 ;;
      --by) by="$2"; shift 2 ;;
      *) die "issues $verb: unknown arg '$1'" ;;
    esac; done
    [ -n "$number" ] || die "issues $verb: --number required"
    case "$verb" in dep-add|dep-remove) [ -n "$by" ] || die "issues $verb: --by required" ;; esac
    ltype="$(_api GET "/rest/api/3/issueLinkType" | jq -c '
      ([.issueLinkTypes[]? | select((.inward // "" | ascii_downcase) == "is blocked by")]
       + [.issueLinkTypes[]? | select(.name == "Blocks")]) | first // empty')"
    [ -n "$ltype" ] || fail unsupported "this Jira site has no \"is blocked by\" issue link type"
    links="$(_api GET "/rest/api/3/issue/${number}?fields=issuelinks" | jq -c --argjson t "$ltype" --arg p "$LS_PROJECT" '
      [.fields.issuelinks[]? | select(.type.id == $t.id)
       | if .inwardIssue then {side: "blocked_by", issue: .inwardIssue} else {side: "blocks", issue: .outwardIssue} end
       | select(.issue.key | startswith($p + "-"))
       | {side, link: .id, number: .issue.key, title: (.issue.fields.summary // ""),
          state: (if .issue.fields.status.statusCategory.key == "done" then "closed" else "open" end)}]')"
    case "$verb" in
      dep-list)     jq -c '[.[] | select(.side == "blocked_by") | {number, title, state}]' <<<"$links" | dep_emit ;;
      dep-blocking) jq -c '[.[] | select(.side == "blocks") | {number, title, state}]' <<<"$links" | dep_emit ;;
      dep-add)
        [ "$(jq --arg b "$by" '[.[] | select(.side == "blocked_by" and .number == $b)] | length' <<<"$links")" = 0 ] || exit 0
        _api POST "/rest/api/3/issueLink" \
          "$(jq -cn --argjson t "$ltype" --arg b "$by" --arg n "$number" '{type: {id: $t.id}, inwardIssue: {key: $b}, outwardIssue: {key: $n}}')" >/dev/null
        ;;
      dep-remove)
        link="$(jq -r --arg b "$by" '[.[] | select(.side == "blocked_by" and .number == $b)] | first | .link // empty' <<<"$links")"
        [ -n "$link" ] || exit 0
        _api DELETE "/rest/api/3/issueLink/${link}" >/dev/null
        ;;
    esac
    ;;

```

Add the four verbs to the header list and the `*)` usage message.

- [ ] **Step 6: Run the tests and watch them pass**

Run: `bash scripts/tests/issue-deps-adapters.test.sh`
Expected: `Passed: 28  Failed: 0`.

Run: `shellcheck flight/scripts/adapters/gitlab/_common.sh flight/scripts/adapters/gitlab/issues flight/scripts/adapters/jira/issues scripts/tests/issue-deps-adapters.test.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add flight/scripts/adapters/gitlab/_common.sh flight/scripts/adapters/gitlab/issues flight/scripts/adapters/jira/issues scripts/tests/issue-deps-adapters.test.sh
git -C "$WT" commit -m "feat(FJ-271): native dependency verbs on GitLab and Jira

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The `issue-deps` helper and its dispatcher routing

**Files:**
- Create: `flight/scripts/issue-deps`
- Modify: `flight/scripts/flight`:
  - `CAPABILITIES` (line ~47): add `issues-deps`
  - `JSON_VERBS` (line ~105): add `issues/block issues/unblock issues/blockers issues/blocking issues/dep-add issues/dep-remove issues/dep-list issues/dep-blocking`
  - the `--json` switch list (line ~121): add `--signature`
  - the schema-3 gate (line ~411): add `block`, `unblock`, `blockers`, `blocking` beside `copy` and `resync`
  - after the `issues copy|resync` block (line ~925): the new routing block
  - the signature `case` (line ~1168): `--signature) sig_on=yes; shift ;;`
- Create: `scripts/tests/issue-deps.test.sh`

**Interfaces:**
- Consumes (existing dispatcher verbs, each called with `--json` through `fl`/`fl_try`):
  - `issues resolve --number ID` → `{tracker, number, qualified, display, branchPrefix}`
  - `issues get --number Q` → the issue object (`title`, `state`, `status`, `qualified`)
  - `issues comments --number Q` → `[{id, author, created, updated, url, body, signature}]`, oldest first
  - `issues comment --number Q --body-file F --signature [--model M]`
  - `issues set-status --number Q --status ROLE`
  - `issues tracker --tracker REF` → the tracker's config entry (`.labels.status`)
  - `issues dep-add|dep-remove --number Q --by NATIVE`, `issues dep-list|dep-blocking --number Q` (Tasks 1–2)
  - `issues clear-status --number Q` (plain, not `--json`)
- Produces:
  - `flight issues block --number ID --by ID [--no-status] [--model M]` → `Q blocked by BQ (native|text)`; `--json` → `{number, by, via, status}`
  - `flight issues unblock --number ID --by ID [--no-status] [--model M]` → `Q no longer blocked by BQ` or (stderr) `Q was not blocked by BQ`; `--json` → `{number, by, removed, status}`
  - `flight issues blockers|blocking --number ID` → TSV `id⇥title⇥state⇥via`; `--json` → `{issues: [{id, title, state, via}]}`
  - The helper exports `FLIGHT_NO_DEPS=1` for every call it makes (Task 4 relies on it).

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/issue-deps.test.sh`:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# `flight issues block|unblock|blockers|blocking` (FJ-271). The helper is driven through a stub
# dispatcher (FLIGHT_SELF) that keeps trackers' issues, comments and native links as JSON files
# under $STATE: the same seam the helper uses in production, where FLIGHT_SELF is the real
# dispatcher. The routing section at the end runs the REAL dispatcher on local verbs only.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_SELF FLIGHT_REPO_ROOT FLIGHT_ERROR_FILE LS_JSON FLIGHT_MODEL LS_MODEL FLIGHT_NO_DEPS
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
HELPER="$REPO_ROOT/flight/scripts/issue-deps"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

STUB="$SANDBOX/flight-stub"
cat >"$STUB" <<'SH'
#!/usr/bin/env bash
# Stub dispatcher. Trackers live under $STATE/<REF>/: <n>.json (issue), <n>.comments.json,
# deps.json ([[blocked, blocker], …] native pairs), and an `unsupported` file that makes the
# dep-* verbs fail as a backend without native links would. $STATE/trackers.json holds each
# tracker's config entry. FAIL_COMMENT_ON=REF-n makes comments on that issue fail. Every call
# is logged to $STATE/calls.log.
set -euo pipefail
S="${STATE:?}"; printf '%s\n' "$*" >>"$S/calls.log"
group="$1" verb="$2"; shift 2
[ "$group" = issues ] || { echo "stub: no group $group" >&2; exit 2; }
number="" by="" tracker="" status="" body_file="" signed=0
while [ $# -gt 0 ]; do case "$1" in
	--number) number="$2"; shift 2 ;;
	--by) by="$2"; shift 2 ;;
	--tracker) tracker="$2"; shift 2 ;;
	--status) status="$2"; shift 2 ;;
	--body-file) body_file="$2"; shift 2 ;;
	--model) shift 2 ;;
	--signature) signed=1; shift ;;
	--json) shift ;;
	*) echo "stub: unexpected arg $1" >&2; exit 2 ;;
esac; done
err() { jq -cn --arg c "$1" --arg m "$2" '{error:{code:$c, message:$m}}'; exit 1; }
up() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
if [ "$verb" = tracker ]; then jq -c --arg r "$(up "$tracker")" '.[$r]' "$S/trackers.json"; exit 0; fi
case "$number" in
	*-*) ref="$(up "${number%%-*}")"; n="${number##*-}" ;;
	*) ref="$(up "${tracker:-FJ}")"; n="${number#\#}" ;;
esac
D="$S/$ref"; [ -d "$D" ] || err not-found "no tracker $ref"
[ -f "$D/$n.json" ] || err not-found "$ref-$n does not exist"
issue() { jq -c --arg r "$ref" --arg n "$1" '. + {number: $n, tracker: $r, qualified: "\($r)-\($n)"}' "$D/$1.json"; }
deps() { [ -f "$D/deps.json" ] || echo '[]' >"$D/deps.json"; cat "$D/deps.json"; }
rows() { while IFS= read -r m; do [ -n "$m" ] && issue "$m"; done | jq -sc 'map({number, title, state})'; }
case "$verb" in
	resolve) jq -cn --arg r "$ref" --arg n "$n" '{tracker:$r, number:$n, qualified:"\($r)-\($n)", display:"\($r)-\($n)", branchPrefix:"\($r|ascii_downcase)-\($n)"}' ;;
	get) issue "$n" ;;
	comments) cat "$D/$n.comments.json" 2>/dev/null || echo '[]' ;;
	comment)
		[ "${FAIL_COMMENT_ON:-}" != "$ref-$n" ] || err network "comment on $ref-$n failed"
		f="$D/$n.comments.json"; [ -f "$f" ] || echo '[]' >"$f"
		jq -c --rawfile b "$body_file" --argjson s "$signed" \
			'. + [{id: (length + 1 | tostring), author: "bot", created: "2026-10-03T00:00:00Z", updated: null, url: null,
				body: ($b | sub("\n+$"; "")), signature: (if $s == 1 then {plugin: "flight", version: "0.17.1", model: null} else null end)}]' \
			"$f" >"$f.new" && mv "$f.new" "$f"
		jq -c '.[-1]' "$f" ;;
	set-status)
		jq -c --arg s "$status" '.status = $s' "$D/$n.json" >"$D/$n.new" && mv "$D/$n.new" "$D/$n.json"
		jq -cn --arg n "$n" --arg r "$ref" --arg s "$status" '{number:$n, tracker:$r, qualified:"\($r)-\($n)", status:$s}' ;;
	clear-status) jq -c '.status = null' "$D/$n.json" >"$D/$n.new" && mv "$D/$n.new" "$D/$n.json" ;;
	dep-add|dep-remove|dep-list|dep-blocking)
		[ ! -f "$D/unsupported" ] || err unsupported "$ref has no native dependencies"
		case "$verb" in
			dep-add) deps | jq -c --arg a "$n" --arg b "$by" 'if any(.[]; . == [$a, $b]) then . else . + [[$a, $b]] end' >"$D/deps.new"; mv "$D/deps.new" "$D/deps.json" ;;
			dep-remove) deps | jq -c --arg a "$n" --arg b "$by" 'map(select(. != [$a, $b]))' >"$D/deps.new"; mv "$D/deps.new" "$D/deps.json" ;;
			dep-list) deps | jq -r --arg a "$n" '.[] | select(.[0] == $a) | .[1]' | rows ;;
			dep-blocking) deps | jq -r --arg a "$n" '.[] | select(.[1] == $a) | .[0]' | rows ;;
		esac ;;
	*) echo "stub: no verb $verb" >&2; exit 2 ;;
esac
SH
chmod +x "$STUB"

STATE="$SANDBOX/state"; export STATE
ROLES='{"new":"status/new","in-progress":"status/in progress","to-test":"status/to test","blocked":"status/blocked"}'
fresh() {   # a clean world: FJ (native), GH, NB (no blocked role), NN (no new role)
	rm -rf "$STATE"; mkdir -p "$STATE/FJ" "$STATE/GH" "$STATE/NB" "$STATE/NN"; : >"$STATE/calls.log"
	jq -n --argjson r "$ROLES" '{FJ: {ref:"FJ", labels:{status:$r}}, GH: {ref:"GH", labels:{status:$r}},
		NB: {ref:"NB", labels:{status:($r | del(.blocked))}}, NN: {ref:"NN", labels:{status:($r | del(.new))}}}' >"$STATE/trackers.json"
}
# mk REF N TITLE [STATUS [STATE]] — one issue.
mk() { jq -n --arg t "$3" --arg s "${4:-}" --arg st "${5:-open}" '{title:$t, state:$st, status:(if $s == "" then null else $s end)}' >"$STATE/$1/$2.json"; }
# hd ARGS… — run the helper; stdout in $OUT, stderr in $ERR, exit status in $RC.
hd() {
	RC=0
	OUT="$(FLIGHT_SELF="$STUB" FLIGHT_REPO_ROOT="$SANDBOX" "$HELPER" "$@" 2>"$SANDBOX/err")" || RC=$?
	ERR="$(cat "$SANDBOX/err")"
}
hdj() {   # the same, under --json (the dispatcher's LS_JSON + error file)
	RC=0; rm -f "$SANDBOX/env.json"
	OUT="$(LS_JSON=1 FLIGHT_ERROR_FILE="$SANDBOX/env.json" FLIGHT_SELF="$STUB" FLIGHT_REPO_ROOT="$SANDBOX" "$HELPER" "$@" 2>/dev/null)" || RC=$?
}
comments() { cat "$STATE/$1/$2.comments.json" 2>/dev/null || echo '[]'; }
ncomments() { comments "$1" "$2" | jq 'length'; }
status_of() { jq -r '.status // "null"' "$STATE/$1/$2.json"; }

section "same tracker: native link"
fresh; mk FJ 1 "Feature" in-progress; mk FJ 2 "Groundwork"
hd block --number FJ-1 --by FJ-2
check "block prints the link and how it was made" "$([ "$RC" = 0 ] && [ "$OUT" = "FJ-1 blocked by FJ-2 (native)" ] && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"
check "the native pair is recorded" "$(jq -e '. == [["1","2"]]' "$STATE/FJ/deps.json" >/dev/null && echo 1 || echo 0)"
check "status moves to blocked" "$([ "$(status_of FJ 1)" = blocked ] && echo 1 || echo 0)"
check "a native link posts only the status record" \
	"$(comments FJ 1 | jq -e 'length == 1 and (.[0].body | startswith("**Status: blocked** (was in-progress), blocked by FJ-2")) and .[0].signature != null' >/dev/null && echo 1 || echo 0)" "$(comments FJ 1)"
check "no mirror comment for a native link" "$([ "$(ncomments FJ 2)" = 0 ] && echo 1 || echo 0)"
hd blockers --number FJ-1
check "blockers lists the native link" "$([ "$OUT" = "$(printf 'FJ-2\tGroundwork\topen\tnative')" ] && echo 1 || echo 0)" "$OUT"
hd blocking --number FJ-2
check "blocking is the reverse" "$([ "$OUT" = "$(printf 'FJ-1\tFeature\topen\tnative')" ] && echo 1 || echo 0)" "$OUT"
hd unblock --number FJ-1 --by FJ-2
check "unblock removes the native link" "$([ "$RC" = 0 ] && [ "$OUT" = "FJ-1 no longer blocked by FJ-2" ] && jq -e '. == []' "$STATE/FJ/deps.json" >/dev/null && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"
check "the last unblock restores the earlier status" "$([ "$(status_of FJ 1)" = in-progress ] && echo 1 || echo 0)" "$(status_of FJ 1)"
hd unblock --number FJ-1 --by FJ-2
check "unblocking again is a quiet no-op" "$([ "$RC" = 0 ] && [ -z "$OUT" ] && grep -q 'was not blocked by FJ-2' <<<"$ERR" && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"

section "fallback to text when the backend has no native links"
fresh; mk FJ 3 "Feature" new; mk FJ 4 "Groundwork"; touch "$STATE/FJ/unsupported"
hd block --number FJ-3 --by FJ-4
check "block falls back and says so" "$([ "$RC" = 0 ] && [ "$OUT" = "FJ-3 blocked by FJ-4 (text)" ] && grep -q 'using comments' <<<"$ERR" && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"
check "the blocked side gets the marker and the status record" \
	"$(comments FJ 3 | jq -e 'length == 1 and (.[0].body == "**Blocked by FJ-4**: Groundwork\n\nStatus: blocked (was new)")' >/dev/null && echo 1 || echo 0)" "$(comments FJ 3)"
check "the blocker gets the mirror" "$(comments FJ 4 | jq -e 'length == 1 and .[0].body == "**Blocks FJ-3**: Feature"' >/dev/null && echo 1 || echo 0)" "$(comments FJ 4)"
hd blockers --number FJ-3
check "blockers reads the text record" "$([ "$OUT" = "$(printf 'FJ-4\tGroundwork\topen\ttext')" ] && echo 1 || echo 0)" "$OUT"
hd blocking --number FJ-4
check "blocking reads the mirror" "$([ "$OUT" = "$(printf 'FJ-3\tFeature\topen\ttext')" ] && echo 1 || echo 0)" "$OUT"
hd unblock --number FJ-3 --by FJ-4
check "unblock posts both 'No longer' comments" \
	"$([ "$(comments FJ 3 | jq -r '.[-1].body')" = "**No longer blocked by FJ-4**" ] && [ "$(comments FJ 4 | jq -r '.[-1].body')" = "**No longer blocks FJ-3**" ] && echo 1 || echo 0)"
hd blockers --number FJ-3
check "the latest comment wins: no blockers left" "$([ -z "$OUT" ] && echo 1 || echo 0)" "$OUT"
check "status goes back to new" "$([ "$(status_of FJ 3)" = new ] && echo 1 || echo 0)"

section "across trackers: always text"
fresh; mk FJ 5 "Feature" in-progress; mk GH 1 "Upstream fix"
hd block --number FJ-5 --by gh-1
check "a cross-tracker link is text, and --by is matched case-blind" "$([ "$OUT" = "FJ-5 blocked by GH-1 (text)" ] && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"
check "no native call is made across trackers" "$(grep -q 'dep-' "$STATE/calls.log" && echo 0 || echo 1)" "$(cat "$STATE/calls.log")"
before="$(ncomments FJ 5)/$(ncomments GH 1)"
hd block --number FJ-5 --by GH-1
check "blocking again posts nothing new" "$([ "$RC" = 0 ] && [ "$(ncomments FJ 5)/$(ncomments GH 1)" = "$before" ] && echo 1 || echo 0)" "$before → $(ncomments FJ 5)/$(ncomments GH 1)"

section "a mirror that failed is posted on the rerun"
fresh; mk FJ 6 "Feature"; mk GH 2 "Upstream"
RC=0; FAIL_COMMENT_ON=GH-2 FLIGHT_SELF="$STUB" FLIGHT_REPO_ROOT="$SANDBOX" "$HELPER" block --number FJ-6 --by GH-2 --no-status >/dev/null 2>"$SANDBOX/err" || RC=$?
check "the failure is reported" "$([ "$RC" = 1 ] && grep -q 'GH-2' "$SANDBOX/err" && echo 1 || echo 0)" "rc=$RC $(cat "$SANDBOX/err")"
hd block --number FJ-6 --by GH-2 --no-status
check "the rerun posts only the mirror" "$([ "$RC" = 0 ] && [ "$(ncomments FJ 6)" = 1 ] && [ "$(ncomments GH 2)" = 1 ] && echo 1 || echo 0)" "$(ncomments FJ 6)/$(ncomments GH 2)"

section "what the text record does not count"
fresh; mk FJ 7 "Feature"; mk GH 1 "Upstream"; mk FJ 8 "Other"
jq -n '[{id:"1", body:"**Blocked by GH-1**: said by a person", signature:null},
	{id:"2", body:"**blocked by FJ-8**\r\nsigned, CRLF, lower case", signature:{plugin:"flight"}},
	{id:"3", body:"Blocked by FJ-404: a deleted issue", signature:{plugin:"flight"}}]' >"$STATE/FJ/7.comments.json"
hd blockers --number FJ-7
check "unsigned prose is ignored" "$(! grep -q 'GH-1' <<<"$OUT" && echo 1 || echo 0)" "$OUT"
check "a signed CRLF marker in another case counts" "$(grep -qx $'FJ-8\tOther\topen\ttext' <<<"$OUT" && echo 1 || echo 0)" "$OUT"
check "a blocker that no longer exists is listed without a title" "$([ "$RC" = 0 ] && grep -qx $'FJ-404\t\tunknown\ttext' <<<"$OUT" && echo 1 || echo 0)" "rc=$RC out=$OUT"

section "native and text for the same pair print once"
fresh; mk FJ 9 "Feature"; mk FJ 10 "Groundwork"
echo '[["9","10"]]' >"$STATE/FJ/deps.json"
jq -n '[{id:"1", body:"**Blocked by FJ-10**: Groundwork", signature:{plugin:"flight"}}]' >"$STATE/FJ/9.comments.json"
hd blockers --number FJ-9
check "one row, as native" "$([ "$OUT" = "$(printf 'FJ-10\tGroundwork\topen\tnative')" ] && echo 1 || echo 0)" "$OUT"

section "status"
fresh; mk FJ 11 "Feature" in-progress; mk GH 1 "One"; mk GH 2 "Two"
hd block --number FJ-11 --by GH-1
hd block --number FJ-11 --by GH-2
check "a second blocker records nothing new about status" "$(comments FJ 11 | jq -e '[.[] | select(.body | test("\\(was "))] | length == 1' >/dev/null && echo 1 || echo 0)" "$(comments FJ 11)"
hd unblock --number FJ-11 --by GH-1
check "still blocked while a blocker remains" "$([ "$(status_of FJ 11)" = blocked ] && echo 1 || echo 0)"
hd unblock --number FJ-11 --by GH-2
check "the last unblock restores in-progress" "$([ "$(status_of FJ 11)" = in-progress ] && echo 1 || echo 0)"

fresh; mk FJ 12 "Feature" in-progress; mk GH 1 "One"
hd block --number FJ-12 --by GH-1
jq '.status = "to-test"' "$STATE/FJ/12.json" >"$STATE/FJ/12.new" && mv "$STATE/FJ/12.new" "$STATE/FJ/12.json"
hd unblock --number FJ-12 --by GH-1
check "a status changed by hand is left alone" "$([ "$(status_of FJ 12)" = to-test ] && echo 1 || echo 0)"

fresh; mk FJ 13 "Feature" blocked; mk FJ 14 "Groundwork"; echo '[["13","14"]]' >"$STATE/FJ/deps.json"
hd unblock --number FJ-13 --by FJ-14
check "no record → new" "$([ "$(status_of FJ 13)" = new ] && echo 1 || echo 0)"

fresh; mk NN 1 "Feature" blocked; mk GH 1 "One"
jq -n '[{id:"1", body:"**Blocked by GH-1**: One", signature:{plugin:"flight"}}]' >"$STATE/NN/1.comments.json"
hd unblock --number NN-1 --by GH-1
check "no record and no new role → status cleared" "$([ "$(status_of NN 1)" = null ] && echo 1 || echo 0)"

fresh; mk NB 1 "Feature" in-progress; mk GH 1 "One"
hd block --number NB-1 --by GH-1
check "a tracker without a blocked role keeps its status, and says so" "$([ "$RC" = 0 ] && [ "$(status_of NB 1)" = in-progress ] && grep -q 'no blocked status role' <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"

fresh; mk FJ 15 "Feature" in-progress; mk GH 1 "One"
hd block --number FJ-15 --by GH-1 --no-status
check "--no-status leaves the status and records none" "$([ "$(status_of FJ 15)" = in-progress ] && comments FJ 15 | jq -e '.[0].body == "**Blocked by GH-1**: One"' >/dev/null && echo 1 || echo 0)" "$(comments FJ 15)"

section "--json and refusals"
fresh; mk FJ 16 "Feature" in-progress; mk GH 1 "One"
hdj block --number FJ-16 --by GH-1
check "block --json" "$(jq -e '. == {number:"FJ-16", by:"GH-1", via:"text", status:"blocked"}' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "$OUT"
hdj blockers --number FJ-16
check "blockers --json" "$(jq -e '.issues == [{id:"GH-1", title:"One", state:"open", via:"text"}]' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "$OUT"
hdj unblock --number FJ-16 --by GH-1
check "unblock --json" "$(jq -e '. == {number:"FJ-16", by:"GH-1", removed:["text"], status:"in-progress"}' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "$OUT"
hdj block --number FJ-16 --by FJ-16
check "an issue cannot block itself" "$([ "$RC" = 1 ] && jq -e '.error.code == "usage"' "$SANDBOX/env.json" >/dev/null && echo 1 || echo 0)"
hdj block --number FJ-16 --by FJ-999
check "an unknown blocker is not-found" "$([ "$RC" = 1 ] && jq -e '.error.code == "not-found"' "$SANDBOX/env.json" >/dev/null && echo 1 || echo 0)"
hd blockers --number FJ-16 --by GH-1
check "--by is refused on blockers" "$([ "$RC" = 1 ] && echo 1 || echo 0)"

section "routing through the real dispatcher"
D="$SANDBOX/disp"; mkdir -p "$D/.flightdirector"; git -C "$D" init -q
jq -n '{schemaVersion: 3,
	code: {backend:"forgejo", api:"https://code.example.com/api/v1", owner:"acme", repo:"widget", stages:[{name:"main"}]},
	issues: {backend:"requires-newer-flight"},
	issueTrackers: [
		{ref:"FJ", name:"Code", default:true, backend:"forgejo", api:"https://code.example.com/api/v1", owner:"acme", repo:"widget", credentialRef:"code"},
		{ref:"GH", name:"Public", default:false, backend:"github", api:"https://api.github.com", owner:"acme", repo:"widget"}]}' >"$D/.flightdirector/config.json"
set +e
OUT="$(cd "$D" && "$DISP" issues block --number FJ-1 --by FJ-1 --no-status --json 2>/dev/null)"; RC=$?
set -e
check "the dispatcher routes block to the helper and keeps --json after a switch" \
	"$([ "$RC" = 1 ] && jq -e '.error.code == "usage" and (.error.message | test("itself"))' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "rc=$RC out=$OUT"
set +e
OUT="$(cd "$D" && "$DISP" issues blockers --number FJ-1 --tracker GH 2>&1)"; RC=$?
set -e
check "--tracker is refused (each id names its tracker)" "$([ "$RC" = 1 ] && grep -q 'names its own tracker' <<<"$OUT" && echo 1 || echo 0)" "rc=$RC out=$OUT"
check "the capability token is advertised" "$(grep -qx issues-deps <<<"$("$DISP" capabilities)" && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then: `git -C "$WT" add scripts/tests/issue-deps.test.sh && git -C "$WT" update-index --chmod=+x scripts/tests/issue-deps.test.sh`.

- [ ] **Step 2: Run it and watch it fail**

Run: `bash scripts/tests/issue-deps.test.sh`
Expected: the helper doesn't exist, so the stub sections fail; the routing checks fail ("unknown verb" from the adapter); exit 1.

- [ ] **Step 3: Write the helper**

Create `flight/scripts/issue-deps`:

```bash
#!/usr/bin/env bash
#
# flight `issues block|unblock|blockers|blocking` — "this issue is blocked by that one" (FJ-271).
#
#   flight issues block    --number ID --by ID [--no-status] [--model ID]
#   flight issues unblock  --number ID --by ID [--no-status] [--model ID]
#   flight issues blockers --number ID
#   flight issues blocking --number ID
#
# Dispatcher-owned, like issue-copy: every read and write goes back through the dispatcher
# ($FLIGHT_SELF), one tracker per call. Two issues on the same tracker use its native
# relationship (the adapters' dep-* verbs). When that backend can't record one (`unsupported`),
# and always across trackers, the link is a pair of signed comments instead:
#   on the blocked issue  **Blocked by GH-3**: <title>   /  **No longer blocked by GH-3**
#   on the blocker        **Blocks FJ-12**: <title>      /  **No longer blocks FJ-12**
# Per pair the latest signed comment wins. Status follows the link unless --no-status: block
# sets the tracker's `blocked` role and records `(was <role>)`; the last unblock restores it.
# Invoked by the dispatcher, which exports FLIGHT_REPO_ROOT and FLIGHT_SELF.
#
# Design: docs/superpowers/specs/2026-10-03-issue-dependencies-design.md
set -euo pipefail

# Windows shims (jq CRLF, path form); a no-op elsewhere.
# shellcheck source-path=SCRIPTDIR source=_portable.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_portable.sh"

: "${FLIGHT_REPO_ROOT:?FLIGHT_REPO_ROOT not set (dispatcher must export it)}"
: "${FLIGHT_SELF:?FLIGHT_SELF not set (dispatcher must export it)}"
# Titles come from `issues get --json`, which would look the blockers up again: never from here.
export FLIGHT_NO_DEPS=1

VERB="${1:-}"; [ $# -eq 0 ] || shift
case "$VERB" in block|unblock|blockers|blocking) ;; *) echo "flight issues: unknown dependency verb '$VERB' (expected: block unblock blockers blocking)" >&2; exit 1 ;; esac
TMP="$(mktemp -d "${TMPDIR:-/tmp}/flight-deps.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# fail CODE MESSAGE — one sentence on stderr, plus the --json envelope when one was asked for.
fail() {
	echo "flight issues $VERB: $2" >&2
	if [ -n "${FLIGHT_ERROR_FILE:-}" ]; then
		jq -cn --arg c "$1" --arg m "flight issues $VERB: $2" '{error:{code:$c, message:$m}}' \
			>"$FLIGHT_ERROR_FILE" 2>/dev/null || true
	fi
	exit 1
}
die() { fail usage "$*"; }
note() { echo "flight issues $VERB: $*" >&2; }

# fl ARGS… — one --json dispatcher call. Prints its output, or stops with the code it reported.
# Always assign its output on a line of its own (never `local x="$(fl …)"`), so a failure stops
# the script.
fl() {
	local out rc=0 code msg
	out="$("$FLIGHT_SELF" "$@" --json)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		code="$(jq -r '.error.code // empty' <<<"$out" 2>/dev/null || true)"
		msg="$(jq -r '.error.message // empty' <<<"$out" 2>/dev/null || true)"
		fail "${code:-backend}" "${msg:-flight $1 $2 failed (exit $rc)}"
	fi
	printf '%s\n' "$out"
}

# fl_try ARGS… — like fl, but a failure prints `!CODE<TAB>MESSAGE` instead of stopping. Used
# where one code (`unsupported`, `not-found`) changes the plan rather than ending it.
fl_try() {
	local out rc=0
	out="$("$FLIGHT_SELF" "$@" --json)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		printf '!%s\t%s\n' "$(jq -r '.error.code // "backend"' <<<"$out" 2>/dev/null || echo backend)" \
			"$(jq -r '.error.message // empty' <<<"$out" 2>/dev/null || true)"
		return 0
	fi
	printf '%s\n' "$out"
}
err_code() { printf '%s' "${1#!}" | cut -f1; }
err_msg() { printf '%s' "$1" | cut -f2-; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

NUMBER=""; BY=""; WANT_STATUS=1; MODEL_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--number) [ $# -ge 2 ] || die "--number needs an issue id"; NUMBER="$2"; shift 2 ;;
		--by)
			case "$VERB" in block|unblock) ;; *) die "--by applies to block and unblock only" ;; esac
			[ $# -ge 2 ] || die "--by needs an issue id"; BY="$2"; shift 2 ;;
		--no-status)
			case "$VERB" in block|unblock) ;; *) die "--no-status applies to block and unblock only" ;; esac
			WANT_STATUS=0; shift ;;
		--model) [ $# -ge 2 ] || die "--model needs a model id"; MODEL_ARGS=(--model "$2"); shift 2 ;;
		*) die "unknown argument '$1'" ;;
	esac
done
[ -n "$NUMBER" ] || die "usage: flight issues $VERB --number ID${BY:+ --by ID}"
case "$VERB" in block|unblock) [ -n "$BY" ] || die "usage: flight issues $VERB --number ID --by ID" ;; esac

ISSUE="$(fl issues resolve --number "$NUMBER")"
Q="$(jq -r '.qualified' <<<"$ISSUE")"; T="$(jq -r '.tracker' <<<"$ISSUE")"
UQ="$(upper "$Q")"

# text_links COMMENTS_JSON SIDE — the qualified ids (upper case) the text record links, one
# per line. SIDE `blocked` reads the "Blocked by" comments (this issue's blockers); `mirror`
# reads the "Blocks" comments (the issues this one blocks). Only flight-signed comments count,
# and per id the latest one wins.
text_links() {
	jq -r --arg side "$2" '
		[.[] | select(.signature != null)
		 | ((.body // "") | split("\n")[0] | sub("\r$"; "")) as $first
		 | ([$first | capture("^(\\*\\*)?(?<kind>Blocked by|No longer blocked by|Blocks|No longer blocks) (?<id>[A-Za-z][A-Za-z0-9]*-[0-9]+)(\\*\\*)?(:.*)?$"; "i")] | first) // empty
		 | .kind |= ascii_downcase
		 | select(if $side == "blocked" then (.kind | endswith("blocked by")) else (.kind | endswith("blocks")) end)]
		| reduce .[] as $m ({}; .[$m.id | ascii_upcase] = ($m.kind | startswith("no longer") | not))
		| to_entries[] | select(.value) | .key' <<<"$1"
}

# collect blockers|blocking — this issue's links as [{id, title, state, via}]: the native rows
# first (skipped when the backend has none), then the text record's ids not already listed.
collect() {
	local verb=dep-list side=blocked native rows comments id got
	if [ "$1" = blocking ]; then verb=dep-blocking; side=mirror; fi
	native="$(fl_try issues "$verb" --number "$Q")"
	case "$native" in
		'!unsupported'*) native='[]' ;;
		'!'*) fail "$(err_code "$native")" "$(err_msg "$native")" ;;
	esac
	rows="$(jq -c --arg t "$T" '[.[] | {id: "\($t)-\(.number | split("-") | last)", title, state, via: "native"}]' <<<"$native")"
	comments="$(fl issues comments --number "$Q")"
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		if jq -e --arg i "$id" 'any(.[]; (.id | ascii_upcase) == $i)' <<<"$rows" >/dev/null; then continue; fi
		got="$(fl_try issues get --number "$id")"
		case "$got" in
			'!'*) rows="$(jq -c --arg i "$id" '. + [{id: $i, title: null, state: null, via: "text"}]' <<<"$rows")" ;;
			*) rows="$(jq -c --arg i "$id" --argjson g "$got" '. + [{id: ($g.qualified // $i), title: $g.title, state: $g.state, via: "text"}]' <<<"$rows")" ;;
		esac
	done < <(text_links "$comments" "$side")
	printf '%s\n' "$rows"
}

# post QUALIFIED TEXT — one signed comment (signed even where a repo turned signatures off:
# reading the record back depends on it).
post() {
	printf '%s\n' "$2" >"$TMP/body.md"
	fl issues comment --number "$1" --body-file "$TMP/body.md" --signature ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} >/dev/null
}

# status_roles TRACKER — the tracker's configured status roles, {role: label} (declined roles left out).
status_roles() { fl issues tracker --tracker "$1" | jq -c '.labels.status // {} | with_entries(select(.value | type == "string"))'; }

if [ "$VERB" = blockers ] || [ "$VERB" = blocking ]; then
	ROWS="$(collect "$VERB")"
	if [ "${LS_JSON:-}" = 1 ]; then jq -c '{issues: .}' <<<"$ROWS"
	else jq -r '.[] | [.id, (.title // ""), (.state // "unknown"), .via] | @tsv' <<<"$ROWS"
	fi
	exit 0
fi

BLOCKER="$(fl issues resolve --number "$BY")"
BQ="$(jq -r '.qualified' <<<"$BLOCKER")"; BT="$(jq -r '.tracker' <<<"$BLOCKER")"; BN="$(jq -r '.number' <<<"$BLOCKER")"
UBQ="$(upper "$BQ")"
[ "$UBQ" != "$UQ" ] || die "an issue cannot block itself ($Q)"
ISSUE_J="$(fl issues get --number "$Q")"
BY_J="$(fl issues get --number "$BQ")"
ROLES="{}"; [ "$WANT_STATUS" = 0 ] || ROLES="$(status_roles "$T")"

if [ "$VERB" = block ]; then
	VIA=text
	if [ "$(upper "$BT")" = "$(upper "$T")" ]; then
		R="$(fl_try issues dep-add --number "$Q" --by "$BN")"
		case "$R" in
			'!unsupported'*) note "native dependencies unavailable on $T ($(err_msg "$R")); using comments" ;;
			'!'*) fail "$(err_code "$R")" "$(err_msg "$R")" ;;
			*) VIA=native ;;
		esac
	fi

	# Status: what `blocked` replaces, recorded so the last unblock can put it back.
	SET_TO=""; WAS=""
	if [ "$WANT_STATUS" = 1 ]; then
		if ! jq -e 'has("blocked")' <<<"$ROLES" >/dev/null; then
			note "tracker $T has no blocked status role; status unchanged"
		elif [ "$(jq -r '.status // ""' <<<"$ISSUE_J")" != blocked ]; then
			SET_TO=blocked; WAS="$(jq -r '.status // "none"' <<<"$ISSUE_J")"
		fi
	fi

	RECORDED=0
	if [ "$VIA" = text ]; then
		LINKS="$(text_links "$(fl issues comments --number "$Q")" blocked)"
		if ! grep -Fxq -- "$UBQ" <<<"$LINKS"; then
			BODY="**Blocked by $BQ**: $(jq -r '.title' <<<"$BY_J")"
			if [ -n "$SET_TO" ]; then BODY="$BODY"$'\n\n'"Status: blocked (was $WAS)"; RECORDED=1; fi
			post "$Q" "$BODY"
		fi
		MIRROR="$(text_links "$(fl issues comments --number "$BQ")" mirror)"
		if ! grep -Fxq -- "$UQ" <<<"$MIRROR"; then
			post "$BQ" "**Blocks $Q**: $(jq -r '.title' <<<"$ISSUE_J")"
		fi
	fi
	if [ -n "$SET_TO" ]; then
		[ "$RECORDED" = 1 ] || post "$Q" "**Status: blocked** (was $WAS), blocked by $BQ"
		fl issues set-status --number "$Q" --status blocked >/dev/null
	fi

	if [ "${LS_JSON:-}" = 1 ]; then
		jq -cn --arg n "$Q" --arg b "$BQ" --arg v "$VIA" --arg s "$SET_TO" '{number: $n, by: $b, via: $v, status: (if $s == "" then null else $s end)}'
	else
		echo "$Q blocked by $BQ ($VIA)"
	fi
	exit 0
fi

# unblock
REMOVED=()
if [ "$(upper "$BT")" = "$(upper "$T")" ]; then
	R="$(fl_try issues dep-list --number "$Q")"
	case "$R" in
		'!unsupported'*) ;;
		'!'*) fail "$(err_code "$R")" "$(err_msg "$R")" ;;
		*)
			if jq -e --arg b "$BN" 'any(.[]; .number == $b)' <<<"$R" >/dev/null; then
				fl issues dep-remove --number "$Q" --by "$BN" >/dev/null
				REMOVED+=(native)
			fi ;;
	esac
fi
LINKS="$(text_links "$(fl issues comments --number "$Q")" blocked)"
if grep -Fxq -- "$UBQ" <<<"$LINKS"; then
	post "$Q" "**No longer blocked by $BQ**"
	REMOVED+=(text)
fi
MIRROR="$(text_links "$(fl issues comments --number "$BQ")" mirror)"
if grep -Fxq -- "$UQ" <<<"$MIRROR"; then
	post "$BQ" "**No longer blocks $Q**"
	case " ${REMOVED[*]-} " in *" text "*) ;; *) REMOVED+=(text) ;; esac
fi

RESTORED=""
if [ "${#REMOVED[@]}" = 0 ]; then
	note "$Q was not blocked by $BQ"
elif [ "$WANT_STATUS" = 1 ] && [ "$(collect blockers)" = "[]" ]; then
	CURRENT="$(fl issues get --number "$Q")"
	if [ "$(jq -r '.status // ""' <<<"$CURRENT")" = blocked ]; then
		WAS="$(fl issues comments --number "$Q" | jq -r '[.[] | select(.signature != null) | (.body // "")
			| [capture("\\(was (?<r>[a-z0-9-]+)\\)")] | first // empty | .r] | last // empty')"
		if [ -n "$WAS" ] && [ "$WAS" != none ] && [ "$WAS" != blocked ] && jq -e --arg r "$WAS" 'has($r)' <<<"$ROLES" >/dev/null; then
			RESTORED="$WAS"
		elif jq -e 'has("new")' <<<"$ROLES" >/dev/null; then
			RESTORED=new
		fi
		if [ -n "$RESTORED" ]; then
			fl issues set-status --number "$Q" --status "$RESTORED" >/dev/null
		else
			FLIGHT_NO_DEPS=1 "$FLIGHT_SELF" issues clear-status --number "$Q" >/dev/null || fail backend "could not clear the status of $Q"
		fi
	fi
fi

if [ "${LS_JSON:-}" = 1 ]; then
	jq -cn --arg n "$Q" --arg b "$BQ" --arg s "$RESTORED" --argjson r "$(printf '%s\n' ${REMOVED[@]+"${REMOVED[@]}"} | jq -Rsc 'split("\n") | map(select(length > 0))')" \
		'{number: $n, by: $b, removed: $r, status: (if $s == "" then null else $s end)}'
elif [ "${#REMOVED[@]}" != 0 ]; then
	echo "$Q no longer blocked by $BQ"
fi
```

Then: `git -C "$WT" add flight/scripts/issue-deps && git -C "$WT" update-index --chmod=+x flight/scripts/issue-deps`.

- [ ] **Step 4: Wire the dispatcher**

In `flight/scripts/flight`:

1. `CAPABILITIES` (line ~47): append `issues-deps`.
2. `JSON_VERBS` (line ~105): append `issues/block issues/unblock issues/blockers issues/blocking issues/dep-add issues/dep-remove issues/dep-list issues/dep-blocking`.
3. The `--json` switch list (line ~121): add `--signature` to `--no-status|--no-signature|…`.
4. The schema-3 gate (line ~411): extend `[ "$verb" = copy ] || [ "$verb" = resync ]` with `|| [ "$verb" = block ] || [ "$verb" = unblock ] || [ "$verb" = blockers ] || [ "$verb" = blocking ]`.
5. After the `issues copy|resync` block (line ~925), add:

```bash
	# `issues block|unblock|blockers|blocking` (FJ-271) — dispatcher-owned, like copy: the helper
	# reads and writes each issue back through this dispatcher, trying the tracker's native
	# dependency verbs (dep-*) first and falling back to signed comments.
	if [ "$group" = issues ]; then
		case "$verb" in
			block|unblock|blockers|blocking)
				[ -z "$tracker_selector" ] || die "issues $verb: each issue id names its own tracker; drop --tracker"
				json_finish=""; json_tracker=""
				export FLIGHT_REPO_ROOT="$repo_root" FLIGHT_SELF="$SELF_DIR/flight"
				handoff "$SELF_DIR/issue-deps" "$verb" "$@"
				;;
		esac
	fi
```

6. In the signature `case` (line ~1168), add beside `--no-signature`:

```bash
      --signature)    sig_on=yes; shift ;;   # forced on: issue-deps' marker comments are read back by it
```

Also add `- \`--signature\` forces it on for one write (FJ-271).` to the comment above that block, after "Off switch: …".

- [ ] **Step 5: Run the tests and watch them pass**

Run: `bash scripts/tests/issue-deps.test.sh`
Expected: `Passed: 44  Failed: 0`.

Run: `bash scripts/tests/issue-copy.test.sh && bash scripts/tests/signature.test.sh && bash scripts/tests/json-errors.test.sh`
Expected: all pass (unchanged behaviour).

Run: `shellcheck flight/scripts/issue-deps flight/scripts/flight scripts/tests/issue-deps.test.sh`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add flight/scripts/issue-deps flight/scripts/flight scripts/tests/issue-deps.test.sh
git -C "$WT" commit -m "feat(FJ-271): issues block/unblock/blockers/blocking with native links and a text fallback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `blocked_by` on `issues get --json`

**Files:**
- Modify: `flight/scripts/issue-json.jq` (`finish_issue`)
- Modify: `flight/scripts/flight` (`handoff`, the `list|get|comments|comment)` branch)
- Modify: `scripts/tests/issues-json.test.sh` (`ISSUE_KEYS`; `FLIGHT_NO_DEPS` at the top)
- Modify: `scripts/tests/issue-deps.test.sh` (a new section before the summary)

**Interfaces:**
- Consumes: `flight issues blockers --number Q --json` → `{issues: [...]}` (Task 3); the helper exports `FLIGHT_NO_DEPS=1` (Task 3).
- Produces: every finished issue object has `blocked_by`: `null` on list rows and when the lookup fails; an array of `{id, title, state, via}` on `issues get --json`.

- [ ] **Step 1: Write the failing tests**

In `scripts/tests/issues-json.test.sh`:
- add `export FLIGHT_NO_DEPS=1` after the `unset` line, with the comment `# The issue shape is under test here, not the blockers lookup (issue-deps.test.sh covers that).`;
- change `ISSUE_KEYS` to `'["author","blocked_by","body","comments","created","labels","number","qualified","signature","state","status","title","tracker","updated","url"]'`.

In `scripts/tests/issue-deps.test.sh`, insert before the summary block:

```bash
section "issues get --json carries blocked_by"
# A fake curl for the real dispatcher: FJ issue 1 exists, its dependencies are FJ-2, and its
# comments are empty. With $DEPS_FAIL set, the dependency call answers 500.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in
	-o) out="$2"; shift 2 ;;
	-D|-w|-H|-u|-X|--data-binary) shift 2 ;;
	-sS|-L) shift ;;
	*) url="$1"; shift ;;
esac; done
code=200
case "$url" in
	*/repos/acme/widget) body='{"internal_tracker":{"enable_issue_dependencies":true}}' ;;
	*/issues/1/dependencies*) if [ -n "${DEPS_FAIL:-}" ]; then code=500; body='{"message":"boom"}'
		else body='[{"number":2,"title":"Groundwork","state":"open","repository":{"owner":"acme","name":"widget"}}]'; fi ;;
	*/issues/1/comments*) body='[]' ;;
	*/issues/1) body='{"number":1,"title":"Feature","state":"open","labels":[],"user":{"login":"a"},"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z","comments":0,"html_url":"u","body":"b"}' ;;
	*) code=404; body='{"message":"no route"}' ;;
esac
printf '%s' "$body" >"$out"; printf '%s' "$code"
SH
chmod +x "$SANDBOX/bin/curl"
printf '{"code":{"token":"t"}}\n' >"$D/.flightdirector/secrets.json"
OUT="$(cd "$D" && PATH="$SANDBOX/bin:$PATH" "$DISP" issues get --number FJ-1 --json 2>/dev/null)"
check "get --json lists the blockers" "$(jq -e '.blocked_by == [{id:"FJ-2", title:"Groundwork", state:"open", via:"native"}]' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "$OUT"
set +e
OUT="$(cd "$D" && DEPS_FAIL=1 PATH="$SANDBOX/bin:$PATH" "$DISP" issues get --number FJ-1 --json 2>"$SANDBOX/get.err")"; RC=$?
set -e
check "a failed lookup still answers, with blocked_by null and a warning" \
	"$([ "$RC" = 0 ] && jq -e '.blocked_by == null and .title == "Feature"' <<<"$OUT" >/dev/null && grep -q 'blocked_by is null' "$SANDBOX/get.err" && echo 1 || echo 0)" "rc=$RC out=$OUT"
OUT="$(cd "$D" && FLIGHT_NO_DEPS=1 PATH="$SANDBOX/bin:$PATH" "$DISP" issues get --number FJ-1 --json 2>/dev/null)"
check "FLIGHT_NO_DEPS skips the lookup" "$(jq -e '.blocked_by == null' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "$OUT"
OUT="$(cd "$D" && PATH="$SANDBOX/bin:$PATH" "$DISP" issues get --number FJ-1 2>/dev/null | head -n1)"
check "the TSV form is unchanged" "$([ "$OUT" = "$(printf '1\tFeature\topen')" ] && echo 1 || echo 0)" "$OUT"
```

- [ ] **Step 2: Run them and watch them fail**

Run: `bash scripts/tests/issues-json.test.sh; bash scripts/tests/issue-deps.test.sh`
Expected: the key-set checks in `issues-json.test.sh` fail (no `blocked_by`), and the first two checks of the new section fail.

- [ ] **Step 3: Implement**

In `flight/scripts/issue-json.jq`, `finish_issue`: append `, blocked_by: null` after `author, created, updated, comments, url, body, signature` (the object's last line), and add to the file's header comment: `#   blocked_by null here; the dispatcher fills it on \`issues get --json\` (FJ-271).`

In `flight/scripts/flight`, `handoff`, right after `mv "$json_out.done" "$json_out"` in the `list|get|comments|comment)` branch:

```bash
        # `issues get --json` carries the issue's blockers (FJ-271). The lookup is the same one
        # `issues blockers` does; it never fails the get. The helper exports FLIGHT_NO_DEPS for
        # its own reads, which is what stops this from recursing.
        if [ "$json_finish" = get ] && [ -z "${FLIGHT_NO_DEPS:-}" ] && [ -n "$json_tracker" ]; then
          deps_q="$(jq -r '.qualified // empty' "$json_out")"
          if [ -n "$deps_q" ] && deps_out="$(env -u FLIGHT_ERROR_FILE -u LS_JSON "$SELF_DIR/flight" issues blockers --number "$deps_q" --json 2>/dev/null)"; then
            jq -c --argjson d "$deps_out" '.blocked_by = $d.issues' "$json_out" >"$json_out.done" && mv "$json_out.done" "$json_out"
          else
            echo "flight: warning — could not read the blockers of ${deps_q:-the issue}; blocked_by is null" >&2
          fi
        fi
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `bash scripts/tests/issues-json.test.sh && bash scripts/tests/issue-deps.test.sh`
Expected: both pass; `issue-deps.test.sh` reports `Passed: 48  Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git -C "$WT" add flight/scripts/issue-json.jq flight/scripts/flight scripts/tests/issues-json.test.sh scripts/tests/issue-deps.test.sh
git -C "$WT" commit -m "feat(FJ-271): blocked_by on issues get --json

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Skills, reference docs, guide and changelog; full preflight

**Files:**
- Modify: `flight/skills/working-an-issue/SKILL.md` (Step 1, after the "state what you read" paragraph, ~line 132)
- Modify: `flight/skills/triaging-issues/SKILL.md` (Step 3, ~line 85)
- Modify: `flight/skills/filing-issues/SKILL.md` (after the "copy or move" paragraph, ~line 96)
- Modify: `scripts/tests/tracker-lifecycle-skills.test.sh`
- Modify: `flight/references/adapter-contract.md`, `flight/references/json-output.md`, `flight/GUIDE.md`, `flight/CHANGELOG.md`

**Interfaces:**
- Consumes: the verbs and shapes from Tasks 1–4.

- [ ] **Step 1: Pin the skill lines (failing)**

Read `scripts/tests/tracker-lifecycle-skills.test.sh` and add, in its own style, three checks:
- `working-an-issue/SKILL.md` contains `issues blockers --tracker "$TRACKER" --number "$NUMBER"`;
- `triaging-issues/SKILL.md` contains `issues blockers`;
- `filing-issues/SKILL.md` contains `issues block --number`.

Run: `bash scripts/tests/tracker-lifecycle-skills.test.sh`
Expected: the three new checks fail.

- [ ] **Step 2: Edit the skills**

`working-an-issue/SKILL.md`, insert after the paragraph that ends "…work to that, and say so explicitly." in Step 1:

```markdown
- **Check what blocks it.** Right after the thread:
  ```
  flight issues blockers --tracker "$TRACKER" --number "$NUMBER"
  ```
  Each row is `id⇥title⇥state⇥native|text`. An **open** blocker goes in the pickup line
  ("read #12: body + 2 comments; blocked by GH-3 (open)"), and you **ask before starting**: the
  work may depend on something that isn't there yet. Closed blockers are only mentioned. No rows:
  say nothing.
```

`triaging-issues/SKILL.md`, at the end of Step 3:

```markdown
For a picked issue that carries the `blocked` status, run `flight issues blockers --number <id>`
and name its open blockers in the write-up. Don't run it for every row: it is one or more API
calls per issue.
```

`filing-issues/SKILL.md`, after the "copy or move" paragraph:

```markdown
A new issue that depends on another one? File it, then record the link with
`flight issues block --number <new id> --by <the other id>` instead of writing "blocked by" in
the body. That uses the tracker's native relationship where there is one, and moves the status to
blocked.
```

Run: `bash scripts/tests/tracker-lifecycle-skills.test.sh`
Expected: all pass.

- [ ] **Step 3: Reference docs**

`flight/references/adapter-contract.md`:
- in the layout block, change the `issues` comment to end with `… close reopen dep-add dep-remove dep-list dep-blocking`;
- add four rows to the `issues` verb table, after `reopen`:

```markdown
| `dep-add`   | `--number N` `--by M`                  | (nothing) — records "N is blocked by M", both on this tracker; idempotent. Fails `unsupported` where the backend can't (Forgejo with dependencies switched off, GitLab Free tier, a Jira site with no "is blocked by" link type) |
| `dep-remove`| `--number N` `--by M`                  | (nothing) — removes that link; idempotent |
| `dep-list`  | `--number N`                           | one row per issue blocking N: `number⇥title⇥state`; under `LS_JSON` an array of `{number, title, state}`. Links to another repo/project are left out |
| `dep-blocking` | `--number N`                        | the issues N blocks, same shape |
```

- add a section after `### \`issues copy\` / \`issues resync\` (dispatcher-owned)`:

```markdown
### `issues block` / `unblock` / `blockers` / `blocking` (dispatcher-owned)

"This issue is blocked by that one" (FJ-271), handled by `scripts/issue-deps` through the
dispatcher, like `copy`.

| Verb | Args | stdout |
|---|---|---|
| `block` | `--number ID --by ID [--no-status]` | `FJ-12 blocked by GH-3 (native\|text)` |
| `unblock` | `--number ID --by ID [--no-status]` | `FJ-12 no longer blocked by GH-3` (or, on stderr, that it wasn't) |
| `blockers` | `--number ID` | `id⇥title⇥state⇥native\|text` per blocker |
| `blocking` | `--number ID` | the same, per issue it blocks |

- Two issues on the same tracker use its `dep-*` verbs. On `unsupported`, and always across
  trackers, the link is a pair of signed comments: `**Blocked by GH-3**: <title>` on the blocked
  issue and `**Blocks FJ-12**: <title>` on the blocker; unblocking posts `**No longer …**`. Only
  flight-signed comments count (they are always signed; see `--signature`), and per pair the latest
  wins.
- Status, unless `--no-status`: `block` sets the tracker's `blocked` role and records
  `(was <role>)`; the last `unblock` restores that role, or `new`, or clears the status. A status
  someone changed by hand is left alone.
- `--tracker` is refused (each id names its tracker). Requires config schema 3.
```

`flight/references/json-output.md`:
- capability table: add `| \`issues-deps\` | \`issues block\`, \`unblock\`, \`blockers\`, \`blocking\`, and \`blocked_by\` on \`issues get --json\` |`;
- the issue object: add `"blocked_by": [{"id": "GH-3", "title": "…", "state": "open", "via": "text"}],  // issues get only; null in list rows and when the lookup failed` after `signature`, and a note: "**`blocked_by`** is filled by `issues get --json` only, with the same lookup `issues blockers` does. It is `null` in `list` rows, and when that lookup fails (`get` still succeeds, with a warning on stderr)."
- the verb table: add rows `| \`issues block\` | \`{number, by, via, status}\` |`, `| \`issues unblock\` | \`{number, by, removed, status}\` |`, `| \`issues blockers\` / \`blocking\` | \`{issues: [{id, title, state, via}]}\` |`;
- error codes: add `| \`unsupported\` | an adapter's \`dep-*\` verb: the backend can't record a dependency here. \`issues block\` handles it by falling back to comments |`.

`flight/GUIDE.md`: add a short section after the issue-copy section, titled `### Blocked issues`, of three or four sentences: how to `block` / `unblock`, that it uses the native relationship where the backend has one and signed comments otherwise (always across trackers), that the status moves to blocked and back unless `--no-status`, and that `working-an-issue` warns about open blockers.

`flight/CHANGELOG.md`, under `## [Unreleased]`, add an `### Added` section (above `### Fixed`):

```markdown
### Added

- **Blocked issues** (FJ-271). `flight issues block --number FJ-12 --by GH-3` records that one
  issue is blocked by another; `unblock` removes it, and `blockers` / `blocking` list the links.
  Issues on the same tracker use the backend's own relationship (GitHub issue dependencies,
  Forgejo dependencies, GitLab Premium blocking links, Jira "is blocked by" links). Where the
  backend can't, and always across trackers, the link is a pair of signed comments. By default the
  blocked issue's status moves to `blocked` and back to what it was; `--no-status` skips that.
  `issues get --json` gains `blocked_by`, and `working-an-issue` warns before starting an issue
  with an open blocker. Capability token: `issues-deps`.
```

- [ ] **Step 4: Full preflight**

Run: `./scripts/run-checks.sh && ./scripts/run-tests.sh`
Expected: `All checks passed.` and `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git -C "$WT" add flight/skills flight/references flight/GUIDE.md flight/CHANGELOG.md scripts/tests/tracker-lifecycle-skills.test.sh
git -C "$WT" commit -m "docs(FJ-271): skills, references, guide and changelog for blocked issues

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Live round trip on every rig

**Files:**
- Modify: `test-rig/forgejo/smoke.sh`, `test-rig/github/smoke.sh`, `test-rig/gitlab/smoke.sh`, `test-rig/jira/smoke.sh`

**Interfaces:**
- Consumes: each smoke script's `lsp` (runs the dispatcher in the rig's `.work`), `ok`, `no`. Confirm the names with `grep -n '^lsp()\|^ok()\|^no()' test-rig/*/smoke.sh` before editing; if a rig names them differently, use its names.

- [ ] **Step 1: Add the round trip**

In each `smoke.sh`, insert this block before the section that closes issues (Forgejo: before line ~106 `lsp issues close`; in the others, before their `issues close` step). On Jira, use the rig's own issue-creation output (a key such as `KAN-12`) as-is:

```bash
echo "── issues block / blockers / blocking / unblock (FJ-271) ──"
DA="$(lsp issues create --title "[rig] blocked" --body "dependency smoke")"
DB="$(lsp issues create --title "[rig] blocker" --body "dependency smoke")"
OUT="$(lsp issues block --number "$DA" --by "$DB" --no-status 2>&1)"
VIA="$(sed -n 's/.*(\(native\|text\))$/\1/p' <<<"$OUT" | tail -n1)"
[ -n "$VIA" ] && ok "block works ($VIA)" || no "block works" "$OUT"
OUT="$(lsp issues blockers --number "$DA")"
grep -q "blocker	open	$VIA$" <<<"$OUT" && ok "blockers lists it ($VIA)" || no "blockers lists it" "$OUT"
OUT="$(lsp issues blocking --number "$DB")"
grep -q "blocked	open	$VIA$" <<<"$OUT" && ok "blocking lists the reverse" || no "blocking lists the reverse" "$OUT"
lsp issues unblock --number "$DA" --by "$DB" --no-status >/dev/null
OUT="$(lsp issues blockers --number "$DA")"
[ -z "$OUT" ] && ok "unblock removes it" || no "unblock removes it" "$OUT"
lsp issues close --number "$DA" >/dev/null; lsp issues close --number "$DB" >/dev/null
```

On GitLab, after the `block works` line, add `echo "    gitlab tier path: $VIA (native = Premium/Ultimate, text = Free)"`.

- [ ] **Step 2: Run each rig**

For each backend `B` in `forgejo github gitlab jira`: `test-rig/$B/up.sh` (Forgejo starts a container; the others use their `.env`), then `test-rig/$B/smoke.sh`, then `test-rig/$B/down.sh`.
Expected: every check passes. Forgejo, GitHub and Jira report `native`; GitLab reports whichever its tier allows.

**If Jira's `blockers` check fails while `block` reported `native`,** the link was created the wrong way round: swap `inwardIssue` and `outwardIssue` in the Jira `dep-add` POST (Task 2, Step 5), update the comment above it and the matching assertion in `issue-deps-adapters.test.sh`, and rerun both the unit test and the rig.

**If GitLab's `block` fails instead of falling back,** record the HTTP status from the error and add it to the `400|403|422` list in the GitLab `dep-add` (Task 2, Step 4), with a matching unit test.

- [ ] **Step 3: Commit**

```bash
git -C "$WT" add test-rig/forgejo/smoke.sh test-rig/github/smoke.sh test-rig/gitlab/smoke.sh test-rig/jira/smoke.sh
git -C "$WT" commit -m "test(FJ-271): live block/unblock round trip on every rig

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Final preflight**

Run: `./scripts/run-checks.sh && ./scripts/run-tests.sh`
Expected: both pass.
