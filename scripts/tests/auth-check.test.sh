#!/usr/bin/env bash
# Tests for `flight auth check` — the read-only token verifier.
#
# Covers the dispatcher's flag handling (--axis, --secrets, LS_SECRETS_FILE and
# their precedence) and each adapter's output shape and exit code, against a
# fake API that can be told to fail a specific endpoint.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLIGHT="$REPO_ROOT/flight/scripts/flight"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# --- fake curl -------------------------------------------------------------
# Serves the read endpoints `auth check` probes. FAIL_MATCH is a substring of a
# URL that should answer 403 instead; FAIL_CODE/FAIL_BODY tune the failure.
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; hdr=/dev/null; url=""; method=GET
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) hdr="$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H|-u) shift 2 ;;
		-L|-sS) shift ;;
		--data-binary) shift 2 ;;
		*) url="$1"; shift ;;
	esac
done
printf 'HTTP/2 200\r\n' >"$hdr"
printf 'github-authentication-token-expiration: 2026-12-31 23:59:59 UTC\r\n' >>"$hdr"
[ "$method" = GET ] || { printf '%s' '{"message":"auth check must be read-only"}' >"$out"; printf '405'; exit 0; }
if [ -n "${FAIL_MATCH:-}" ] && [ "${url#*"$FAIL_MATCH"}" != "$url" ]; then
	printf '%s' "${FAIL_BODY:-{\"message\":\"insufficient_granular_scope for the current token [Work Item: Read]\"}}" >"$out"
	printf '%s' "${FAIL_CODE:-403}"
	exit 0
fi
case "$url" in
	*/user)   printf '%s' '{"id":9,"login":"flight-bot","username":"flight-bot","type":"Bot","bot":false}' >"$out" ;;
	*/personal_access_tokens/self) printf '%s' '{"scopes":["api"],"expires_at":"2026-12-31"}' >"$out" ;;
	*/rest/api/3/myself) printf '%s' '{"displayName":"Flight Bot","emailAddress":"bot@example.invalid","accountId":"abc"}' >"$out" ;;
	*/rest/api/3/mypermissions*)
		printf '%s' '{"permissions":{
			"BROWSE_PROJECTS":{"name":"Browse Projects","havePermission":true},
			"CREATE_ISSUES":{"name":"Create Issues","havePermission":true},
			"EDIT_ISSUES":{"name":"Edit Issues","havePermission":true},
			"ADD_COMMENTS":{"name":"Add Comments","havePermission":true},
			"TRANSITION_ISSUES":{"name":"Transition Issues","havePermission":'"${JIRA_TRANSITION:-true}"'}}}' >"$out" ;;
	*/rest/api/3/project/*) printf '%s' '{"key":"ACME","name":"Acme Board"}' >"$out" ;;
	*/projects/*%2Fwidget) printf '%s' '{"id":3,"path_with_namespace":"acme/widget"}' >"$out" ;;
	*/repos/acme/widget)   printf '%s' '{"full_name":"acme/widget","private":true,"html_url":"https://example.invalid/acme/widget"}' >"$out" ;;
	*) printf '%s' '[]' >"$out" ;;
esac
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"

# --- a sandbox repo with a flight config ----------------------------------
REPO="$SANDBOX/repo"
mkdir -p "$REPO/.flightdirector"
git -C "$SANDBOX" init -q "$REPO"
cfg() {
	cat >"$REPO/.flightdirector/config.json" <<JSON
{ "code":   { "backend": "$1", "owner": "acme", "repo": "widget",
              "api": "https://example.invalid/api",
              "stages": [ { "name": "main", "merge": "pr" } ] },
  "issues": { "backend": "$2", "owner": "acme", "repo": "widget",
              "api": "https://example.invalid/api",
              "project": "ACME", "email": "bot@example.invalid" } }
JSON
}
printf '%s\n' '{"code":{"token":"live-token-aaaaaaaa"},"issues":{"token":"live-token-aaaaaaaa"}}' \
	>"$REPO/.flightdirector/secrets.json"
printf '%s\n' '{"code":{"token":"candidate-token-bbbbbbbb"},"issues":{"token":"candidate-token-bbbbbbbb"}}' \
	>"$REPO/.flightdirector/secrets-new.json"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; }
bad() { fail=$((fail + 1)); printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { if grep -q -- "$2" "$1"; then ok "$3"; else bad "$3 (not found: $2)"; fi; }
hasnt() { if grep -q -- "$2" "$1"; then bad "$3 (unexpectedly found: $2)"; else ok "$3"; fi; }

# check_auth [args…] — runs the dispatcher from inside the sandbox repo.
check_auth() {
	set +e
	( cd "$REPO" && "$FLIGHT" auth check "$@" ) >"$SANDBOX/out" 2>"$SANDBOX/err"
	rc=$?
	set -e
	return $rc
}

# --- forgejo + github: the happy path ------------------------------------
for backend in forgejo github; do
	cfg "$backend" "$backend"
	if check_auth; then
		ok "$backend auth check exits 0 when every probe passes"
	else
		bad "$backend auth check exited non-zero on the happy path ($(cat "$SANDBOX/err"))"
	fi
	has "$SANDBOX/out" '✓ authenticates' "$backend reports identity"
	has "$SANDBOX/out" 'flight-bot' "$backend names the account"
	has "$SANDBOX/out" '✓ issues read' "$backend probes issues"
	has "$SANDBOX/out" '✓ labels read' "$backend probes labels"
	has "$SANDBOX/out" 'not tested' "$backend reports write access as not tested"
	hasnt "$SANDBOX/out" '✗' "$backend emits no failure marks on the happy path"
	# The token must never be printed in full — only the first 8 characters.
	has "$SANDBOX/out" 'live-tok…' "$backend masks the token to 8 characters"
	hasnt "$SANDBOX/out" 'live-token-aaaaaaaa' "$backend never prints the whole token"
done

# forgejo: expiry is not exposed by the API; github reads it from a header.
cfg forgejo forgejo; check_auth || true
has "$SANDBOX/out" 'not exposed' "forgejo reports expiry as not exposed"
cfg github github; check_auth || true
has "$SANDBOX/out" '2026-12-31' "github reports the expiry header"

# --- a failing probe fails the whole check -------------------------------
cfg github github
if FAIL_MATCH='/actions/runs' check_auth; then
	bad "github auth check exited 0 despite a failed probe"
else
	check "$rc" "1" "github auth check exits 1 when a probe fails"
fi
has "$SANDBOX/out" '✗ actions read' "the failing probe is the one marked ✗"
has "$SANDBOX/out" 'Actions: Read' "the failure names the permission to grant"
has "$SANDBOX/out" '✓ issues read' "the other probes still run and report"

# A 401 on identity is reported, not swallowed.
if FAIL_MATCH='/user' FAIL_CODE=401 FAIL_BODY='{"message":"token is invalid"}' check_auth; then
	bad "github auth check exited 0 with a bad token"
else
	ok "github auth check exits non-zero when the token does not authenticate"
fi
has "$SANDBOX/out" '✗ authenticates' "a bad token fails the identity check"
has "$SANDBOX/out" 'HTTP 401' "the identity failure carries the status code"
has "$SANDBOX/out" 'token is invalid' "the identity failure carries the backend's own message"

# The repo/project failure is distinguished from the token failure.
cfg forgejo forgejo
if FAIL_MATCH='/repos/acme/widget' FAIL_CODE=404 FAIL_BODY='{"message":"Not Found"}' check_auth; then
	bad "forgejo auth check exited 0 with an unreachable repo"
else
	ok "forgejo auth check exits non-zero when the repo is unreachable"
fi
has "$SANDBOX/out" '✗ repository' "an unreachable repo fails the repository check"
has "$SANDBOX/out" '✓ authenticates' "an unreachable repo still reports a good identity"

# --- gitlab: fine-grained permission names + expiry ----------------------
cfg gitlab gitlab
if check_auth; then ok "gitlab auth check exits 0 when every probe passes"; else
	bad "gitlab auth check exited non-zero on the happy path ($(cat "$SANDBOX/err"))"; fi
has "$SANDBOX/out" '✓ mrs read' "gitlab probes merge requests"
has "$SANDBOX/out" '✓ pipelines read' "gitlab probes pipelines"
has "$SANDBOX/out" '2026-12-31' "gitlab reports the token expiry date"
if FAIL_MATCH='/issues' check_auth; then
	bad "gitlab auth check exited 0 despite a failed probe"
else
	ok "gitlab auth check exits non-zero when a probe fails"
fi
has "$SANDBOX/out" 'Work Item: Read' "gitlab surfaces the missing fine-grained permission"

# --- jira: account permissions on the project ----------------------------
cfg github jira
if check_auth --axis issues; then ok "jira auth check exits 0 when the account has every permission"; else
	bad "jira auth check exited non-zero on the happy path ($(cat "$SANDBOX/err"))"; fi
has "$SANDBOX/out" 'Flight Bot' "jira reports the account display name"
has "$SANDBOX/out" '✓ perm BROWSE_PROJECTS' "jira reports each project permission"
if JIRA_TRANSITION=false check_auth --axis issues; then
	bad "jira auth check exited 0 with a missing permission"
else
	ok "jira auth check exits non-zero when a project permission is missing"
fi
has "$SANDBOX/out" '✗ perm TRANSITION_ISSUES' "jira marks the missing permission"

# --axis picks the axis: the default (code) is github here, not jira.
check_auth || true
has "$SANDBOX/out" 'flight-bot' "auth check defaults to the code axis"

# --- token sources and their precedence ----------------------------------
cfg forgejo forgejo
check_auth || true
has "$SANDBOX/out" 'live-tok…' "the live secrets file is the default token source"

check_auth --secrets "$REPO/.flightdirector/secrets-new.json" || true
has "$SANDBOX/out" 'candidat…' "--secrets reads the candidate file"

LS_SECRETS_FILE="$REPO/.flightdirector/secrets-new.json" check_auth || true
has "$SANDBOX/out" 'candidat…' "LS_SECRETS_FILE reads the candidate file"

# --secrets beats LS_SECRETS_FILE.
printf '%s\n' '{"code":{"token":"env-file-token-cccccccc"}}' >"$SANDBOX/other.json"
LS_SECRETS_FILE="$SANDBOX/other.json" check_auth --secrets "$REPO/.flightdirector/secrets-new.json" || true
has "$SANDBOX/out" 'candidat…' "--secrets wins over LS_SECRETS_FILE"

# An ambient env token is the fallback, but an explicit candidate file beats it.
LS_TOKEN=env-token-dddddddd check_auth || true
has "$SANDBOX/out" 'env-toke…' "LS_TOKEN is used when no secrets file is named"
LS_TOKEN=env-token-dddddddd check_auth --secrets "$REPO/.flightdirector/secrets-new.json" || true
has "$SANDBOX/out" 'candidat…' "--secrets wins over an ambient LS_TOKEN"

# --- dispatcher argument validation --------------------------------------
if check_auth --axis bogus; then bad "auth check accepted a bogus --axis"; else
	ok "auth check rejects an unknown --axis"; fi
if check_auth --secrets "$SANDBOX/nope.json"; then bad "auth check accepted a missing --secrets file"; else
	ok "auth check rejects a missing --secrets file"; fi
if check_auth --nonsense; then bad "auth check accepted an unknown flag"; else
	ok "auth check rejects an unknown flag"; fi
if ( cd "$REPO" && "$FLIGHT" auth verify ) >/dev/null 2>&1; then
	bad "auth accepted an unknown verb"
else
	ok "auth rejects a verb other than check"
fi

# --- read-only guarantee --------------------------------------------------
for backend in forgejo github gitlab jira; do
	if grep -Eq '_?probe[ ]+(POST|PUT|PATCH|DELETE)|-X[ ]+(POST|PUT|PATCH|DELETE)' \
		"$REPO_ROOT/flight/scripts/adapters/$backend/auth"; then
		bad "$backend/auth contains a write request"
	else
		ok "$backend/auth issues no write requests"
	fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
