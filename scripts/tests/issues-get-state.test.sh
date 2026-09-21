#!/usr/bin/env bash
# Unit tests for `issues get`'s state field: every adapter must emit the issue's
# state as field 3 of line 1, normalized to exactly `open` or `closed`, so a
# caller can ask "is #N open?" in one call. The backends disagree on the wire
# (GitLab says `opened`, Jira has no state field at all, only a workflow status
# with a category), and that normalization is the whole point of the field.
# See flight/references/adapter-contract.md, `issues` → `get`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTERS="$REPO_ROOT/flight/scripts/adapters"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# A fake forge that answers any single-issue GET with the JSON in $ISSUE_JSON.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) shift 2 ;;
		--data-binary) shift 2 ;;
		-w|-X|-H|-u) shift 2 ;;
		-sS|-L) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\n' "${url:-}" >>"${CURL_LOG:?}"
printf '%s' "${ISSUE_JSON:?}" >"$out"
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t
export LS_PROJECT=ACME LS_EMAIL=a@b.c
export CURL_LOG="$SANDBOX/curl.log"

pass=0; fail=0
check() { # check <label> <got> <want>
	if [ "$2" = "$3" ]; then
		printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else
		printf '\033[0;31m  ✗ %s\n      got:  %s\n      want: %s\033[0m\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

# state <adapter> <json> — field 3 of line 1 of `issues get`.
state() {
	: >"$CURL_LOG"
	ISSUE_JSON="$2" "$ADAPTERS/$1/issues" get --number 1 2>/dev/null \
		| head -1 | cut -f3
}
# line1 <adapter> <json> — the whole first line, for shape assertions.
line1() {
	: >"$CURL_LOG"
	ISSUE_JSON="$2" "$ADAPTERS/$1/issues" get --number 1 2>/dev/null | head -1
}

printf '\033[1m── issues get emits a normalized state ──\033[0m\n'

# --- Forgejo / GitHub: the wire already says open|closed -----------------------
FJ_OPEN='{"number":1,"title":"t","state":"open","body":"b"}'
FJ_SHUT='{"number":1,"title":"t","state":"closed","body":"b"}'
check "forgejo: an open issue reports open"   "$(state forgejo "$FJ_OPEN")" open
check "forgejo: a closed issue reports closed" "$(state forgejo "$FJ_SHUT")" closed
check "github: an open issue reports open"    "$(state github "$FJ_OPEN")" open
check "github: a closed issue reports closed"  "$(state github "$FJ_SHUT")" closed

# --- GitLab says `opened`, which must be normalized to `open` -----------------
# This is the case that makes the field worth having: a caller comparing the raw
# wire value against `open` would read every open GitLab issue as not-open.
GL_OPEN='{"iid":1,"title":"t","state":"opened","description":"b"}'
GL_SHUT='{"iid":1,"title":"t","state":"closed","description":"b"}'
check "gitlab: 'opened' is normalized to open"  "$(state gitlab "$GL_OPEN")" open
check "gitlab: 'closed' stays closed"           "$(state gitlab "$GL_SHUT")" closed

# --- Jira has no state field: the status category decides ---------------------
# Same rule `issues list` (statusCategory != Done) and `close`/`reopen` already
# use, so `get` is inheriting the adapter's convention rather than inventing one.
jira_json() { printf '{"key":"ACME-1","fields":{"summary":"t","description":"b","status":{"statusCategory":{"key":"%s"}}}}' "$1"; }
check "jira: a done-category status is closed"          "$(state jira "$(jira_json "done")")" closed
check "jira: a new-category status is open"             "$(state jira "$(jira_json "new")")" open
check "jira: an indeterminate-category status is open"  "$(state jira "$(jira_json "indeterminate")")" open

# A response with no status must FAIL, not default to open. Jira is the only
# backend that derives state rather than reading it, so a missing field would
# otherwise report `open` for what may be a done issue — the one direction that
# lets a stale tracker slip past a deferral guard. The other three emit an empty
# field 3 and halt on their own.
: >"$CURL_LOG"
if ISSUE_JSON='{"key":"ACME-1","fields":{"summary":"t","description":"b"}}' \
	"$ADAPTERS/jira/issues" get --number 1 >/dev/null 2>&1; then
	check "jira: a response with no status fails instead of reporting open" exited-0 non-zero
else
	check "jira: a response with no status fails instead of reporting open" non-zero non-zero
fi

printf '\033[1m── the line shape stays pinned ──\033[0m\n'

# Field 3 is APPENDED: number and title keep their positions, so `cut -f1`/`-f2`
# consumers are unaffected. Three fields exactly — a fourth would break them next.
check "forgejo: line 1 is number⇥title⇥state" "$(line1 forgejo "$FJ_OPEN")" "$(printf '1\tt\topen')"
check "gitlab: line 1 is iid⇥title⇥state"     "$(line1 gitlab "$GL_OPEN")" "$(printf '1\tt\topen')"
check "jira: line 1 is key⇥summary⇥state"     "$(line1 jira "$(jira_json "new")")" "$(printf 'ACME-1\tt\topen')"

# The body still follows after a blank line — the one verb that emits a body.
body_ok() {
	: >"$CURL_LOG"
	ISSUE_JSON="$2" "$ADAPTERS/$1/issues" get --number 1 2>/dev/null | sed -n '2,3p'
}
check "forgejo: a blank line then the body still follow" "$(body_ok forgejo "$FJ_OPEN")" "$(printf '\nb')"
check "gitlab: a blank line then the body still follow"  "$(body_ok gitlab "$GL_OPEN")" "$(printf '\nb')"

# --- Jira must actually ask for the status field ------------------------------
: >"$CURL_LOG"
ISSUE_JSON="$(jira_json "new")" "$ADAPTERS/jira/issues" get --number 1 >/dev/null 2>&1
check "jira: the request asks for the status field" \
	"$(grep -c 'fields=summary,description,status' "$CURL_LOG")" 1

printf '\n'
if [ "$fail" -gt 0 ]; then
	printf '\033[0;31missues-get-state: %d passed, %d failed\033[0m\n' "$pass" "$fail"
	exit 1
fi
printf '\033[0;32missues-get-state: all %d checks passed\033[0m\n' "$pass"
