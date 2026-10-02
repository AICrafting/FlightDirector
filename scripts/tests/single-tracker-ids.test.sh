#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted strings are jq programs; their $-vars are jq's
# Single-tracker issue names (#258): with exactly one tracker — the code repository's
# own, or Jira — `issues resolve` names an issue the way people already do (`#12`,
# `PROJ-7`) and branches drop the tracker prefix (`feature/12-…`). `qualified` stays the
# fully qualified routing key. Adding a second tracker later must not make that era's
# branches ambiguous. Runs the REAL dispatcher and issue-identity.sh; no network.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_SELF FLIGHT_REPO_ROOT FLIGHT_ERROR_FILE LS_JSON
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
IDENTITY="$REPO_ROOT/flight/scripts/issue-identity.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }
yes() { "$@" >/dev/null 2>&1 && echo 1 || echo 0; }

R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
CFG="$R/.flightdirector/config.json"
BIND="$R/.flightdirector/batches/work-items/identities.json"
CODE='{"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"acme","repo":"widget","stages":[{"name":"main"}]}'
FJ='{"ref":"FJ","name":"Code issues","default":true,"backend":"forgejo","api":"https://code.example.com/api/v1/","owner":"acme","repo":"widget","credentialRef":"code"}'
GH='{"ref":"GH","name":"Public","default":false,"backend":"github","api":"https://api.github.com","owner":"acme","repo":"widget"}'
JIR='{"ref":"JIR","name":"Jira","default":true,"backend":"jira","api":"https://jira.example.com","project":"PROJ","email":"bot@example.com"}'
OTHER='{"ref":"TK","name":"Tickets","default":true,"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"acme","repo":"tickets"}'
config() { # config <tracker json>… — a schema-3 config (never migrated) with these trackers
	jq -n --argjson code "$CODE" --argjson ts "$(jq -s . <<<"$*")" \
		'{schemaVersion: 3, code: $code, issues: {backend: "requires-newer-flight"}, issueTrackers: $ts}' >"$CFG"
}
resolve() { (cd "$R" && "$DISP" issues resolve "$@"); }
ident() { (cd "$R" && "$IDENTITY" "$@"); }
status_of() { local rc=0; ident "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

section "issues resolve"
config "$FJ"
out="$(resolve --number 12)"
check "one tracker, the code repo's own: #12, branch prefix 12, qualified kept" \
	"$(yes jq -e '. == {tracker:"FJ", number:"12", qualified:"FJ-12", display:"#12", branchPrefix:"12"}' <<<"$out")" "$out"
out="$(resolve --number FJ-12)"
check "a qualified input names the same issue the same way" "$(yes jq -e '.display == "#12" and .qualified == "FJ-12"' <<<"$out")" "$out"
config "$JIR"
out="$(resolve --number 7)"
check "one Jira tracker: its native key, lowercased for branches" \
	"$(yes jq -e '. == {tracker:"JIR", number:"PROJ-7", qualified:"JIR-7", display:"PROJ-7", branchPrefix:"proj-7"}' <<<"$out")" "$out"
config "$OTHER"
out="$(resolve --number 12)"
check "one tracker in ANOTHER forge repo keeps its prefix (a bare #12 would link the code repo's issue)" \
	"$(yes jq -e '.display == "TK-12" and .branchPrefix == "tk-12"' <<<"$out")" "$out"
config "$FJ" "$GH"
out="$(resolve --number 12)"
check "two trackers: the qualified id, as before" "$(yes jq -e '.display == "FJ-12" and .branchPrefix == "fj-12"' <<<"$out")" "$out"

section "single-tracker branches"
config "$FJ"
ID="$(resolve --number 12)"
ident remember --branch feature/12-add-login --identity "$ID"
check "remember binds an unprefixed branch, without storing display" \
	"$(yes jq -e '.branches["feature/12-add-login"] == {tracker:"FJ", number:"12", qualified:"FJ-12", branchPrefix:"12"}' "$BIND")" "$(cat "$BIND" 2>/dev/null)"
out="$(ident from-branch --branch feature/12-add-login)"
check "from-branch returns it with display #12" "$(yes jq -e '.display == "#12" and .branchPrefix == "12" and .tracker == "FJ"' <<<"$out")" "$out"
check "remember refuses a branch carrying another issue's number" \
	"$([ "$(status_of remember --branch feature/13-other --identity "$ID")" = 1 ] && echo 1 || echo 0)"
out="$(ident from-branch --branch feature/14-made-by-hand)"
check "an unbound numeric branch belongs to the only tracker" "$(yes jq -e '.qualified == "FJ-14" and .display == "#14"' <<<"$out")" "$out"
out="$(ident pr-reference --identity "$ID" --closes true)"
check "the code PR line still closes it by number" "$([ "$out" = "Closes #12" ] && echo 1 || echo 0)" "$out"
config "$JIR"
out="$(ident from-branch --branch feature/proj-7-sync)"
check "a single Jira tracker's branch carries the native key" "$(yes jq -e '.qualified == "JIR-7" and .display == "PROJ-7"' <<<"$out")" "$out"

section "adding a second tracker later"
config "$FJ" "$GH"
out="$(ident from-branch --branch feature/12-add-login)"
check "the single-tracker branch still resolves to its tracker, now shown qualified" \
	"$(yes jq -e '.tracker == "FJ" and .display == "FJ-12" and .branchPrefix == "12"' <<<"$out")" "$out"
check "an unbound numeric branch is no longer guessed (4)" \
	"$([ "$(status_of from-branch --branch feature/15-unbound)" = 4 ] && echo 1 || echo 0)"
out="$(resolve --number 12)"
check "new work is qualified again" "$(yes jq -e '.branchPrefix == "fj-12"' <<<"$out")" "$out"

section "batch manifests"
config "$FJ"
mkdir -p "$R/.flightdirector/batches"
(cd "$R" && "$REPO_ROOT/flight/scripts/batch-manifest" write --run-id S1 --zone z --issues "12") >/dev/null
check "manifest entries are identities without a stored display" \
	"$(yes jq -e '.zones.z[0] == {tracker:"FJ", number:"12", qualified:"FJ-12", branchPrefix:"12"}' "$R/.flightdirector/batches/S1.json")" \
	"$(cat "$R/.flightdirector/batches/S1.json" 2>/dev/null)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
