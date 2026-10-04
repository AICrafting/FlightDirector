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
# is logged to $STATE/calls.log. FAIL_DEP=CODE makes the dep-* verbs fail with that error code.
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
# `resolve` is local in the real dispatcher: it names an issue without looking it up.
if [ "$verb" != resolve ]; then [ -f "$D/$n.json" ] || err not-found "$ref-$n does not exist"; fi
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
		[ -z "${FAIL_DEP:-}" ] || err "$FAIL_DEP" "$verb failed on $ref"
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
check "it names what is done, what is missing, and to rerun" \
	"$(grep -q "posted the marker on FJ-6 but the mirror on GH-2 failed" "$SANDBOX/err" && grep -q "rerun 'flight issues block --number FJ-6 --by GH-2'" "$SANDBOX/err" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
hd block --number FJ-6 --by GH-2 --no-status
check "the rerun posts only the mirror" "$([ "$RC" = 0 ] && [ "$(ncomments FJ 6)" = 1 ] && [ "$(ncomments GH 2)" = 1 ] && echo 1 || echo 0)" "$(ncomments FJ 6)/$(ncomments GH 2)"

section "a rerun after a partial failure, status on"
fresh; mk FJ 17 "Feature" in-progress; mk GH 3 "Upstream"
RC=0; FAIL_COMMENT_ON=GH-3 FLIGHT_SELF="$STUB" FLIGHT_REPO_ROOT="$SANDBOX" "$HELPER" block --number FJ-17 --by GH-3 >/dev/null 2>"$SANDBOX/err" || RC=$?
check "the first run fails on the mirror" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
hd block --number FJ-17 --by GH-3
check "the rerun records the status once, ends blocked, and posts the mirror once" \
	"$([ "$RC" = 0 ] && [ "$(status_of FJ 17)" = blocked ] && [ "$(ncomments FJ 17)" = 1 ] && [ "$(ncomments GH 3)" = 1 ] && comments FJ 17 | jq -e '[.[] | select(.body | contains("(was "))] | length == 1' >/dev/null && echo 1 || echo 0)" "rc=$RC $(comments FJ 17) / $(ncomments GH 3)"

section "a native rerun after set-status failed posts one status comment"
fresh; mk FJ 21 "Feature" in-progress; mk FJ 22 "Groundwork"
jq -n '[{id:"1", body:"**Status: blocked** (was in-progress), blocked by fj-22", signature:{plugin:"flight"}}]' >"$STATE/FJ/21.comments.json"
hd block --number FJ-21 --by FJ-22
check "the status comment already there is not posted again" \
	"$([ "$RC" = 0 ] && [ "$(status_of FJ 21)" = blocked ] && [ "$(ncomments FJ 21)" = 1 ] && echo 1 || echo 0)" "rc=$RC $(comments FJ 21)"

section "the (was ...) scan reads only flight's Status shapes"
fresh; mk FJ 23 "Feature" blocked; mk GH 1 "One"
jq -n '[{id:"1", body:"**Blocked by GH-1**: One\n\nStatus: blocked (was in-progress)", signature:{plugin:"flight"}},
	{id:"2", body:"Moved it back and forth: it was fine (was to-test) until Tuesday", signature:{plugin:"flight"}}]' >"$STATE/FJ/23.comments.json"
hd unblock --number FJ-23 --by GH-1
check "another signed comment mentioning (was to-test) does not steer the restore" "$([ "$RC" = 0 ] && [ "$(status_of FJ 23)" = in-progress ] && echo 1 || echo 0)" "rc=$RC $(status_of FJ 23)"

section "a native failure other than unsupported stops the verb"
fresh; mk FJ 18 "Feature" in-progress; mk FJ 19 "Groundwork"
RC=0; rm -f "$SANDBOX/env.json"
FAIL_DEP=network LS_JSON=1 FLIGHT_ERROR_FILE="$SANDBOX/env.json" FLIGHT_SELF="$STUB" FLIGHT_REPO_ROOT="$SANDBOX" "$HELPER" block --number FJ-18 --by FJ-19 >/dev/null 2>&1 || RC=$?
check "block stops with the backend's code and posts nothing" \
	"$([ "$RC" = 1 ] && jq -e '.error.code == "network"' "$SANDBOX/env.json" >/dev/null && [ "$(ncomments FJ 18)" = 0 ] && [ "$(ncomments FJ 19)" = 0 ] && [ "$(status_of FJ 18)" = in-progress ] && echo 1 || echo 0)" "rc=$RC"

section "a deleted blocker can still be unblocked"
fresh; mk FJ 20 "Feature" blocked
jq -n '[{id:"1", body:"**Blocked by FJ-404**: gone\n\nStatus: blocked (was in-progress)", signature:{plugin:"flight"}}]' >"$STATE/FJ/20.comments.json"
hd unblock --number FJ-20 --by FJ-404
check "unblock succeeds, records it, and restores the status" \
	"$([ "$RC" = 0 ] && [ "$OUT" = "FJ-20 no longer blocked by FJ-404" ] && [ "$(status_of FJ 20)" = in-progress ] && [ "$(comments FJ 20 | jq -r '.[-1].body')" = "**No longer blocked by FJ-404**" ] && echo 1 || echo 0)" "rc=$RC out=$OUT err=$ERR"

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

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
