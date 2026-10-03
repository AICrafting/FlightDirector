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
		jq -cn --rawfile b "$body_file" '{body:$b}' >>"$S/$tracker/$number.posted.jsonl"
		# A posted comment joins the issue's thread, as on a real tracker.
		c="$S/$tracker/$number.comments.json"; [ -f "$c" ] || echo '[]' >"$c"
		jq --arg id "c$posted" --rawfile b "$body_file" '. + [{id:$id, author:"bot", created:"2026-10-03T00:00:00Z", body:$b}]' "$c" >"$c.tmp" && mv "$c.tmp" "$c"
		jq -cn --arg id "c$posted" '{id:$id}' ;;
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
check "the existing comments and the back-link are recorded as handled" "$(yes jq -e '.comments == ["501","502","c1"] and .components == ["footer","back-link"]' <<<"$(last_ledger)")" "$(last_ledger)"
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
: >"$STATE/calls.log"
hc copy --from FJ-12 --to NOPE
check "an unknown target tracker fails before anything is written" \
	"$([ "$RC" = 1 ] && ! grep -q 'issues create' "$STATE/calls.log" && echo 1 || echo 0)" "rc=$RC"
hc copy --from FJ-12
check "--to is required" "$([ "$RC" = 1 ] && grep -q usage <<<"$ERR" && echo 1 || echo 0)" "rc=$RC err=$ERR"

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

section "resync after --back-link"
fixture
hc copy --from FJ-12 --to GH --back-link
hc resync --from FJ-12 --to GH
check "the back-link on the source is never resynced onto the copy" \
	"$([ "$RC" = 0 ] && [ "$OUT" = 0 ] && jq -e 'length == 2' <<<"$(posted GH 100)" >/dev/null && echo 1 || echo 0)" "rc=$RC out=$OUT $(posted GH 100)"

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
	"$([ ! -e "$LEDGER" ] && ! grep -qE 'issues (create|comment) ' "$STATE/calls.log" && echo 1 || echo 0)" "$(cat "$STATE/calls.log")"
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

section "the ledger stays out of git"
fixture
git -C "$R" init -q
hc copy --from FJ-12 --to GH
check "a copy warns when the ledger is not git-ignored" "$(grep -q 'not git-ignored' <<<"$ERR" && echo 1 || echo 0)" "$ERR"
echo '.flightdirector/copies.jsonl' >"$R/.gitignore"
hc copy --from FJ-12 --to GH --force
check "…and stays quiet once it is" "$(grep -q 'not git-ignored' <<<"$ERR" && echo 0 || echo 1)" "$ERR"
rm -rf "$R/.git" "$R/.gitignore"
check "this repo ignores the ledger" "$(grep -qxF '.flightdirector/copies.jsonl' "$REPO_ROOT/.gitignore" && echo 1 || echo 0)"
check "setting-up-a-repo ignores the ledger" \
	"$(grep -qF '.flightdirector/copies.jsonl' "$REPO_ROOT/flight/skills/setting-up-a-repo/SKILL.md" && echo 1 || echo 0)"

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
check "the capability token is advertised" "$(grep -qx issues-copy <<<"$("$DISP" capabilities)" && echo 1 || echo 0)"

[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
