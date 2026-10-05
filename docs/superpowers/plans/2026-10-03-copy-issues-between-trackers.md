# Copy Issues Between Trackers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `flight issues copy` and `flight issues resync`, which copy one issue (title, plus optional body, comments, labels, status, footer, back-link) from any configured tracker to any other and later post the source comments the copy is missing, with a local ledger that blocks accidental second copies. Add a `copying-an-issue` skill that drives them.

**Architecture:** The dispatcher (`flight/scripts/flight`) hands both verbs to a new dispatcher-owned helper, `flight/scripts/issue-copy`, the same way it hands `branches` to `flight/scripts/branches`. The helper does every read and write by calling the dispatcher again (`$FLIGHT_SELF … --json`), each call naming its own tracker. So each side uses its own coordinates, credential and label map, and the adapters don't change. The helper records links in `<main checkout>/.flightdirector/copies.jsonl`, appending one line per step.

**Tech Stack:** bash (`set -euo pipefail`, tabs), jq, the existing bash test style (`scripts/tests/*.test.sh` with `check`/`section` helpers), shellcheck through `scripts/run-checks.sh`.

**Spec:** `docs/superpowers/specs/2026-10-03-copy-issues-between-trackers-design.md`

## Global Constraints

- **Worktree:** all work happens in `.worktrees/fj-200-copy-issue-between-trackers` on `feature/fj-200-copy-issue-between-trackers`. Every git command is `git -C "$WT" …` with `WT=/home/dave/Documents/Projects/CurrentProjects/AICrafting/flightdirector/Repos/flightdirector/.worktrees/fj-200-copy-issue-between-trackers`. Never commit to `develop`.
- **Style:** tabs, width 4; no trailing whitespace except in `.md`; exactly one final newline. File names kebab-case. Tracked scripts carry the exec bit: after creating a script, `git -C "$WT" update-index --chmod=+x <path>` and confirm `git -C "$WT" ls-files -s <path>` shows `100755`.
- **Commits:** end every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Use the `feat(FJ-200): …` / `docs(FJ-200): …` / `test(FJ-200): …` scope.
- **Scope (from the spec):** never create labels on the target. Never copy assignees or open/closed state. Never re-upload attachments. Never close the source. Resync posts **comments only**. The footer and back-link name issues by tracker ref + id only, never a URL or host, and are **off** by default. Body, comments, labels and status are **on** by default.
- **Forbidden words:** do not mention the two unrelated project/company names listed in `AGENTS.local.md` anywhere.
- **No new runtime dependencies:** bash + jq + the dispatcher only.
- **Verification gate:** before calling the work done, `./scripts/run-checks.sh && ./scripts/run-tests.sh` must pass from `$WT` (this repo's `code.preflight`).

## Review Focus

1. **Source with no body** (a Jira issue with no description, a forge issue with an empty body): the copy must still be created, with an empty body (or only the footer). This is pinned in Task 1 (FJ-14 fixture).
2. **Comment text with shell and markdown metacharacters** (`$HOME`, backticks, code fences, quotes): the comment must be posted byte-for-byte after the attribution line, never expanded or mangled. Pinned in Task 1 (comment 502 fixture).
3. **A tracker named by alias or in another case** (`--to gh`): it must resolve to the canonical ref, and the duplicate check must still match an earlier copy made with `--to GH`. Pinned in Task 1.
4. **A ledger line that doesn't parse** (a hand edit, a truncated write): it is skipped with a warning; copy, refusal and resync keep working. Pinned in Task 1.
5. **Failure partway through the comments** (network drop on comment 2 of 2): the ledger must list exactly what was posted, the error must say to run `resync`, and resync must finish the job without posting anything twice. Pinned in Task 2.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `flight/scripts/issue-copy` | create | The `copy` and `resync` verbs: argument parsing, both trackers' resolution, label/status mapping, comment posting, ledger, text/JSON output |
| `flight/scripts/flight` | modify | Route `issues copy|resync` to the helper; accept their switches under `--json`; refuse them below schema 3; add the `issues-copy` capability token |
| `scripts/tests/issue-copy.test.sh` | create | Helper tests against a stub dispatcher, plus routing tests through the real dispatcher |
| `flight/skills/copying-an-issue/SKILL.md` | create | The agent workflow: resolve, soft duplicate scan, dry-run preview, copy/resync, report |
| `flight/skills/filing-issues/SKILL.md` | modify | One pointer to the new skill |
| `scripts/tests/tracker-lifecycle-skills.test.sh` | modify | Include the new skill in the contract checks; pin its key lines |
| `flight/README.md` | modify | Skill table row |
| `flight/references/adapter-contract.md` | modify | Document the two dispatcher-owned verbs |
| `flight/references/json-output.md` | modify | `--json` shapes, `already-copied` error code, capability token |
| `flight/references/flight-setup.md` | modify | The ledger file |
| `flight/GUIDE.md`, `flight/CHANGELOG.md` | modify | User-facing docs and the Unreleased entry |

---

### Task 1: The `issues copy` verb

**Files:**
- Create: `flight/scripts/issue-copy`
- Modify: `flight/scripts/flight` (lines ~105, ~121, ~409–411, and after the `issues tracker` block at ~917)
- Test: `scripts/tests/issue-copy.test.sh`

**Interfaces:**
- Consumes (existing dispatcher verbs, each called with `--json`):
  - `issues resolve --number ID` → `{tracker, number, qualified, display, branchPrefix}`
  - `issues tracker --tracker REF` → the tracker entry (`.ref`, `.labels.status`)
  - `issues get --number QUALIFIED` → the issue object (`.title`, `.body` with the signature already removed, `.labels`, `.status` = role or null)
  - `issues comments --number QUALIFIED` → `[{id, author, created, body, …}]`, oldest first
  - `labels list --tracker REF` → `[{name, …}]`
  - `issues create --tracker REF --title T --body-file F --label L…` → the new issue object (`.qualified`)
  - `issues comment --number QUALIFIED --body-file F` (called **without** `--json`; it prints nothing)
- Produces (Task 2 builds on these names inside `issue-copy`):
  - globals `SRC_Q SRC_D SRC_T DST_T DST_Q DST_D COMMENTS COMPONENTS HANDLED POSTED DRY MODEL_ARGS LEDGER TMP`
  - functions `fail CODE MSG`, `die MSG`, `fl ARGS…`, `ledger_find SOURCE_Q TRACKER_REF`, `ledger_write TARGET_Q HANDLED_JSON`, `attributed COMMENT_JSON`, `post_comments TARGET_Q HANDLED_JSON`, `report RESULT_JSON TEXT`
  - ledger line shape: `{"source":"FJ-12","target":"GH-100","at":"<ISO-8601Z>","components":["body",…],"comments":["501",…]}`
  - `--json` result: `{"source","target","copied":{"body":bool,"comments":N,"labels":[…],"status":role|null,"footer":bool,"backLink":bool},"skipped":{"labels":[…],"status":role|null}}`
  - error code `already-copied`

- [ ] **Step 1: Write the test file with the stub dispatcher and the copy tests**

Create `scripts/tests/issue-copy.test.sh`:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# `flight issues copy` / `issues resync` (FJ-200). The helper is driven through a stub
# dispatcher (FLIGHT_SELF), which keeps two trackers' issues, comments and labels as JSON
# files under $STATE. That stub is exactly the seam the helper uses in production, where
# FLIGHT_SELF is the real dispatcher. The routing section at the end runs the REAL dispatcher;
# it uses only local verbs, so no network.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_SELF FLIGHT_REPO_ROOT FLIGHT_ERROR_FILE LS_JSON FLIGHT_MODEL LS_MODEL
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
HELPER="$REPO_ROOT/flight/scripts/issue-copy"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }
yes() { "$@" >/dev/null 2>&1 && echo 1 || echo 0; }

STUB="$SANDBOX/flight-stub"
cat >"$STUB" <<'SH'
#!/usr/bin/env bash
# Stub dispatcher: trackers live under $STATE/<REF>/. Every call is logged to $STATE/calls.log.
# FAIL_COMMENT_AT=N makes the Nth `issues comment` of this state fail.
set -euo pipefail
S="${STATE:?}"; printf '%s\n' "$*" >>"$S/calls.log"
group="$1" verb="$2"; shift 2
tracker="" number="" title="" body_file=""; labels=()
while [ $# -gt 0 ]; do case "$1" in
	--tracker) tracker="$2"; shift 2 ;;
	--number) number="$2"; shift 2 ;;
	--title) title="$2"; shift 2 ;;
	--body-file) body_file="$2"; shift 2 ;;
	--label) labels+=("$2"); shift 2 ;;
	--model) shift 2 ;;
	--json) shift ;;
	*) echo "stub: unexpected argument $1" >&2; exit 2 ;;
esac; done
# A qualified id (FJ-12) names its tracker; otherwise --tracker, else the default FJ.
case "$number" in *-*) tracker="${number%%-*}"; number="${number##*-}" ;; esac
tracker="$(printf '%s' "${tracker:-FJ}" | tr '[:lower:]' '[:upper:]')"
[ "$tracker" != GITHUB ] || tracker=GH   # GH's alias
if [ ! -f "$S/$tracker/tracker.json" ]; then
	echo '{"error":{"code":"not-found","message":"stub: unknown tracker"}}'
	echo "stub: unknown tracker $tracker" >&2; exit 1
fi
case "$group/$verb" in
	issues/resolve) jq -cn --arg t "$tracker" --arg n "$number" \
		'{tracker:$t, number:$n, qualified:"\($t)-\($n)", display:"\($t)-\($n)", branchPrefix:"\($t|ascii_downcase)-\($n)"}' ;;
	issues/tracker) cat "$S/$tracker/tracker.json" ;;
	issues/get) cat "$S/$tracker/$number.json" ;;
	issues/comments) cat "$S/$tracker/$number.comments.json" 2>/dev/null || echo '[]' ;;
	labels/list) cat "$S/$tracker/labels.json" ;;
	issues/create)
		n="$(cat "$S/$tracker/next" 2>/dev/null || echo 100)"; echo $((n + 1)) >"$S/$tracker/next"
		jq -cn --arg t "$title" --rawfile b "$body_file" '{title:$t, body:$b, labels:$ARGS.positional}' \
			--args ${labels[@]+"${labels[@]}"} >"$S/$tracker/created-$n.json"
		jq -cn --arg t "$tracker" --arg n "$n" '{number:$n, tracker:$t, qualified:"\($t)-\($n)"}' ;;
	issues/comment)
		posted=$(( $(cat "$S/posted-count" 2>/dev/null || echo 0) + 1 )); echo "$posted" >"$S/posted-count"
		if [ "${FAIL_COMMENT_AT:-0}" = "$posted" ]; then echo "stub: comment failed" >&2; exit 1; fi
		jq -cn --rawfile b "$body_file" '{body:$b}' >>"$S/$tracker/$number.posted.jsonl" ;;
	*) echo "stub: unexpected $group $verb" >&2; exit 2 ;;
esac
SH
chmod +x "$STUB"

R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector"
LEDGER="$R/.flightdirector/copies.jsonl"
export STATE="$SANDBOX/state"

# fixture — a fresh pair of trackers and an empty ledger. FJ spells to-test "status/to test"
# and has a qa role; GH spells it "status/to-test" and has no qa role.
fixture() {
	rm -rf "$STATE" "$LEDGER"; mkdir -p "$STATE/FJ" "$STATE/GH"
	echo '{"ref":"FJ","labels":{"status":{"new":false,"in-progress":"status/in progress","to-test":"status/to test","qa":"status/qa"}}}' >"$STATE/FJ/tracker.json"
	echo '{"ref":"GH","labels":{"status":{"new":"status/new","in-progress":"status/in-progress","to-test":"status/to-test"}}}' >"$STATE/GH/tracker.json"
	echo '[{"name":"bug"},{"name":"area/app"},{"name":"status/to test"},{"name":"status/qa"}]' >"$STATE/FJ/labels.json"
	echo '[{"name":"bug"},{"name":"status/to-test"},{"name":"status/new"}]' >"$STATE/GH/labels.json"
	echo '{"number":"12","tracker":"FJ","qualified":"FJ-12","title":"Fix login","state":"open","status":"to-test","labels":["bug","area/app","status/to test"],"body":"The login redirect loops.","signature":null}' >"$STATE/FJ/12.json"
	jq -n '[{id:"501", author:"dave", created:"2026-09-20T10:00:00Z", body:"Repro: click login."},
		{id:"502", author:"aaron", created:"2026-09-21T11:00:00Z", body:"Same with `$HOME` set:\n```\necho \"$PATH\"\n```"}]' >"$STATE/FJ/12.comments.json"
	echo '{"number":"13","tracker":"FJ","qualified":"FJ-13","title":"Ship it","state":"closed","status":"qa","labels":["status/qa"],"body":"Done.","signature":null}' >"$STATE/FJ/13.json"
	echo '{"number":"14","tracker":"FJ","qualified":"FJ-14","title":"No description","state":"open","status":null,"labels":[],"body":null,"signature":null}' >"$STATE/FJ/14.json"
}
# hc ARGS… — run the helper; sets RC, and OUT/ERR to its stdout/stderr.
hc() {
	set +e
	OUT="$(cd "$R" && FLIGHT_REPO_ROOT="$R" FLIGHT_SELF="$STUB" "$HELPER" "$@" 2>"$SANDBOX/err")"; RC=$?
	set -e
	ERR="$(cat "$SANDBOX/err")"
}
created() { cat "$STATE/GH/created-$1.json"; }
posted() { jq -s . "$STATE/$1/$2.posted.jsonl" 2>/dev/null || echo '[]'; }
last_ledger() { tail -n1 "$LEDGER"; }

section "copy: defaults"
fixture
hc copy --from FJ-12 --to GH
check "prints the copy's id" "$([ "$RC" = 0 ] && [ "$OUT" = GH-100 ] && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"
check "title and body are copied" \
	"$(yes jq -e '.title == "Fix login" and (.body | startswith("The login redirect loops."))' <<<"$(created 100)")" "$(created 100)"
check "matching plain labels and the mapped status label are applied; missing ones are not" \
	"$(yes jq -e '(.labels | sort) == ["bug", "status/to-test"]' <<<"$(created 100)")" "$(created 100)"
check "the skipped label is reported on stderr" "$(grep -q 'area/app' <<<"$ERR" && echo 1 || echo 0)" "$ERR"
check "comments are posted oldest first with an attribution line" \
	"$(yes jq -e 'length == 2 and (.[0].body | startswith("**dave** commented on 2026-09-20:\n\nRepro: click login.")) and (.[1].body | startswith("**aaron** commented on 2026-09-21:"))' <<<"$(posted GH 100)")" "$(posted GH 100)"
check "comment text with shell and markdown metacharacters arrives verbatim" \
	"$(yes jq -e '.[1].body | contains("Same with `$HOME` set:\n```\necho \"$PATH\"\n```")' <<<"$(posted GH 100)")" "$(posted GH 100)"
check "the ledger records the link and every copied comment" \
	"$(yes jq -e '.source == "FJ-12" and .target == "GH-100" and .comments == ["501","502"] and .components == ["body","comments","labels","status"]' <<<"$(last_ledger)")" "$(last_ledger)"
check "nothing is written back to the source by default" "$([ ! -e "$STATE/FJ/12.posted.jsonl" ] && echo 1 || echo 0)"
check "the source's state is never copied (no close/reopen call)" "$(grep -qE 'issues (close|reopen)' "$STATE/calls.log" && echo 0 || echo 1)"

section "copy: duplicate prevention"
echo 'not json' >>"$LEDGER"
hc copy --from FJ-12 --to GH
check "a second copy to the same tracker is refused, naming the first" \
	"$([ "$RC" = 1 ] && grep -q 'already copied to GH-100' <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"
check "an unreadable ledger line is skipped with a warning" "$(grep -q 'unreadable line' <<<"$ERR" && echo 1 || echo 0)" "$ERR"
check "no second issue was created" "$([ ! -e "$STATE/GH/created-101.json" ] && echo 1 || echo 0)"
hc copy --from FJ-12 --to gh
check "the refusal holds when the tracker is named in another case" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
hc copy --from FJ-12 --to github
check "…and by its alias" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
set +e
(cd "$R" && FLIGHT_REPO_ROOT="$R" FLIGHT_SELF="$STUB" LS_JSON=1 FLIGHT_ERROR_FILE="$SANDBOX/envelope" "$HELPER" copy --from FJ-12 --to GH >/dev/null 2>&1)
set -e
check "--json failures record the already-copied code" "$(yes jq -e '.error.code == "already-copied"' "$SANDBOX/envelope")" "$(cat "$SANDBOX/envelope" 2>/dev/null)"
hc copy --from FJ-12 --to GH --force
check "--force makes a second copy" "$([ "$RC" = 0 ] && [ "$OUT" = GH-101 ] && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"

section "copy: components off and opt-ins on"
fixture
hc copy --from FJ-12 --to GH --no-body --no-comments --no-labels --no-status --footer --back-link
check "the copy succeeds" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC err=$ERR"
check "only the footer is in the body" "$(yes jq -e '.body == "Copied from FJ-12\n"' <<<"$(created 100)")" "$(created 100)"
check "no labels are passed (the target's own starting status is left to the dispatcher)" "$(yes jq -e '.labels == []' <<<"$(created 100)")" "$(created 100)"
check "no comments are posted" "$(yes jq -e 'length == 0' <<<"$(posted GH 100)")" "$(posted GH 100)"
check "the existing comments are recorded as handled" "$(yes jq -e '.comments == ["501","502"] and .components == ["footer","back-link"]' <<<"$(last_ledger)")" "$(last_ledger)"
check "the back-link is posted on the source" "$(yes jq -e 'length == 1 and (.[0].body | startswith("Copied to GH-100"))' <<<"$(posted FJ 12)")" "$(posted FJ 12)"

section "copy: status the target can't hold, empty bodies, bad targets"
fixture
set +e
OUT="$(cd "$R" && FLIGHT_REPO_ROOT="$R" FLIGHT_SELF="$STUB" LS_JSON=1 "$HELPER" copy --from FJ-13 --to GH 2>"$SANDBOX/err")"; RC=$?
set -e
check "a status role the target lacks is skipped and reported in --json" \
	"$(yes jq -e '.copied.status == null and .skipped.status == "qa" and .target == "GH-100" and .source == "FJ-13"' <<<"$OUT")" "rc=$RC out=$OUT"
check "…and no status label is passed" "$(yes jq -e '.labels == []' <<<"$(created 100)")" "$(created 100)"
hc copy --from FJ-14 --to GH
check "a source with no body still copies, with an empty body" \
	"$([ "$RC" = 0 ] && jq -e '.body == ""' <<<"$(created 101)" >/dev/null && echo 1 || echo 0)" "rc=$RC err=$ERR $(created 101 2>/dev/null)"
hc copy --from FJ-12 --to FJ
check "copying to the source's own tracker is a usage error" \
	"$([ "$RC" = 1 ] && grep -q 'another tracker' <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"
hc copy --from FJ-12 --to NOPE
check "an unknown target tracker fails before anything is written" \
	"$([ "$RC" = 1 ] && ! grep -q 'issues create' "$STATE/calls.log" && echo 1 || echo 0)" "rc=$RC"
hc copy --from FJ-12
check "--to is required" "$([ "$RC" = 1 ] && grep -q usage <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"

section "routing through the real dispatcher"
D="$SANDBOX/disp"; mkdir -p "$D/.flightdirector"; git -C "$D" init -q
jq -n '{schemaVersion: 3,
	code: {backend:"forgejo", api:"https://code.example.com/api/v1", owner:"acme", repo:"widget", stages:[{name:"main"}]},
	issues: {backend:"requires-newer-flight"},
	issueTrackers: [
		{ref:"FJ", name:"Code", default:true, backend:"forgejo", api:"https://code.example.com/api/v1", owner:"acme", repo:"widget", credentialRef:"code"},
		{ref:"GH", name:"Public", default:false, backend:"github", api:"https://api.github.com", owner:"acme", repo:"widget"}]}' >"$D/.flightdirector/config.json"
set +e
OUT="$(cd "$D" && "$DISP" issues copy --from FJ-12 --to fj --dry-run --json 2>/dev/null)"; RC=$?
set -e
check "the dispatcher routes copy to the helper and keeps --json after a switch" \
	"$([ "$RC" = 1 ] && jq -e '.error.code == "usage" and (.error.message | test("another tracker"))' <<<"$OUT" >/dev/null && echo 1 || echo 0)" "rc=$RC out=$OUT"
set +e
OUT="$(cd "$D" && "$DISP" issues copy --from FJ-12 --to GH --tracker GH 2>&1)"; RC=$?
set -e
check "--tracker is refused (the trackers are --from and --to)" "$([ "$RC" = 1 ] && grep -q -- '--from/--to' <<<"$OUT" && echo 1 || echo 0)" "rc=$RC out=$OUT"
check "the capability token is advertised" "$("$DISP" capabilities | grep -qx issues-copy && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then make it executable: `chmod +x scripts/tests/issue-copy.test.sh`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash "$WT/scripts/tests/issue-copy.test.sh"`
Expected: FAIL. Every helper check fails (`issue-copy: No such file or directory`); the routing checks fail with an adapter "unknown verb" error.

- [ ] **Step 3: Create the helper**

Create `flight/scripts/issue-copy`:

```bash
#!/usr/bin/env bash
#
# flight `issues copy` / `issues resync` — copy one issue from a named tracker to another, and
# later post the source comments its copy is missing (FJ-200).
#
#   flight issues copy   --from ID --to TRACKER [--no-body] [--no-comments] [--no-labels]
#                        [--no-status] [--footer] [--back-link] [--force] [--dry-run] [--model ID]
#   flight issues resync --from ID --to TRACKER [--dry-run] [--model ID]
#
# Dispatcher-owned, like `branches`: every read and write goes back through the dispatcher
# ($FLIGHT_SELF), each call naming its own tracker, so each side uses its own coordinates,
# credential and label map and every backend pair works without adapter changes. Links live in
# the git-ignored ledger .flightdirector/copies.jsonl under the main checkout: append-only, one
# record per step, the latest record for a source and target tracker wins. Under --json
# (LS_JSON=1) the result is one JSON object and a failure is recorded in FLIGHT_ERROR_FILE.
# Invoked by the dispatcher, which exports FLIGHT_REPO_ROOT and FLIGHT_SELF.
#
# Design: docs/superpowers/specs/2026-10-03-copy-issues-between-trackers-design.md
set -euo pipefail

# Windows shims (jq CRLF, path form); a no-op elsewhere.
# shellcheck source-path=SCRIPTDIR source=_portable.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_portable.sh"

: "${FLIGHT_REPO_ROOT:?FLIGHT_REPO_ROOT not set (dispatcher must export it)}"
: "${FLIGHT_SELF:?FLIGHT_SELF not set (dispatcher must export it)}"

VERB="${1:-}"; [ $# -eq 0 ] || shift
case "$VERB" in copy|resync) ;; *) echo "flight issues: unknown copy verb '$VERB' (expected: copy resync)" >&2; exit 1 ;; esac
LEDGER="$FLIGHT_REPO_ROOT/.flightdirector/copies.jsonl"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/flight-copy.XXXXXX")"
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

FROM=""; TO=""; DRY=0; FORCE=0; MODEL_ARGS=()
WANT_BODY=1; WANT_COMMENTS=1; WANT_LABELS=1; WANT_STATUS=1; WANT_FOOTER=0; WANT_BACKLINK=0
while [ $# -gt 0 ]; do
	case "$1" in
		--from)  [ $# -ge 2 ] || die "--from needs an issue id"; FROM="$2"; shift 2 ;;
		--to)    [ $# -ge 2 ] || die "--to needs a tracker ref"; TO="$2"; shift 2 ;;
		--model) [ $# -ge 2 ] || die "--model needs a model id"; MODEL_ARGS=(--model "$2"); shift 2 ;;
		--dry-run) DRY=1; shift ;;
		--no-body|--no-comments|--no-labels|--no-status|--footer|--back-link|--force)
			[ "$VERB" = copy ] || die "$1 applies to 'issues copy' only"
			case "$1" in
				--no-body) WANT_BODY=0 ;;
				--no-comments) WANT_COMMENTS=0 ;;
				--no-labels) WANT_LABELS=0 ;;
				--no-status) WANT_STATUS=0 ;;
				--footer) WANT_FOOTER=1 ;;
				--back-link) WANT_BACKLINK=1 ;;
				--force) FORCE=1 ;;
			esac
			shift ;;
		*) die "unknown argument '$1'" ;;
	esac
done
[ -n "$FROM" ] && [ -n "$TO" ] || die "usage: flight issues $VERB --from ID --to TRACKER …"

# ledger_find SOURCE_Q TRACKER_REF — the latest ledger record of SOURCE copied to that tracker,
# or nothing. Lines that don't parse are skipped with a warning; the file is never rewritten.
ledger_find() {
	[ -f "$LEDGER" ] || return 0
	local line
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line"; then
			printf '%s\n' "$line"
		else
			echo "flight issues $VERB: warning — skipping an unreadable line in $LEDGER" >&2
		fi
	done <"$LEDGER" | jq -c -s --arg s "$1" --arg t "$2" '
		[.[] | select(.source == $s and ((.target // "") | split("-")[0] | ascii_downcase) == ($t | ascii_downcase))]
		| last // empty'
}

# ledger_write TARGET_Q HANDLED_JSON — append the pair's current state (COMPONENTS is global).
ledger_write() {
	mkdir -p "$(dirname "$LEDGER")"
	jq -cn --arg s "$SRC_Q" --arg t "$1" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson c "$COMPONENTS" --argjson ids "$2" \
		'{source:$s, target:$t, at:$at, components:$c, comments:$ids}' >>"$LEDGER"
}

# attributed COMMENT_JSON — the comment as it is posted on the copy: who wrote it and when (the
# copy is posted by the target token's user), then the original text, untouched.
attributed() {
	jq -r '"**\(.author // "someone")** commented\(if (.created // "") != "" then " on \(.created[0:10])" else "" end):\n\n\(.body // "")"' <<<"$1"
}

# post_comments TARGET_Q HANDLED_JSON — post every source comment (COMMENTS) not in HANDLED to
# TARGET, oldest first, recording each in the ledger as it lands. Sets POSTED and HANDLED.
post_comments() {
	local target="$1" c id total
	HANDLED="$2"; POSTED=0
	total="$(jq --argjson h "$HANDLED" '[.[] | select(.id as $i | $h | any(.[]; . == $i) | not)] | length' <<<"$COMMENTS")"
	while IFS= read -r c; do
		[ -n "$c" ] || continue
		id="$(jq -r '.id' <<<"$c")"
		attributed "$c" >"$TMP/comment.md"
		"$FLIGHT_SELF" issues comment --number "$target" --body-file "$TMP/comment.md" \
			${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} >/dev/null \
			|| fail backend "posting source comment $id to $target failed after $POSTED of $total — run 'flight issues resync --from $SRC_Q --to $DST_T' to post the rest"
		HANDLED="$(jq -c --arg id "$id" '. + [$id]' <<<"$HANDLED")"
		ledger_write "$target" "$HANDLED"
		POSTED=$((POSTED + 1))
	done < <(jq -c --argjson h "$HANDLED" '.[] | select(.id as $i | $h | any(.[]; . == $i) | not)' <<<"$COMMENTS")
}

# report RESULT_JSON TEXT — the --json object, or TEXT on stdout with any skips on stderr.
report() {
	if [ -n "${LS_JSON:-}" ]; then printf '%s\n' "$1"; return 0; fi
	printf '%s\n' "$2"
	jq -r --arg v "$VERB" --arg t "$DST_T" '
		(.skipped.labels // []) as $l | (.skipped.status // null) as $s
		| (if ($l | length) > 0 then "flight issues \($v): skipped labels \($t) does not have: \($l | join(", "))" else empty end),
		  (if $s != null then "flight issues \($v): skipped status \($s) — \($t) has no label for that role" else empty end)' <<<"$1" >&2
}

# Both ends, resolved once. Refs compare case-insensitively; DST_T is the canonical ref.
SRC="$(fl issues resolve --number "$FROM")"
SRC_Q="$(jq -r '.qualified' <<<"$SRC")"; SRC_D="$(jq -r '.display' <<<"$SRC")"; SRC_T="$(jq -r '.tracker' <<<"$SRC")"
SRC_TRACKER="$(fl issues tracker --tracker "$SRC_T")"
DST_TRACKER="$(fl issues tracker --tracker "$TO")"
DST_T="$(jq -r '.ref' <<<"$DST_TRACKER")"
[ "$(printf '%s' "$SRC_T" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$DST_T" | tr '[:upper:]' '[:lower:]')" ] \
	|| die "$SRC_D is already on tracker $DST_T — --to must name another tracker"
DST_Q=""; DST_D=""; COMMENTS='[]'; COMPONENTS='[]'; HANDLED='[]'; POSTED=0

copy_issue() {
	local existing issue dst_labels split='{"apply":[],"skip":[]}' role status_label="" skip_status="" applied_status="" l
	existing="$(ledger_find "$SRC_Q" "$DST_T")"
	if [ -n "$existing" ] && [ "$FORCE" = 0 ]; then
		fail already-copied "$SRC_D was already copied to $(jq -r '.target' <<<"$existing") — run 'flight issues resync --from $SRC_Q --to $DST_T' to bring it up to date, or pass --force for a second copy"
	fi
	issue="$(fl issues get --number "$SRC_Q")"
	COMMENTS="$(fl issues comments --number "$SRC_Q")"

	# Body, then the optional footer (ref + id only — never a URL).
	if [ "$WANT_BODY" = 1 ]; then jq -j '.body // ""' <<<"$issue" >"$TMP/body.md"; else : >"$TMP/body.md"; fi
	if [ "$WANT_FOOTER" = 1 ]; then
		if [ -s "$TMP/body.md" ]; then printf '\n\n' >>"$TMP/body.md"; fi
		printf 'Copied from %s\n' "$SRC_D" >>"$TMP/body.md"
	fi

	if [ "$WANT_LABELS" = 1 ] || [ "$WANT_STATUS" = 1 ]; then
		dst_labels="$(fl labels list --tracker "$DST_T")"
		dst_labels="$(jq -c '[.[].name]' <<<"$dst_labels")"
	fi
	# Plain labels only: the source's status labels travel through the status mapping. A name
	# the target doesn't have is skipped — labels are never created on the target.
	if [ "$WANT_LABELS" = 1 ]; then
		split="$(jq -c --argjson src "$SRC_TRACKER" --argjson have "$dst_labels" '
			[($src.labels.status // {})[] | strings] as $status
			| [(.labels // [])[] | select(. as $l | $status | any(.[]; . == $l) | not)]
			| {apply: map(select(. as $l | $have | any(.[]; . == $l))),
			   skip:  map(select(. as $l | $have | any(.[]; . == $l) | not))}' <<<"$issue")"
	fi
	# Status by role: source label → role → the target's label for that role (if it exists there).
	role="$(jq -r '.status // empty' <<<"$issue")"
	if [ "$WANT_STATUS" = 1 ] && [ -n "$role" ]; then
		status_label="$(jq -r --arg r "$role" '.labels.status[$r] // empty | strings' <<<"$DST_TRACKER")"
		if [ -n "$status_label" ] && jq -e --arg l "$status_label" 'any(.[]; . == $l)' <<<"$dst_labels" >/dev/null; then
			applied_status="$role"
		else
			status_label=""; skip_status="$role"
		fi
	fi

	COMPONENTS="$(printf '%s\n' "body:$WANT_BODY" "comments:$WANT_COMMENTS" "labels:$WANT_LABELS" \
		"status:$WANT_STATUS" "footer:$WANT_FOOTER" "back-link:$WANT_BACKLINK" \
		| jq -R -s -c 'split("\n") | map(select(endswith(":1")) | rtrimstr(":1"))')"

	local args=(issues create --tracker "$DST_T" --title "$(jq -r '.title' <<<"$issue")" --body-file "$TMP/body.md")
	while IFS= read -r l; do
		if [ -n "$l" ]; then args+=(--label "$l"); fi
	done < <(jq -r '.apply[]' <<<"$split")
	if [ -n "$status_label" ]; then args+=(--label "$status_label"); fi
	NEW="$(fl "${args[@]}" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"})"
	DST_Q="$(jq -r '.qualified' <<<"$NEW")"
	DST_D="$(fl issues resolve --number "$DST_Q")"
	DST_D="$(jq -r '.display' <<<"$DST_D")"

	# Record the link before anything else can fail. --no-comments marks today's comments
	# handled, so a later resync only brings comments added after the copy.
	if [ "$WANT_COMMENTS" = 1 ]; then HANDLED='[]'; else HANDLED="$(jq -c '[.[].id]' <<<"$COMMENTS")"; fi
	ledger_write "$DST_Q" "$HANDLED"
	POSTED=0
	if [ "$WANT_COMMENTS" = 1 ]; then post_comments "$DST_Q" "$HANDLED"; fi

	if [ "$WANT_BACKLINK" = 1 ]; then
		printf 'Copied to %s\n' "$DST_D" >"$TMP/back-link.md"
		"$FLIGHT_SELF" issues comment --number "$SRC_Q" --body-file "$TMP/back-link.md" \
			${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} >/dev/null \
			|| fail backend "the copy $DST_D was made, but posting the back-link on $SRC_D failed"
	fi

	RESULT="$(jq -cn --arg s "$SRC_Q" --arg t "$DST_Q" --argjson split "$split" --argjson n "$POSTED" \
		--argjson body "$WANT_BODY" --argjson footer "$WANT_FOOTER" --argjson back "$WANT_BACKLINK" \
		--arg st "$applied_status" --arg skst "$skip_status" '
		{source: $s, target: $t,
		 copied: {body: ($body == 1), comments: $n, labels: $split.apply,
		          status: (if $st == "" then null else $st end), footer: ($footer == 1), backLink: ($back == 1)},
		 skipped: {labels: $split.skip, status: (if $skst == "" then null else $skst end)}}')"
	report "$RESULT" "$DST_D"
}

case "$VERB" in
	copy) copy_issue ;;
	resync) die "resync is not implemented yet" ;;
esac
```

Make it executable and tracked as such:

```bash
chmod +x "$WT/flight/scripts/issue-copy"
git -C "$WT" add flight/scripts/issue-copy
git -C "$WT" update-index --chmod=+x flight/scripts/issue-copy
git -C "$WT" ls-files -s flight/scripts/issue-copy   # expect 100755
```

- [ ] **Step 4: Route the verbs in the dispatcher**

In `flight/scripts/flight`:

1. Add `issues/copy issues/resync` to `JSON_VERBS` (line ~105):

```bash
JSON_VERBS=(issues/resolve issues/tracker issues/list issues/get issues/comments labels/list labels/statuses issues/create issues/comment issues/set-status issues/copy issues/resync)
```

2. Teach the `--json` scanner the new switches, so `--dry-run --json` doesn't treat `--json` as `--dry-run`'s value (line ~121):

```bash
					--no-status|--no-signature|--all-trackers|--no-body|--no-comments|--no-labels|--footer|--back-link|--force|--dry-run) ;;
```

3. Refuse the verbs below schema 3, next to `resolve`/`tracker` (line ~411):

```bash
			|| { [ "$group" = issues ] && { [ "$verb" = resolve ] || [ "$verb" = tracker ] || [ "$verb" = copy ] || [ "$verb" = resync ]; }; }
```

4. Directly after the `issues tracker` block (the one that ends `tracker_coded not-found select … exit 0` / `fi`, ~line 917), add:

```bash
	# `issues copy|resync --from ID --to TRACKER` (FJ-200) — dispatcher-owned, like `branches`:
	# the helper reads and writes both trackers back through this dispatcher, one tracker per
	# call, so no adapter is involved here. Links live in .flightdirector/copies.jsonl.
	if [ "$group" = issues ] && { [ "$verb" = copy ] || [ "$verb" = resync ]; }; then
		[ -z "$tracker_selector" ] || die "issues $verb: name the trackers with --from/--to, not --tracker"
		json_finish=""; json_tracker=""
		export FLIGHT_REPO_ROOT="$repo_root" FLIGHT_SELF="$SELF_DIR/flight"
		handoff "$SELF_DIR/issue-copy" "$verb" "$@"
	fi
```

5. Add the capability token (line ~47):

```bash
CAPABILITIES=(version capabilities json-errors issues-json labels-json write-json issues-paging issues-copy)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash "$WT/scripts/tests/issue-copy.test.sh"`
Expected: every check ✓, `Failed: 0`.

If the routing check fails because `handoff` under `--json` expects variables that aren't set at this point, read `handoff()` (~line 307) and set any of them to `""` in the new block, just as `json_finish`/`json_tracker` are set there.

- [ ] **Step 6: Lint**

Run: `cd "$WT" && ./scripts/run-checks.sh`
Expected: pass. Fix any shellcheck findings in `issue-copy` or the test file in place. Don't add blanket disables: use a targeted `# shellcheck disable=SCxxxx  # reason` only where the existing code uses the same idiom.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add flight/scripts/issue-copy flight/scripts/flight scripts/tests/issue-copy.test.sh
git -C "$WT" update-index --chmod=+x scripts/tests/issue-copy.test.sh
git -C "$WT" commit -m "feat(FJ-200): flight issues copy between named trackers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `issues resync`, partial-failure recovery and `--dry-run`

**Files:**
- Modify: `flight/scripts/issue-copy`
- Test: `scripts/tests/issue-copy.test.sh` (new sections before `section "routing through the real dispatcher"`)

**Interfaces:**
- Consumes (from Task 1): `fail`, `die`, `fl`, `ledger_find`, `post_comments`, `report`, globals `SRC_Q SRC_D DST_T DST_Q COMMENTS COMPONENTS POSTED DRY WANT_*`.
- Produces:
  - `resync` text output: the number of comments posted (`0` = up to date). `--json`: `{"source","target","copied":{"comments":N},"skipped":{}}`.
  - `--dry-run` text output: a plan whose first line contains `(dry run`. `--json`: the copy result shape plus `"dryRun": true` and `"target": null` for copy (the copy's qualified id for resync). Nothing is written: no create, no comment, no ledger line.
  - error code `not-found` when resync finds no ledger record.

- [ ] **Step 1: Add the failing tests**

Insert before `section "routing through the real dispatcher"` in `scripts/tests/issue-copy.test.sh`:

```bash
section "resync"
fixture
hc copy --from FJ-12 --to GH
jq '. + [{id:"503", author:"dave", created:"2026-09-22T09:00:00Z", body:"Fixed upstream."}]' "$STATE/FJ/12.comments.json" >"$SANDBOX/c" \
	&& mv "$SANDBOX/c" "$STATE/FJ/12.comments.json"
hc resync --from FJ-12 --to GH
check "resync posts only the new source comment" \
	"$([ "$RC" = 0 ] && [ "$OUT" = 1 ] && jq -e 'length == 3 and (.[2].body | contains("Fixed upstream."))' <<<"$(posted GH 100)" >/dev/null && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"
check "…and records it" "$(yes jq -e '.comments == ["501","502","503"] and .target == "GH-100"' <<<"$(last_ledger)")" "$(last_ledger)"
hc resync --from FJ-12 --to GH
check "an up-to-date copy posts nothing" \
	"$([ "$RC" = 0 ] && [ "$OUT" = 0 ] && jq -e 'length == 3' <<<"$(posted GH 100)" >/dev/null && echo 1 || echo 0)" "rc=$RC out=$OUT"
hc resync --from FJ-13 --to GH
check "resync without a recorded copy is not-found" \
	"$([ "$RC" = 1 ] && grep -q 'no copy of FJ-13 on GH' <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"
hc resync --from FJ-12 --to GH --no-body
check "copy-only flags are refused on resync" "$([ "$RC" = 1 ] && grep -q "applies to 'issues copy' only" <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"

section "resync after --no-comments"
fixture
hc copy --from FJ-12 --to GH --no-comments
jq '. + [{id:"503", author:"dave", created:"2026-09-22T09:00:00Z", body:"Fixed upstream."}]' "$STATE/FJ/12.comments.json" >"$SANDBOX/c" \
	&& mv "$SANDBOX/c" "$STATE/FJ/12.comments.json"
hc resync --from FJ-12 --to GH
check "only comments added after the copy are brought over" \
	"$([ "$OUT" = 1 ] && jq -e 'length == 1 and (.[0].body | contains("Fixed upstream."))' <<<"$(posted GH 100)" >/dev/null && echo 1 || echo 0)" "out=$OUT $(posted GH 100)"

section "a copy that fails partway is finished by resync"
fixture
export FAIL_COMMENT_AT=2   # exported, not a prefix: a prefix on a function call need not reach the stub
hc copy --from FJ-12 --to GH
unset FAIL_COMMENT_AT
check "the failure says how to finish" "$([ "$RC" = 1 ] && grep -q "after 1 of 2" <<<"$ERR" && grep -q 'issues resync --from FJ-12 --to GH' <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"
check "the ledger holds exactly what was posted" "$(yes jq -e '.comments == ["501"]' <<<"$(last_ledger)")" "$(last_ledger)"
hc resync --from FJ-12 --to GH
check "resync posts the rest, nothing twice" \
	"$([ "$OUT" = 1 ] && jq -e 'length == 2 and (.[0].body | contains("Repro")) and (.[1].body | contains("Same with"))' <<<"$(posted GH 100)" >/dev/null && echo 1 || echo 0)" "out=$OUT $(posted GH 100)"

section "dry run"
fixture
hc copy --from FJ-12 --to GH --dry-run
check "copy --dry-run prints a plan" "$([ "$RC" = 0 ] && grep -q '(dry run' <<<"$OUT" && grep -q 'area/app' <<<"$OUT" && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"
check "…and writes nothing" \
	"$([ ! -e "$LEDGER" ] && ! grep -qE 'issues (create|comment)' "$STATE/calls.log" && echo 1 || echo 0)" "$(cat "$STATE/calls.log")"
set +e
OUT="$(cd "$R" && FLIGHT_REPO_ROOT="$R" FLIGHT_SELF="$STUB" LS_JSON=1 "$HELPER" copy --from FJ-12 --to GH --dry-run 2>/dev/null)"
set -e
check "copy --dry-run --json is the result shape, marked as a dry run" \
	"$(yes jq -e '.dryRun == true and .target == null and .copied.comments == 2 and .copied.labels == ["bug"] and .copied.status == "to-test" and .skipped.labels == ["area/app"]' <<<"$OUT")" "$OUT"
hc copy --from FJ-12 --to GH
jq '. + [{id:"503", author:"dave", created:"2026-09-22T09:00:00Z", body:"x"}]' "$STATE/FJ/12.comments.json" >"$SANDBOX/c" \
	&& mv "$SANDBOX/c" "$STATE/FJ/12.comments.json"
before="$(wc -l <"$LEDGER")"
hc resync --from FJ-12 --to GH --dry-run
check "resync --dry-run counts what it would post and writes nothing" \
	"$([ "$RC" = 0 ] && grep -q '1 comment' <<<"$OUT" && [ "$(wc -l <"$LEDGER")" = "$before" ] && jq -e 'length == 2' <<<"$(posted GH 100)" >/dev/null && echo 1 || echo 0)" "rc=$RC out=$OUT"
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `bash "$WT/scripts/tests/issue-copy.test.sh"`
Expected: the Task 1 sections still pass. Resync checks fail (`resync is not implemented yet`), and the dry-run checks fail because a real copy was made.

- [ ] **Step 3: Implement dry-run for copy**

In `copy_issue`, directly after the `COMPONENTS="$(…)"` assignment and before `local args=(issues create …)`, insert:

```bash
	if [ "$DRY" = 1 ]; then
		local n_comments=0
		if [ "$WANT_COMMENTS" = 1 ]; then n_comments="$(jq 'length' <<<"$COMMENTS")"; fi
		RESULT="$(jq -cn --arg s "$SRC_Q" --argjson split "$split" --argjson n "$n_comments" \
			--argjson body "$WANT_BODY" --argjson footer "$WANT_FOOTER" --argjson back "$WANT_BACKLINK" \
			--arg st "$applied_status" --arg skst "$skip_status" '
			{source: $s, target: null, dryRun: true,
			 copied: {body: ($body == 1), comments: $n, labels: $split.apply,
			          status: (if $st == "" then null else $st end), footer: ($footer == 1), backLink: ($back == 1)},
			 skipped: {labels: $split.skip, status: (if $skst == "" then null else $skst end)}}')"
		if [ -n "${LS_JSON:-}" ]; then printf '%s\n' "$RESULT"; return 0; fi
		jq -r --arg title "$(jq -r '.title' <<<"$issue")" --arg to "$DST_T" --arg label "$status_label" '
			def yn: if . then "yes" else "no" end;
			"copy \(.source) → \($to) (dry run, nothing written)",
			"  title      \($title)",
			"  body       \(.copied.body | yn)",
			"  comments   \(.copied.comments)",
			"  labels     \(if (.copied.labels | length) > 0 then .copied.labels | join(", ") else "none" end)",
			"  status     \(if .copied.status then "\(.copied.status) → \($label)" else "none" end)",
			"  footer     \(.copied.footer | yn)",
			"  back-link  \(.copied.backLink | yn)",
			(if (.skipped.labels | length) > 0 then "  skipped    labels \($to) does not have: \(.skipped.labels | join(", "))" else empty end),
			(if .skipped.status then "  skipped    status \(.skipped.status) (\($to) has no label for that role)" else empty end)' <<<"$RESULT"
		return 0
	fi
```

- [ ] **Step 4: Implement resync**

Add this function above the final `case "$VERB"` block:

```bash
resync_issue() {
	local rec n
	rec="$(ledger_find "$SRC_Q" "$DST_T")"
	[ -n "$rec" ] || fail not-found "no copy of $SRC_D on $DST_T in this clone's ledger ($LEDGER) — copies made on another machine are not recorded here"
	DST_Q="$(jq -r '.target' <<<"$rec")"
	COMPONENTS="$(jq -c '.components // []' <<<"$rec")"
	COMMENTS="$(fl issues comments --number "$SRC_Q")"
	if [ "$DRY" = 1 ]; then
		n="$(jq --argjson h "$(jq -c '.comments // []' <<<"$rec")" '[.[] | select(.id as $i | $h | any(.[]; . == $i) | not)] | length' <<<"$COMMENTS")"
		RESULT="$(jq -cn --arg s "$SRC_Q" --arg t "$DST_Q" --argjson n "$n" '{source:$s, target:$t, dryRun:true, copied:{comments:$n}, skipped:{}}')"
		report "$RESULT" "resync $SRC_Q → $DST_Q (dry run, nothing written): $n comment(s) to post"
		return 0
	fi
	post_comments "$DST_Q" "$(jq -c '.comments // []' <<<"$rec")"
	RESULT="$(jq -cn --arg s "$SRC_Q" --arg t "$DST_Q" --argjson n "$POSTED" '{source:$s, target:$t, copied:{comments:$n}, skipped:{}}')"
	report "$RESULT" "$POSTED"
}
```

Then replace the final dispatch with:

```bash
case "$VERB" in
	copy) copy_issue ;;
	resync) resync_issue ;;
esac
```

- [ ] **Step 5: Run the tests**

Run: `bash "$WT/scripts/tests/issue-copy.test.sh"`
Expected: all ✓, `Failed: 0`.

- [ ] **Step 6: Lint and commit**

```bash
cd "$WT" && ./scripts/run-checks.sh
git -C "$WT" add flight/scripts/issue-copy scripts/tests/issue-copy.test.sh
git -C "$WT" commit -m "feat(FJ-200): issues resync and --dry-run for copies

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The `copying-an-issue` skill

**Files:**
- Create: `flight/skills/copying-an-issue/SKILL.md`
- Modify: `flight/skills/filing-issues/SKILL.md` (Step 2 "Classify" section)
- Modify: `scripts/tests/tracker-lifecycle-skills.test.sh` (the `LIFECYCLE` list and new checks)
- Modify: `flight/README.md` (skill table)

**Interfaces:**
- Consumes: `flight issues copy|resync` exactly as Tasks 1–2 define them; `issues resolve`, `issues tracker`, `issues list --tracker`, `issues get`.
- Produces: skill text the contract test pins: `ISSUE="$(flight issues resolve --number "$INPUT")"`, `flight issues copy --from "$QUALIFIED" --to "$DST_T" --dry-run`.

- [ ] **Step 1: Add the failing contract checks**

In `scripts/tests/tracker-lifecycle-skills.test.sh`, append `$SK/copying-an-issue/SKILL.md` to the `LIFECYCLE` list (so the generic tracker rules apply to it):

```bash
LIFECYCLE="$SK/working-an-issue/SKILL.md $SK/filing-issues/SKILL.md $SK/triaging-issues/SKILL.md
$SK/queue-batches/SKILL.md $SK/queue-batches/templates/agent-prompt.md $SK/promoting-a-branch/SKILL.md
$SK/promoting-branches/SKILL.md $SK/cleaning-up-branches/SKILL.md $SK/copying-an-issue/SKILL.md"
```

and add, before the summary lines at the end:

```bash
C="$SK/copying-an-issue/SKILL.md"
check "copying-an-issue resolves the source once" "$(has "$C" 'ISSUE="$(flight issues resolve --number "$INPUT")"')"
check "copying-an-issue previews with --dry-run before copying" "$(has "$C" 'flight issues copy --from "$QUALIFIED" --to "$DST_T" --dry-run')"
check "copying-an-issue scans the target for duplicates" "$(has "$C" 'flight issues list --tracker "$DST_T" --state open --limit 100')"
check "filing-issues points copy requests at copying-an-issue" "$(has "$SK/filing-issues/SKILL.md" 'copying-an-issue')"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash "$WT/scripts/tests/tracker-lifecycle-skills.test.sh"`
Expected: the four new checks fail (grep can't find a missing file); the existing ones pass.

- [ ] **Step 3: Write the skill**

Create `flight/skills/copying-an-issue/SKILL.md`:

````markdown
---
name: copying-an-issue
description: Use when copying an issue from one configured issue tracker to another, or bringing an earlier copy up to date — "copy FJ-12 to GH", "pull GH-3 into Forgejo", "put this on Jira too", "move this issue over to the public tracker", "resync the copy", "bring the GitHub copy up to date". Copies the title plus optional body, comments, labels and status, refuses a second copy of the same issue, and later posts only the comments the copy is missing. Never closes the source.
---

# Copying an Issue

Before the first command, follow [runtime preflight](../../references/runtime.md).

Copy one issue from the tracker it lives on to another configured tracker, or resync an earlier
copy with the comments added to the source since. Everything goes through the dispatcher:
`flight issues copy` and `flight issues resync` read and write each side with that tracker's own
credential and label map, and record the link in the git-ignored
`.flightdirector/copies.jsonl` ledger. Verb details:
[adapter-contract.md](../../references/adapter-contract.md) → *`issues copy` / `issues resync`*.

## Red flags — STOP

- **Never skip the duplicate scan.** The dispatcher refuses a second copy it has recorded, but
  only on this machine. Copies made by hand, by someone else, or on another clone are found
  only by scanning the target tracker (Step 2).
- **Preview before writing.** Always show the `--dry-run` plan and get the user's OK before the
  real copy. A copy is visible on the target at once, and on a public tracker it is public.
- **Copy, never move.** Closing or relabelling the source is a separate, explicit request — not
  part of "move this over". Say so if the user asked to move it.
- **Private → public needs a word.** When the target is the public tracker (or the user's
  wording suggests the source is private), point out that the body and comments become visible
  there, and offer `--no-comments` / `--no-body`. The footer and back-link stay off unless asked:
  they name the source issue.
- **Never pass `--force` on your own.** It exists for a deliberate second copy; use it only when
  the user says so after seeing the existing copy.

## Step 1: Resolve both ends

```bash
ISSUE="$(flight issues resolve --number "$INPUT")"     # FJ-12, GH#3, PROJ-7, or a bare number (default tracker)
QUALIFIED="$(jq -r '.qualified' <<<"$ISSUE")"; DISPLAY="$(jq -r '.display' <<<"$ISSUE")"
DST_T="$(flight issues tracker --tracker "<what the user named>" | jq -r '.ref')"
```

An unknown tracker name is an error listing the configured trackers: ask, never guess. If
`DST_T` is the issue's own tracker, there is nothing to copy; say so.

## Step 2: Duplicate scan on the target (copy only)

```bash
flight issues get --number "$QUALIFIED"
flight issues list --tracker "$DST_T" --state open --limit 100
```

Pick a few specific words from the source title and scan the target's titles for them. If the
stderr warning says rows were held back (`showing 100 of N`), list again with a higher
`--limit`. When a title looks close, pull it with `issues get --number <its id>` and ask the
user: *"GH-7 looks like the same issue: [title]. Copy anyway, resync that one instead, or stop?"*
A tracker reported `unavailable` was not scanned: say so rather than "no duplicates".

## Step 3: Preview

```bash
flight issues copy --from "$QUALIFIED" --to "$DST_T" --dry-run [component flags]
```

Components: body, comments, labels and status are copied by default. `--no-body`,
`--no-comments`, `--no-labels` and `--no-status` turn them off. `--footer` (a "Copied from …"
line in the copy) and `--back-link` (a "Copied to …" comment on the source) are off unless the
user asks. Show the plan as printed. It lists what will be copied, how the status maps, and the
labels the target lacks, which are skipped: labels are never created on the target. If the
dispatcher says the issue was already copied there, offer a resync (Step 5) instead.

## Step 4: Copy

After the user agrees:

```bash
flight issues copy --from "$QUALIFIED" --to "$DST_T" [the same component flags] --model <your-model-id>
```

It prints the new issue's id (`GH-5`); skipped labels or status are named on stderr. Report:
*"Copied FJ-12 to GH-5 (body, 3 comments, labels bug; status to-test). Skipped: area/app (GH
doesn't have it)."* If it stops partway through the comments, it says so, and the ledger
already holds what landed. Run the resync it names to finish the job.

## Step 5: Resync an earlier copy

```bash
flight issues resync --from "$QUALIFIED" --to "$DST_T" --dry-run
flight issues resync --from "$QUALIFIED" --to "$DST_T" --model <your-model-id>
```

Resync posts the source comments the copy doesn't have yet, oldest first, and touches nothing
else: not the title, body, labels or status, and not comments edited after they were copied. It
prints how many it posted (`0` = up to date). "No copy … in this clone's ledger" means the copy
was made elsewhere or never: there is nothing to resync from here.

## Common mistakes

- Treating the dispatcher's refusal as the whole duplicate check. It only knows this clone's copies.
- Copying without the preview because the request sounded certain.
- Closing the source after a "move". That needs its own explicit go-ahead.
- Adding `--footer` / `--back-link` by default. They reveal the source's id on the target.
````

- [ ] **Step 4: Point filing-issues at it**

In `flight/skills/filing-issues/SKILL.md`, directly after the paragraph `Filing two related issues in one turn? Scan and classify each independently.` add:

```markdown
Asked to copy or move an existing issue to another tracker ("copy FJ-12 to GH")? That is not a
new issue. Use the `copying-an-issue` skill, which keeps the link and checks for an earlier copy.
```

- [ ] **Step 5: Add the README row**

In `flight/README.md`, after the `filing-issues` row of the skill table, add:

```markdown
| `copying-an-issue` | "copy FJ-12 to GH", "pull GH-3 into Forgejo", "resync the copy" | Copies one issue to another configured tracker (title, plus optional body, comments, labels, status) after a duplicate scan and a dry-run preview; later resyncs comments added to the source; never closes the source |
```

- [ ] **Step 6: Run the contract test**

Run: `bash "$WT/scripts/tests/tracker-lifecycle-skills.test.sh"`
Expected: all ✓. If the generic "every issue write/read names its tracker or a qualified id" check flags a line in the new skill, change that command to pass `--tracker "$DST_T"` or `--number "$QUALIFIED"`. Don't loosen the check.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add flight/skills/copying-an-issue/SKILL.md flight/skills/filing-issues/SKILL.md scripts/tests/tracker-lifecycle-skills.test.sh flight/README.md
git -C "$WT" commit -m "feat(FJ-200): copying-an-issue skill

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Reference docs, guide and changelog; full preflight

**Files:**
- Modify: `flight/references/adapter-contract.md` (after the `### \`branches\`` section)
- Modify: `flight/references/json-output.md` (the verbs/shape table, error codes, capability list)
- Modify: `flight/references/flight-setup.md` (named-tracker section, after *Setting trackers up*)
- Modify: `flight/GUIDE.md` (the section on multiple trackers; find it with `grep -n -i 'tracker' flight/GUIDE.md`)
- Modify: `flight/CHANGELOG.md` (`## [Unreleased]` → `### Added`)

**Interfaces:**
- Consumes: the behaviour from Tasks 1–3. Document only what the code does; run the commands if unsure.
- Produces: nothing code depends on.

- [ ] **Step 1: adapter-contract.md**

Add after the `branches` section:

```markdown
### `issues copy` / `issues resync` (dispatcher-owned)

Copy one issue to another configured tracker, and later bring that copy up to date with source
comments. Like `branches`, these live in the dispatcher (`scripts/issue-copy`) rather than in an
adapter: they read and write each side back through the dispatcher with that tracker's own
credential and label map, so every backend pair works.

| Verb | Args | stdout |
|---|---|---|
| `copy` | `--from ID --to TRACKER` `[--no-body] [--no-comments] [--no-labels] [--no-status] [--footer] [--back-link] [--force] [--dry-run]` | the copy's display id; skipped labels/status on stderr. `--dry-run`: the plan, nothing written |
| `resync` | `--from ID --to TRACKER [--dry-run]` | the number of comments posted (`0` = up to date) |

- Title always; body, comments, labels and status by default. Labels match **by exact name**
  and are never created on the target. Status maps by **role** (the source's label → its role →
  the target's label for it). Comments are posted oldest-first under an attribution line
  (`**author** commented on YYYY-MM-DD:`). Assignees, open/closed state and attachments are
  never copied, and the source is never closed.
- The source ↔ copy link is recorded in `.flightdirector/copies.jsonl` (see
  [flight-setup.md](flight-setup.md)). `copy` refuses a source already recorded for that
  tracker (`already-copied`; `--force` overrides). `resync` posts the source comments the
  record doesn't list and touches nothing else. A record is written after each step, so a copy
  that fails partway is finished by `resync`.
- `--tracker` is refused: the two trackers are `--from` (any id `issues resolve` accepts) and
  `--to` (a ref or alias). `--to` the source's own tracker is a usage error. Requires config schema 3.
```

- [ ] **Step 2: json-output.md**

Add rows to the shape table (next to `issues set-status`):

```markdown
| `issues copy` | `{source, target, copied: {body, comments, labels, status, footer, backLink}, skipped: {labels, status}}`; with `--dry-run`, `target` is null and `dryRun` is true |
| `issues resync` | `{source, target, copied: {comments}, skipped: {}}`; `dryRun: true` with `--dry-run` |
```

Add `already-copied` to the error-code list with the meaning *"`issues copy`: the ledger already records a copy of this issue on that tracker; use `issues resync`, or `--force` for a second copy"*. Add `issues-copy` to the documented capability tokens with *"`issues copy` and `issues resync` exist"*. Match the surrounding table formats exactly (read those sections first).

- [ ] **Step 3: flight-setup.md**

After the *Setting trackers up* paragraph add:

```markdown
**Copied issues.** `flight issues copy` (and the `copying-an-issue` skill) records each copy in
`.flightdirector/copies.jsonl`: one JSON line per step, `{source, target, at, components,
comments}`, with the latest line for a source and target tracker winning. It is git-ignored
along with the rest of `.flightdirector/`, so it belongs to this clone. `copy` uses it to refuse
a second copy, and `resync` uses it to know which comments are already across. Deleting it
forgets the links; it never affects the issues themselves.
```

Check that `.flightdirector/.gitignore` ignores the file (`git -C "$WT" check-ignore -v .flightdirector/copies.jsonl` from the main checkout prints a matching rule). If it doesn't, add `copies.jsonl` to the gitignore that `setting-up-a-repo` writes and to the repo's own, and note it in this paragraph.

- [ ] **Step 4: GUIDE.md**

In the multiple-trackers section add a short subsection, *Copying an issue to another tracker*, with three examples and one sentence on privacy:

```markdown
#### Copying an issue to another tracker

    flight issues copy --from GH-3 --to FJ --dry-run      # preview
    flight issues copy --from GH-3 --to FJ                # copy (prints e.g. FJ-271)
    flight issues resync --from GH-3 --to FJ              # later: bring over new comments

Body, comments, labels and status come along unless you pass `--no-body`, `--no-comments`,
`--no-labels` or `--no-status`. Nothing names the source on the copy unless you add `--footer`
or `--back-link`, which matters when copying from a private tracker to a public one. Or just
ask: "copy GH-3 into Forgejo".
```

- [ ] **Step 5: CHANGELOG.md**

Under `## [Unreleased]` → `### Added`, first bullet:

```markdown
- **Copy issues between trackers** (FJ-200). `flight issues copy --from FJ-12 --to GH` copies an
  issue to another configured tracker. The body, comments (with their original author and date),
  name-matched labels and the status (mapped by role) are copied by default and each can be
  turned off; an optional "Copied from" footer and "Copied to" back-link are off by default.
  `flight issues resync` later brings over comments added to the source. A local ledger
  (`.flightdirector/copies.jsonl`) refuses accidental second copies and lets a copy that failed
  partway finish. The new `copying-an-issue` skill adds a duplicate scan and a dry-run preview.
  Capability token: `issues-copy`.
```

- [ ] **Step 6: Full preflight**

Run: `cd "$WT" && ./scripts/run-checks.sh && ./scripts/run-tests.sh`
Expected: both pass, including `issue-copy.test.sh` and `tracker-lifecycle-skills.test.sh`. Fix any failure before committing. A failure in an unrelated suite should be checked against `develop` (`git -C "$WT" stash` is **not** allowed; compare with a fresh throwaway worktree of `develop`) and reported rather than papered over.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add flight/references/adapter-contract.md flight/references/json-output.md flight/references/flight-setup.md flight/GUIDE.md flight/CHANGELOG.md
git -C "$WT" commit -m "docs(FJ-200): document issues copy/resync and the copy ledger

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Live verification against this repo's FJ and GH trackers

**Files:** none changed (unless a bug turns up: then fix it in its owning file with a regression test in `issue-copy.test.sh`, and commit as `fix(FJ-200): …`).

This task runs against the real Forgejo and GitHub trackers, using the **worktree's** dispatcher:
`F="$WT/flight/scripts/flight"`, run from `$WT`. It creates two scratch issues; the user is told
about each one and both are closed at the end.

- [ ] **Step 1: Dry-run GH → FJ on an existing GitHub issue**

Run: `"$F" issues copy --from GH-3 --to FJ --dry-run`
Expected: a plan with GH-3's title, `comments` = its comment count, `status none` (GH-3 has no labels). Nothing written.

- [ ] **Step 2: Create a scratch source and copy it FJ → GH**

```bash
SRC="$("$F" issues create --tracker FJ --title "FJ-200 live check: copy me (scratch, will be closed)" --body "Scratch issue for the FJ-200 live check." --label bug --model claude-opus-5-5)"
"$F" issues comment --tracker FJ --number "$SRC" --body 'First comment with `code` and $HOME.' --model claude-opus-5-5
"$F" issues set-status --tracker FJ --number "$SRC" --status to-test
"$F" issues copy --from "FJ-$SRC" --to GH --footer --model claude-opus-5-5
```

Expected: prints `GH-<n>`. On GitHub the copy has the body plus `Copied from FJ-<SRC>`, the labels `bug` and `status/to test` (GH's spelling, from its label map), and one comment starting `**DaveWoodCom** commented on <today>:` (or whichever login owns the FJ token) with the backticks and `$HOME` intact. `tail -n1 .flightdirector/copies.jsonl` in the main checkout shows the pair.

- [ ] **Step 3: Refusal, resync, cleanup**

```bash
"$F" issues copy --from "FJ-$SRC" --to GH; echo "rc=$?"              # expect rc=1, "already copied to GH-<n>"
"$F" issues comment --tracker FJ --number "$SRC" --body "Second comment, for resync." --model claude-opus-5-5
"$F" issues resync --from "FJ-$SRC" --to GH                           # expect 1
"$F" issues resync --from "FJ-$SRC" --to GH                           # expect 0
"$F" issues close --tracker FJ --number "$SRC"
"$F" issues close --number "GH-<n>"
```

Expected: as commented. Report both scratch issue ids to the user and confirm they are closed.

- [ ] **Step 4: Status hand-off**

All tasks done and the preflight green: set FJ-200 to `to-test` with `flight issues set-status --tracker FJ --number 200 --status to-test` and tell the user the branch `feature/fj-200-copy-issue-between-trackers` is ready to test. Merging waits for their explicit "promote" (working-an-issue's merge gate).
