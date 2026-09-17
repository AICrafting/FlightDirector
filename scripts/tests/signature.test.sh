#!/usr/bin/env bash
# Unit tests for the dispatcher-owned body signature (#132): every body flight
# writes (issues create/update/comment, pr open/update) ends with
#     ---
#     via FlightDirector:flight@<version>[ with <Model/ver>]
# It is appended in the dispatcher (adapters stay pure), replaced rather than
# stacked on update, and switchable off. A fake curl captures the payloads.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
VERSION="$(jq -r .version "$REPO_ROOT/flight/.claude-plugin/plugin.json")"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; method=GET; payload=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H|-u) shift 2 ;;
		-L|-sS) shift ;;
		--data-binary) payload="$2"; shift 2 ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s' '{"number":42,"iid":42,"id":7,"title":"t","state":"open","html_url":"https://example.invalid/acme/widget/pulls/42","web_url":"https://example.invalid/x"}' >"$out"
if [ "$method" != GET ]; then
	printf '%s\t%s\t%s\n' "$method" "$url" "$(printf '%s' "$payload" | jq -c . 2>/dev/null)" >>"${CURL_LOG:?}"
fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
export CURL_LOG="$SANDBOX/curl.log"
export LS_TOKEN=t
unset FLIGHT_MODEL LS_MODEL

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

mkrepo() { # $1 name, $2 extra config JSON merged into .code → prints path
	local r="$SANDBOX/$1" extra="${2:-}"; mkdir -p "$r/.flightdirector"; git -C "$r" init -q
	# Spelled out rather than "${2:-{\}}": bash 3.2 (macOS) mis-parses the braces in
	# that default and hands jq an invalid object, which is how this test went red on
	# the bash 3.2 CI leg. `[ -n ] || extra='{}'` reads the same on every bash.
	[ -n "$extra" ] || extra='{}'
	jq -n --argjson extra "$extra" '{code:({backend:"forgejo",owner:"acme",repo:"widget",api:"https://example.invalid/api/v1",stages:[{name:"develop"}]} + $extra)}' >"$r/.flightdirector/config.json"
	printf '%s\n' "$r"
}
# run <repo> <group> <verb> [args…] → payload body of the last write, in $BODY; rc in $RC
run() {
	local r="$1"; shift
	: >"$CURL_LOG"
	set +e; (cd "$r" && "$DISP" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"); RC=$?; set -e
	BODY="$(tail -1 "$CURL_LOG" | cut -f3 | jq -r '.body // empty' 2>/dev/null || true)"
}
SIG_RE='^via FlightDirector:flight@'
# last_two <body> → the last two lines of the body joined by \n
last_two() { printf '%s' "$1" | tail -2 | paste -sd '\n'; }

R="$(mkrepo plain)"

# --- 1. issues create --body: signature appended after a blank line ----------
run "$R" issues create --title T --body 'hello body'
check "issues create exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "body keeps its text" "$(printf '%s' "$BODY" | head -1 | grep -qx 'hello body' && echo 1 || echo 0)" "$BODY"
check "signature is the last two lines: rule + via FlightDirector:flight@<version>" \
	"$([ "$(last_two "$BODY")" = "$(printf -- '---\nvia FlightDirector:flight@%s' "$VERSION")" ] && echo 1 || echo 0)" "$BODY"
check "a blank line separates body and rule" "$(printf '%s' "$BODY" | sed -n 2p | grep -qx '' && echo 1 || echo 0)" "$BODY"
check "no model → no 'with' clause" "$(printf '%s' "$BODY" | grep -q ' with ' && echo 0 || echo 1)" "$BODY"

# --- 2. --body-file, plus --model → 'with Fable/5.1' -------------------------
printf 'line one\nline two\n' >"$SANDBOX/body.md"
run "$R" issues comment --number 1 --body-file "$SANDBOX/body.md" --model claude-fable-5-1
check "issues comment --body-file is signed" "$(printf '%s' "$BODY" | grep -qE "$SIG_RE" && echo 1 || echo 0)" "$BODY"
check "--model claude-fable-5-1 renders as 'with Fable/5.1'" \
	"$(printf '%s' "$BODY" | tail -1 | grep -qx "via FlightDirector:flight@$VERSION with Fable/5.1" && echo 1 || echo 0)" "$(tail -1 <<<"$BODY")"
check "--model is stripped before the adapter sees the args" "$([ ! -s "$SANDBOX/err" ] && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "the body file on disk is untouched" "$([ "$(cat "$SANDBOX/body.md")" = "$(printf 'line one\nline two')" ] && echo 1 || echo 0)"

# --- 3. model display mapping -------------------------------------------------
for pair in 'gpt-5.6-sol=Sol/5.6' 'claude-opus-4-7=Opus/4.7' 'claude-haiku-4-5-20251001=Haiku/4.5' 'gpt-5=GPT/5' 'anthropic/claude-sonnet-5=Sonnet/5'; do
	id="${pair%%=*}"; want="${pair#*=}"
	run "$R" issues comment --number 1 --body x --model "$id"
	check "model '$id' → 'with $want'" "$(tail -1 <<<"$BODY" | grep -qx "via FlightDirector:flight@$VERSION with $want" && echo 1 || echo 0)" "$(tail -1 <<<"$BODY")"
done
FLIGHT_MODEL=claude-fable-5-1 run "$R" issues comment --number 1 --body x
check "FLIGHT_MODEL env is honoured when --model is absent" "$(tail -1 <<<"$BODY" | grep -q 'with Fable/5.1' && echo 1 || echo 0)" "$(tail -1 <<<"$BODY")"
FLIGHT_MODEL=claude-opus-4-7 run "$R" issues comment --number 1 --body x --model claude-fable-5-1
check "--model beats FLIGHT_MODEL" "$(tail -1 <<<"$BODY" | grep -q 'with Fable/5.1' && echo 1 || echo 0)" "$(tail -1 <<<"$BODY")"

# --- 4. update replaces an old signature instead of stacking -----------------
# bare (pre-'via') shape on purpose: both shapes must be replaced, not stacked
old="$(printf 'edited text\n\n---\nFlightDirector:flight@0.1.0 with Opus/4.7\n')"
run "$R" issues update --number 1 --body "$old" --model claude-fable-5-1
check "issues update: exactly one signature" "$([ "$(grep -c 'FlightDirector:flight@' <<<"$BODY")" = 1 ] && echo 1 || echo 0)" "$BODY"
check "issues update: the old version/model is replaced by the current one" \
	"$(tail -1 <<<"$BODY" | grep -qx "via FlightDirector:flight@$VERSION with Fable/5.1" && echo 1 || echo 0)" "$(tail -1 <<<"$BODY")"
check "issues update: the body text above the signature survives" "$(head -1 <<<"$BODY" | grep -qx 'edited text' && echo 1 || echo 0)" "$BODY"
run "$R" issues update --number 1 --body "$old"
check "issues update without a model drops the old 'with' clause too" "$(tail -1 <<<"$BODY" | grep -qx "via FlightDirector:flight@$VERSION" && echo 1 || echo 0)" "$(tail -1 <<<"$BODY")"
run "$R" issues update --number 1 --title 'only a title'
check "issues update with no body sends no body (title-only patch untouched)" "$([ "$RC" = 0 ] && [ -z "$BODY" ] && echo 1 || echo 0)" "$BODY"

# --- 5. pr open / pr update ------------------------------------------------------
printf 'PR body\n' >"$SANDBOX/pr.md"
run "$R" pr open --head feature/x --base develop --title T --body-file "$SANDBOX/pr.md" --model claude-fable-5-1
check "pr open --body-file is signed" "$([ "$RC" = 0 ] && tail -1 <<<"$BODY" | grep -q "flight@$VERSION with Fable/5.1" && echo 1 || echo 0)" "$BODY $(cat "$SANDBOX/err")"
run "$R" pr update --number 42 --body 'new pr body'
check "pr update --body is signed" "$([ "$RC" = 0 ] && grep -qE "$SIG_RE" <<<"$BODY" && echo 1 || echo 0)" "$BODY $(cat "$SANDBOX/err")"

# --- 6. opt-out: config switch and --no-signature ---------------------------
run "$R" issues comment --number 1 --body 'quiet' --no-signature
check "--no-signature sends the body untouched" "$([ "$BODY" = quiet ] && echo 1 || echo 0)" "$BODY"
R2="$(mkrepo off '{"signature":{"enabled":false}}')"
run "$R2" issues comment --number 1 --body 'quiet'
check "code.signature.enabled=false sends the body untouched" "$([ "$BODY" = quiet ] && echo 1 || echo 0)" "$BODY"
run "$R2" issues comment --number 1 --body "$old"
check "…and leaves an existing signature alone" "$([ "$BODY" = "$(printf '%s' "$old")" ] && echo 1 || echo 0)" "$BODY"

# --- 7. only body-writing verbs are touched ------------------------------------
run "$R" issues get --number 1 --model claude-fable-5-1
check "--model on a read verb is rejected by the adapter (dispatcher does not swallow it)" "$([ "$RC" != 0 ] && echo 1 || echo 0)"

# --- 8. no temp files leaked --------------------------------------------------------
mkdir -p "$SANDBOX/tmp"
(cd "$R" && TMPDIR="$SANDBOX/tmp" "$DISP" issues comment --number 1 --body 'x' >/dev/null 2>&1)
check "no signed-body temp file is leaked" "$([ -z "$(ls -A "$SANDBOX/tmp")" ] && echo 1 || echo 0)" "$(ls -A "$SANDBOX/tmp")"

# --- 9. Jira shim renders the rule as an ADF rule node ------------------------
# The helper asserts LS_* on load, so pull ADF_JQ out of a throwaway shell.
ADF_JQ="$(LS_API=x LS_PROJECT=x LS_TOKEN=x LS_EMAIL=x bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$ADF_JQ"' _ "$REPO_ROOT/flight/scripts/adapters/jira/_common.sh")"
if [ -n "${ADF_JQ:-}" ]; then
	adf="$(printf 'para\n\n---\nvia FlightDirector:flight@1.0.0\n' | jq -Rs "$ADF_JQ"'md_to_adf')"
	check "jira md_to_adf turns --- into a rule node" "$(jq -e '.content[1].type == "rule"' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
	check "jira md_to_adf keeps the signature line as a paragraph" "$(jq -e '.content[2].content[0].text == "via FlightDirector:flight@1.0.0"' <<<"$adf" >/dev/null && echo 1 || echo 0)" "$adf"
	back="$(jq -r "$ADF_JQ"'adf_to_text' <<<"$adf")"
	check "jira adf_to_text renders a rule back as ---" "$(grep -qx -- '---' <<<"$back" && echo 1 || echo 0)" "$back"
else
	check "jira shim sourced" 0 "ADF_JQ not defined"
fi

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
