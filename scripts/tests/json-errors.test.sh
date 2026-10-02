#!/usr/bin/env bash
# Structured errors under --json (#251): a failing --json call exits non-zero and
# prints exactly one {"error":{"code","message"}} object on stdout — nothing before
# it — while stderr keeps the human sentence. The code is decided where the cause
# is known: the dispatcher for config/usage/ref resolution, each adapter's _api for
# HTTP status and curl failure. See flight/references/json-output.md.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_ERROR_FILE LS_JSON
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
ADAPTERS="$REPO_ROOT/flight/scripts/adapters"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }

# run DIR CMD… — stdout to $OUT, stderr to $ERR, exit status in $RC.
OUT="$SANDBOX/out"; ERR="$SANDBOX/err"
run() { local d="$1"; shift; RC=0; (cd "$d" && "$@" >"$OUT" 2>"$ERR") || RC=$?; }
# envelope CODE — stdout is exactly one envelope with that code, and the call failed.
envelope() {
	[ "$RC" -ne 0 ] \
		&& [ "$(wc -l <"$OUT" | tr -d ' ')" = 1 ] \
		&& jq -e --arg c "$1" 'keys == ["error"] and .error.code == $c and (.error.message | type == "string" and length > 0)' "$OUT" >/dev/null \
		&& echo 1 || echo 0
}

section "dispatcher-classified failures"
BARE="$SANDBOX/bare"; mkdir -p "$BARE"; git -C "$BARE" init -q
run "$BARE" "$DISP" issues resolve --number 1 --json
check "no config → not-configured" "$(envelope not-configured)" "$(cat "$OUT" "$ERR")"
check "stderr still carries the human sentence" "$(grep -q 'no .flightdirector/config.json' "$ERR" && echo 1 || echo 0)" "$(cat "$ERR")"

R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
cat >"$R/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"o","repo":"r","stages":[{"name":"main"}]},
  "issues": {"backend":"requires-newer-flight"},
  "issueTrackers": [
    {"ref":"FJ","name":"Forgejo","default":true,"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"o","repo":"r","credentialRef":"code","labels":{}}
  ]
}
JSON
run "$R" "$DISP" issues resolve --number ZZ-1 --json
check "an id naming no tracker → not-found" "$(envelope not-found)" "$(cat "$OUT" "$ERR")"
check "the envelope keeps the resolver's own reason" "$(jq -e '.error.message | test("ZZ")' "$OUT" >/dev/null && echo 1 || echo 0)" "$(cat "$OUT")"
run "$R" "$DISP" issues tracker --tracker NOPE --json
check "an unknown --tracker ref → not-found" "$(envelope not-found)" "$(cat "$OUT" "$ERR")"
run "$R" "$DISP" issues resolve --json
check "bad arguments → usage" "$(envelope usage)" "$(cat "$OUT" "$ERR")"
run "$R" "$DISP" issues close --number 1 --json
check "--json on a verb without JSON output → usage" "$(envelope usage)" "$(cat "$OUT" "$ERR")"

BADJSON="$SANDBOX/badjson"; mkdir -p "$BADJSON/.flightdirector"; git -C "$BADJSON" init -q
echo '{ not json' >"$BADJSON/.flightdirector/config.json"
run "$BADJSON" "$DISP" issues resolve --number 1 --json
check "a config that is not valid JSON → not-configured" "$(envelope not-configured)" "$(cat "$OUT" "$ERR")"
OLD="$SANDBOX/schema2"; mkdir -p "$OLD/.flightdirector"; git -C "$OLD" init -q
echo '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://x/api/v1","owner":"o","repo":"r"}}' >"$OLD/.flightdirector/config.json"
run "$OLD" "$DISP" issues resolve --number 1 --json
check "a pre-schema-3 config where trackers are needed → not-configured" "$(envelope not-configured)" "$(cat "$OUT" "$ERR")"
echo '{"schemaVersion":99}' >"$OLD/.flightdirector/config.json"
run "$OLD" "$DISP" issues resolve --number 1 --json
check "a config newer than this Flight → not-configured" "$(envelope not-configured)" "$(cat "$OUT" "$ERR")"

section "--json is a flag only where a flag can stand"
# A value that is literally --json stays a value: here it is the --number value, which
# resolves to nothing, so the failure must be the resolver's (stderr) — not JSON mode.
run "$R" "$DISP" issues resolve --number --json
check "an option's value '--json' is not taken as the flag" \
	"$([ "$RC" -ne 0 ] && [ ! -s "$OUT" ] && ! grep -q 'needs a value\|usage: flight issues resolve' "$ERR" && echo 1 || echo 0)" "$(cat "$OUT" "$ERR")"
run "$R" "$DISP" issues resolve --json --number 3
check "--json before the other flags still counts" "$([ "$RC" = 0 ] && jq -e '.qualified == "FJ-3"' "$OUT" >/dev/null && echo 1 || echo 0)" "$(cat "$OUT" "$ERR")"

section "success is unchanged"
run "$R" "$DISP" issues resolve --number 7 --json
check "a JSON-native verb answers as before under --json" \
	"$([ "$RC" = 0 ] && jq -e '.qualified == "FJ-7"' "$OUT" >/dev/null && echo 1 || echo 0)" "$(cat "$OUT" "$ERR")"
run "$R" "$DISP" issues resolve --number ZZ-1
check "without --json a failure prints nothing on stdout" "$([ "$RC" -ne 0 ] && [ ! -s "$OUT" ] && echo 1 || echo 0)" "$(cat "$OUT")"
run "$R" "$DISP" prompt-log summary --session none --json
check "other groups keep their own --json (prompt-log summary)" "$(! grep -q -- '--json is not supported' "$ERR" && echo 1 || echo 0)" "$(cat "$ERR")"

section "adapter-classified failures (every backend)"
# A fake curl: FAKE_HTTP is the status to answer; FAKE_HTTP=curl-fails makes curl
# itself fail, as an unreachable host does.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D|--data-binary|-w|-X|-H|-u) shift 2 ;;
		*) shift ;;
	esac
done
[ "${FAKE_HTTP:?}" != curl-fails ] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }
printf '{"message":"fake %s"}' "$FAKE_HTTP" >"$out"
printf '%s' "$FAKE_HTTP"
SH
chmod +x "$SANDBOX/bin/curl"

adapter_code() { # BACKEND STATUS [env…] — the code the issues adapter records for `get`
	local backend="$1" status="$2"; shift 2
	local ef="$SANDBOX/errfile"; rm -f "$ef"
	env PATH="$SANDBOX/bin:$PATH" FLIGHT_ERROR_FILE="$ef" FAKE_HTTP="$status" \
		LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t \
		LS_PROJECT=ACME LS_EMAIL=a@b.c "$@" \
		"$ADAPTERS/$backend/issues" get --number 1 >/dev/null 2>&1 || true
	jq -r '.error.code' "$ef" 2>/dev/null || echo none
}
for b in forgejo github gitlab jira; do
	check "$b: HTTP 401 → auth" "$([ "$(adapter_code "$b" 401)" = auth ] && echo 1 || echo 0)"
	check "$b: HTTP 403 → auth" "$([ "$(adapter_code "$b" 403)" = auth ] && echo 1 || echo 0)"
	check "$b: HTTP 404 → not-found" "$([ "$(adapter_code "$b" 404)" = not-found ] && echo 1 || echo 0)"
	check "$b: HTTP 500 → backend" "$([ "$(adapter_code "$b" 500)" = backend ] && echo 1 || echo 0)"
	check "$b: HTTP 422 → backend" "$([ "$(adapter_code "$b" 422)" = backend ] && echo 1 || echo 0)"
	check "$b: unreachable server → network" "$([ "$(adapter_code "$b" curl-fails)" = network ] && echo 1 || echo 0)"
	check "$b: no token → auth" "$([ "$(adapter_code "$b" 200 LS_TOKEN=)" = auth ] && echo 1 || echo 0)"
	check "$b: a missing coordinate → not-configured" "$([ "$(adapter_code "$b" 200 LS_API=)" = not-configured ] && echo 1 || echo 0)"
	check "$b: an unknown argument → usage" \
		"$(ef="$SANDBOX/errfile"; rm -f "$ef"; env PATH="$SANDBOX/bin:$PATH" FLIGHT_ERROR_FILE="$ef" LS_API=x LS_OWNER=o LS_REPO=r LS_TOKEN=t LS_PROJECT=P LS_EMAIL=e \
			"$ADAPTERS/$b/issues" get --bogus 1 >/dev/null 2>&1 || true; [ "$(jq -r '.error.code' "$ef" 2>/dev/null)" = usage ] && echo 1 || echo 0)"
done
ef="$SANDBOX/errfile"; rm -f "$ef"
env PATH="$SANDBOX/bin:$PATH" FAKE_HTTP=404 LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t \
	"$ADAPTERS/forgejo/issues" get --number 1 >"$OUT" 2>"$ERR" || true
check "without FLIGHT_ERROR_FILE an adapter writes no envelope anywhere" \
	"$([ ! -e "$ef" ] && [ ! -s "$OUT" ] && grep -q 'HTTP 404' "$ERR" && echo 1 || echo 0)" "$(cat "$OUT" "$ERR")"

section "capabilities"
check "json-errors is advertised" "$("$DISP" capabilities --json | jq -e '.capabilities | index("json-errors") != null' >/dev/null && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
