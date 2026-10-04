#!/usr/bin/env bash
# Contract tests for tracker setup (#199): setting-up-a-repo + add-an-issue-tracker.
#
# Setup is a skill, not a script, so these tests take the machine-readable pieces the skills
# publish — the fresh-config skeleton, the example tracker entries, and the jq recipes that
# merge an entry, check a ref, finalize labels and switch the default — straight out of the
# SKILL.md files (each sits under an `<!-- marker -->`), run them, and hand the result to the
# real dispatcher in a temp repo. A fake `curl` on PATH records which host, token and labels
# each call used. Grep checks then pin the prose contract: gap-check rows, the three
# starting-status states, the skill inventories, and no private hosts or tokens in shared docs.
#
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose ($a/$b are jq variables)
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_MODEL LS_MODEL
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
SETUP_SKILL="$REPO_ROOT/flight/skills/setting-up-a-repo/SKILL.md"
TRACKER_SKILL="$REPO_ROOT/flight/skills/add-an-issue-tracker/SKILL.md"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1)); fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }
ok() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }

# block <file> <marker> — the fenced block that follows `<!-- marker -->`.
block() {
	awk -v marker="<!-- $2 -->" '
		$0 == marker { found = 1; next }
		found && !fence && /^```/ { fence = 1; next }
		fence && /^```$/ { exit }
		fence { print }
	' "$1"
}

# The skills write examples with a bare `flight`; runtime.md says to run them through $DISP.
flight() { "$DISP" "$@"; }

SKELETON="$(block "$SETUP_SKILL" fresh-config-skeleton)"
ENTRY_FIRST="$(block "$TRACKER_SKILL" tracker-entry-first)"
ENTRY_JIRA="$(block "$TRACKER_SKILL" tracker-entry-jira)"
SECRETS_EXAMPLE="$(block "$TRACKER_SKILL" tracker-secrets)"
MERGE="$(block "$TRACKER_SKILL" tracker-merge)"
REF_CHECK="$(block "$TRACKER_SKILL" tracker-ref-check)"
FINALIZE="$(block "$TRACKER_SKILL" tracker-labels-finalize)"
SWITCH="$(block "$TRACKER_SKILL" tracker-default-switch)"

# merge_entry <config-file> <entry-json> — runs the skill's merge recipe verbatim. The recipes
# read CFG/ENTRY/REF/ADOPTED/CANDIDATE, which shellcheck cannot see through eval.
# shellcheck disable=SC2034
merge_entry() { ( CFG="$1"; ENTRY="$2"; eval "$MERGE" ); }
# shellcheck disable=SC2034
finalize() { ( CFG="$1"; REF="$2"; ADOPTED="$3"; eval "$FINALIZE" ); }
# shellcheck disable=SC2034
switch_default() { ( CFG="$1"; REF="$2"; eval "$SWITCH" ); }
# ref_check <repo> <candidate> — prints the ref already answering to the candidate.
# shellcheck disable=SC2034
ref_check() { ( cd "$1" && CANDIDATE="$2" && eval "$REF_CHECK" ); }
resolve() { local r="$1"; shift; (cd "$r" && "$DISP" issues resolve "$@"); }
same_json() { [ "$(jq -S . "$1")" = "$(jq -S . "$2")" ]; }

section "the published examples parse"
for name in SKELETON ENTRY_FIRST ENTRY_JIRA SECRETS_EXAMPLE; do
	eval "val=\$$name"
	check "$name is valid JSON" "$(jq -e . >/dev/null 2>&1 <<<"$val" && echo 1 || echo 0)" "$val"
done
for name in MERGE REF_CHECK FINALIZE SWITCH; do
	eval "val=\$$name"
	check "$name recipe is present" "$([ -n "$val" ] && echo 1 || echo 0)"
done
check "the fresh skeleton is schema 3 with the requires-newer-flight stub" \
	"$(ok jq -e '.schemaVersion == 3 and .issues.backend == "requires-newer-flight"' <<<"$SKELETON")"
check "the fresh skeleton has no top-level labels, no legacyIssueTracker and no trackers yet" \
	"$(ok jq -e '(has("labels") or has("legacyIssueTracker") or has("issueTrackers") or has("harnesses")) | not' <<<"$SKELETON")"
check "example entries never carry a default key (the merge decides it)" \
	"$(ok jq -e -s 'all(.[]; has("default") | not)' <<<"$ENTRY_FIRST$ENTRY_JIRA")"
check "the first-tracker example seeds the complete status and model role map" \
	"$(ok jq -e '(.labels.status | keys) == ["blocked","deferred","done","in-progress","qa","review","to-test"] and (.labels.model | length) == 8' <<<"$ENTRY_FIRST")"
check "the Jira example uses its project key as the ref and space-free label names" \
	"$(ok jq -e '.ref == .project and ([.labels | .. | strings | select(test(" "))] | length) == 0' <<<"$ENTRY_JIRA")"
check "the secrets example keys tracker tokens by ref, beside code, with no legacy issues object" \
	"$(ok jq -e '(.code.token | type) == "string" and (.issueTrackers | type) == "object" and (.issueTrackers | has("KAN")) and (has("issues") | not)' <<<"$SECRETS_EXAMPLE")"

# A fixture repo with a pre-existing unqualified branch: reconcile must NOT bind it on a fresh
# schema-3 config (binding is migration-only, and a fresh config has no legacyIssueTracker).
R="$SANDBOX/repo"; mkdir -p "$R"
git -C "$R" init -q
git -C "$R" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$R" branch feature/12-old-work
mkdir -p "$R/.flightdirector"
CFG="$R/.flightdirector/config.json"; SEC="$R/.flightdirector/secrets.json"

section "first run — one default, installed in a single valid write"
CAND="$SANDBOX/candidate.json"
printf '%s\n' "$SKELETON" >"$CAND"
merge_entry "$CAND" "$ENTRY_FIRST"
check "the first tracker becomes the one default" \
	"$(ok jq -e '[.issueTrackers[] | select(.default == true)] | length == 1 and .[0].ref == "FJ"' "$CAND")"
check "code settings, preferences and the stub survive the merge" \
	"$(ok jq -e '.code.preflight and .code.queueBatches.defaultModel and .issues.backend == "requires-newer-flight"' "$CAND")"
cp "$CAND" "$CFG"
out="$(resolve "$R" --number 1 2>&1)"
check "the installed config validates and a bare number means the first tracker" \
	"$(ok jq -e '.tracker == "FJ" and .qualified == "FJ-1"' <<<"$out")" "$out"
out="$(resolve "$R" --tracker FJ --number 1 2>&1)"
check "the skill's verification step (resolve --tracker REF --number 1) passes" \
	"$(ok jq -e '.tracker == "FJ"' <<<"$out")" "$out"
cp "$CFG" "$SANDBOX/before-reconcile.json"
set +e; (cd "$R" && "$DISP" reconcile --harness claude >"$SANDBOX/out" 2>"$SANDBOX/err"); rc=$?; set -e
check "the deferred reconcile accepts the fresh config" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
check "reconcile only stamps the harness — trackers, code and the stub are unchanged" \
	"$(ok jq -e -n --slurpfile a "$SANDBOX/before-reconcile.json" --slurpfile b "$CFG" '
		($b[0].harnesses.claude.plugins.flight.reconciledWith | type) == "string"
		and ($b[0] | del(.harnesses)) == ($a[0] | del(.harnesses))')" "$(cat "$CFG")"
check "a fresh config never gains legacyIssueTracker" "$(ok jq -e 'has("legacyIssueTracker") | not' "$CFG")"
check "a fresh config binds no legacy branches" \
	"$([ ! -e "$R/.flightdirector/batches/work-items/identities.json" ] && echo 1 || echo 0)"

section "rerun — preserves entries, answers and the default"
cp "$CFG" "$SANDBOX/after-first.json"
merge_entry "$CFG" "$ENTRY_FIRST"
check "re-merging the same tracker changes nothing (no duplicate, no default switch)" \
	"$(ok same_json "$SANDBOX/after-first.json" "$CFG")" "$(jq -c '.issueTrackers' "$CFG")"
merge_entry "$CFG" '{"ref":"fj","default":false,"name":"Renamed by mistake","labels":{"status":{"new":"status/new","in-progress":"doing"}}}'
check "a rerun fills an absent answer (new) on the existing entry, matched case-insensitively" \
	"$(ok jq -e '[.issueTrackers[] | select(.ref == "FJ")] | length == 1 and .[0].labels.status.new == "status/new"' "$CFG")"
check "a rerun never overwrites a present answer (name, in-progress label)" \
	"$(ok jq -e '.issueTrackers[0].name == "Working backlog" and .issueTrackers[0].labels.status["in-progress"] == "status/in progress"' "$CFG")"
check "a default:false in rerun answers cannot demote the default" "$(ok jq -e '.issueTrackers[0].default == true' "$CFG")"
jq '.issueTrackers[0].labels.status.new = false' "$SANDBOX/after-first.json" >"$CFG"
merge_entry "$CFG" '{"ref":"FJ","labels":{"status":{"new":"status/new"}}}'
check "a recorded decline (new: false) survives a rerun" "$(ok jq -e '.issueTrackers[0].labels.status.new == false' "$CFG")"
cp "$SANDBOX/after-first.json" "$CFG"

section "second and later trackers — the default stays put"
merge_entry "$CFG" "$ENTRY_JIRA"
check "the Jira tracker is appended as a non-default" \
	"$(ok jq -e '(.issueTrackers | length) == 2 and .issueTrackers[1].ref == "KAN" and .issueTrackers[1].default == false' "$CFG")"
check "the original default and its settings are untouched" \
	"$(ok jq -e -n --slurpfile a "$SANDBOX/after-first.json" --slurpfile b "$CFG" '$b[0].issueTrackers[0] == $a[0].issueTrackers[0]')"
check "a bare number still means the original default" "$(ok jq -e '.tracker == "FJ"' <<<"$(resolve "$R" --number 5)")"
out="$(resolve "$R" --number KAN-5 2>&1)"
check "a Jira project reference resolves to the Jira tracker with its native key" \
	"$(ok jq -e '.tracker == "KAN" and .number == "KAN-5" and .qualified == "KAN-5" and .branchPrefix == "kan-5"' <<<"$out")" "$out"
check "the Jira tracker's alias resolves case-insensitively" \
	"$(ok jq -e '.tracker == "KAN"' <<<"$(resolve "$R" --number roadmap-6)")"
check "--tracker with a bare number builds the Jira key" \
	"$(ok jq -e '.number == "KAN-7"' <<<"$(resolve "$R" --tracker KAN --number 7)")"

section "ref collisions and aliases — explicit, never guessed"
check "the ref check names the tracker holding a taken ref (case-insensitive)" "$([ "$(ref_check "$R" fj)" = FJ ] && echo 1 || echo 0)"
check "the ref check names the tracker holding a taken alias" "$([ "$(ref_check "$R" ROADMAP)" = KAN ] && echo 1 || echo 0)"
check "the ref check is empty for a free ref" "$([ -z "$(ref_check "$R" GH)" ] && echo 1 || echo 0)"
SECOND_FORGE='{"ref":"FJ2","name":"Second Forgejo repo","aliases":["Ops"],"backend":"forgejo","api":"https://git.example.com/api/v1","owner":"acme","repo":"ops","labels":{"status":{"in-progress":"wip"}}}'
check "a same-backend second tracker would collide on the suggested FJ" "$([ "$(ref_check "$R" FJ)" = FJ ] && echo 1 || echo 0)"
merge_entry "$CFG" "$SECOND_FORGE"
check "the user's replacement ref (FJ2) is appended beside FJ" \
	"$(ok jq -e '[.issueTrackers[].ref] == ["FJ","KAN","FJ2"] and ([.issueTrackers[] | select(.default)] | length) == 1' "$CFG")"
check "FJ-3 and FJ2-3 stay two identities" \
	"$([ "$(resolve "$R" --number FJ-3 | jq -r .tracker)" = FJ ] && [ "$(resolve "$R" --number FJ2-3 | jq -r .tracker)" = FJ2 ] && echo 1 || echo 0)"
check "the new tracker's alias selects it" "$(ok jq -e '.tracker == "FJ2"' <<<"$(resolve "$R" --number ops-1)")"
cp "$CFG" "$SANDBOX/three.json"
merge_entry "$CFG" '{"ref":"GH","name":"Clash","aliases":["kan"],"backend":"github","api":"https://api.github.com","owner":"acme","repo":"widget","labels":{}}'
set +e; out="$(resolve "$R" --number 1 2>&1)"; set -e
check "an alias colliding with another tracker's ref fails validation after the merge" \
	"$(grep -q 'used more than once' <<<"$out" && echo 1 || echo 0)" "$out"
cp "$SANDBOX/three.json" "$CFG"

section "independent credentials"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""; method=GET; data=""; headers=""; user=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) printf 'x-total-count: 1\r\n' >"$2"; shift 2 ;;
		-w) shift 2 ;;
		-X) method="$2"; shift 2 ;;
		-H) headers="${headers}${headers:+|}$2"; shift 2 ;;
		-u) user="$2"; shift 2 ;;
		--data-binary|-d|--data) data="$2"; shift 2 ;;
		-sS|-L|-s|-f|-fsS) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\t%s\t%s\t%s\t%s\n' "$method" "$url" "$headers" "$user" "$(printf '%s' "$data" | tr '\n' ' ')" >>"${CURL_LOG:?}"
body='[]'
case "$url" in
	*/labels*page=1*) body='[{"id":11,"name":"status/new","color":"fff","description":""},{"id":12,"name":"status/triage","color":"fff","description":""},{"id":13,"name":"bug","color":"fff","description":""}]' ;;
	*/labels*) body='[]' ;;
	*/issues) body='{"number":42,"title":"t","state":"open","labels":[]}' ;;
	*/issues*) body='[]' ;;
	*/user) body='{"id":2,"login":"bot"}' ;;
	*/repos/*) body='{"full_name":"acme/widget","private":true}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" CURL_LOG="$SANDBOX/curl.log"

cat >"$SEC" <<'JSON'
{"code":{"token":"code-secret"},"issueTrackers":{"FJ2":{"token":"fj2-secret"},"KAN":{"token":"kan-secret","email":"bot@example.com"}}}
JSON
: >"$CURL_LOG"
(cd "$R" && "$DISP" issues list --tracker FJ --limit 1 >/dev/null 2>&1) || true
check "a tracker on the code repo with credentialRef code uses the code token" \
	"$(grep -q 'token code-secret' "$CURL_LOG" && ! grep -q 'fj2-secret' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
(cd "$R" && FLIGHT_TOKEN=code-env "$DISP" issues list --tracker FJ2 --limit 1 >/dev/null 2>&1) || true
check "a same-backend second tracker uses only its own token — neither code's nor the env's" \
	"$(grep -q 'repos/acme/ops/issues' "$CURL_LOG" && grep -q 'token fj2-secret' "$CURL_LOG" && ! grep -Eq 'code-secret|code-env' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
(cd "$R" && "$DISP" auth check --tracker FJ2 >/dev/null 2>&1) || true
check "auth check --tracker verifies that tracker's own credential" \
	"$(grep -q 'token fj2-secret' "$CURL_LOG" && ! grep -q 'code-secret' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
: >"$CURL_LOG"
(cd "$R" && FLIGHT_TOKEN=code-env "$DISP" auth check --tracker KAN >/dev/null 2>&1) || true
check "the Jira tracker authenticates with its own email:token, not the code token" \
	"$(grep -q 'example.atlassian.net' "$CURL_LOG" && ! grep -Eq 'code-secret|code-env' "$CURL_LOG" && grep -Eq 'kan-secret|'"$(printf 'bot@example.com:kan-secret' | base64 | tr -d '\n')" "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"
jq '.issueTrackers[2].credentialRef = "code" | .issueTrackers[2].api = "https://other.example.com/api/v1"' "$SANDBOX/three.json" >"$CFG"
set +e; out="$(resolve "$R" --number 1 2>&1)"; set -e
check "credentialRef code on another host is refused (a token never leaves its system)" \
	"$(grep -q 'credentialRef "code" reuses the code token only' <<<"$out" && echo 1 || echo 0)" "$out"
cp "$SANDBOX/three.json" "$CFG"

section "starting status — string, false and absent, per tracker"
# FJ: configured (status/new) · FJ2: an adopted equivalent (status/triage) · GH: declined · GL: never asked
merge_entry "$CFG" '{"ref":"GH","name":"Public intake","backend":"github","api":"https://api.github.com","owner":"acme","repo":"widget","labels":{"status":{"new":false}}}'
merge_entry "$CFG" '{"ref":"GL","name":"Mirror","backend":"gitlab","api":"https://gitlab.com/api/v4","owner":"acme","repo":"widget","labels":{"status":{"in-progress":"doing"}}}'
finalize "$CFG" FJ '{"status":{"new":"status/new"}}'
finalize "$CFG" FJ2 '{"status":{"new":"status/triage"}}'
jq '.issueTrackers.GH = {"token":"gh-secret"} | .issueTrackers.GL = {"token":"gl-secret"}' "$SEC" >"$SANDBOX/sec" && cp "$SANDBOX/sec" "$SEC"
created_labels() {	# created_labels <tracker> → the label ids/names on the created issue ("none" if none)
	: >"$CURL_LOG"
	(cd "$R" && "$DISP" issues create --tracker "$1" --title t --body b --no-signature >/dev/null 2>&1) || true
	local row; row="$(grep -a $'^POST\t[^\t]*/issues\t' "$CURL_LOG" | tail -1 | cut -f5)"
	printf '%s' "$row" | jq -c '.labels // "none"' 2>/dev/null || echo "?"
}
out="$(created_labels FJ)"
check "a configured starting status is applied on its tracker" "$([ "$out" = "[11]" ] && echo 1 || echo 0)" "$out"
out="$(created_labels FJ2)"
check "an adopted equivalent is applied on the tracker that adopted it" "$([ "$out" = "[12]" ] && echo 1 || echo 0)" "$out"
out="$(created_labels GH)"
check "a declined (false) starting status applies nothing" "$([ "$out" = '"none"' ] || [ "$out" = "[]" ] && echo 1 || echo 0)" "$out"
check "…and the decline is still recorded (not collapsed into absent)" "$(ok jq -e '.issueTrackers[] | select(.ref == "GH") | .labels.status | has("new") and .new == false' "$CFG")"
out="$(created_labels GL)"
check "an absent (never asked) starting status applies nothing" "$([ "$out" = '"none"' ] || [ "$out" = "[]" ] && echo 1 || echo 0)" "$out"
check "…and stays absent, so the next rerun offers it" "$(ok jq -e '.issueTrackers[] | select(.ref == "GL") | .labels.status | has("new") | not' "$CFG")"

section "label adoption is per tracker"
cp "$CFG" "$SANDBOX/before-adopt.json"
finalize "$CFG" FJ2 '{"status":{"to-test":"ready-for-test"},"model":{"sol":"sol"}}'
check "adopted names land on the tracker being reconciled" \
	"$(ok jq -e '.issueTrackers[] | select(.ref == "FJ2") | .labels.status["to-test"] == "ready-for-test" and .labels.model.sol == "sol"' "$CFG")"
check "its carried-forward names are kept" \
	"$(ok jq -e '.issueTrackers[] | select(.ref == "FJ2") | .labels.status["in-progress"] == "wip" and .labels.status.new == "status/triage"' "$CFG")"
check "every other tracker is byte-for-byte unchanged" \
	"$(ok jq -e -n --slurpfile a "$SANDBOX/before-adopt.json" --slurpfile b "$CFG" '
		[$a[0].issueTrackers[] | select(.ref != "FJ2")] == [$b[0].issueTrackers[] | select(.ref != "FJ2")]')"
out="$(cd "$R" && "$DISP" issues tracker --tracker FJ2 | jq -r '.labels.status["to-test"]')"
check "the dispatcher hands the tracker's own adopted name to readers" "$([ "$out" = ready-for-test ] && echo 1 || echo 0)" "$out"
: >"$CURL_LOG"
(cd "$R" && "$DISP" labels create --tracker GL --name bug --color '#d73a4a' --description 'Something is broken' >/dev/null 2>&1) || true
check "labels create --tracker creates on that tracker's host only" \
	"$(grep -q 'gitlab.com' "$CURL_LOG" && grep -q 'gl-secret' "$CURL_LOG" && ! grep -Eq 'git.example.com|api.github.com' "$CURL_LOG" && echo 1 || echo 0)" "$(cat "$CURL_LOG")"

section "changing the default — explicit only"
switch_default "$CFG" kan
check "the switch recipe leaves exactly one default, the one asked for" \
	"$(ok jq -e '[.issueTrackers[] | select(.default == true) | .ref] == ["KAN"]' "$CFG")"
check "a bare number follows the new default" "$(ok jq -e '.tracker == "KAN" and .number == "KAN-9"' <<<"$(resolve "$R" --number 9)")"
check "a qualified id keeps its tracker after the switch" "$(ok jq -e '.tracker == "FJ"' <<<"$(resolve "$R" --number FJ-9)")"
merge_entry "$CFG" '{"ref":"LATE","name":"Added after the switch","backend":"github","api":"https://api.github.com","owner":"acme","repo":"late","labels":{}}'
check "a tracker added after the switch does not take the default" \
	"$(ok jq -e '[.issueTrackers[] | select(.default == true) | .ref] == ["KAN"]' "$CFG")"

section "skill contract (prose)"
says() { grep -Fq -- "$2" "$1"; }
check "add-an-issue-tracker is a packaged skill with its own name" \
	"$(ok grep -q '^name: add-an-issue-tracker$' "$TRACKER_SKILL")"
check "add-an-issue-tracker starts with the runtime preflight" \
	"$(ok says "$TRACKER_SKILL" 'follow [runtime preflight](../../references/runtime.md)')"
check "its triggers cover adding / connecting a tracker" \
	"$(grep -q 'add an issue tracker' <<<"$(sed -n '/^description:/p' "$TRACKER_SKILL")" && grep -q 'connect Jira' <<<"$(sed -n '/^description:/p' "$TRACKER_SKILL")" && echo 1 || echo 0)"
check "it verifies with auth check --tracker" "$(ok says "$TRACKER_SKILL" 'flight auth check --tracker <REF>')"
check "it documents all three starting-status states" \
	"$(says "$TRACKER_SKILL" '| absent | never asked |' && says "$TRACKER_SKILL" '| `false` | declined |' && says "$TRACKER_SKILL" '| a string | configured |' && echo 1 || echo 0)"
check "it prefers the Jira project key, else GH/FJ/GL" \
	"$(says "$TRACKER_SKILL" 'the project key' && says "$TRACKER_SKILL" '`FJ` (Forgejo/Gitea), `GH` (GitHub), `GL` (GitLab)' && echo 1 || echo 0)"
check "it never renames, recolors or deletes labels" "$(ok says "$TRACKER_SKILL" 'Never rename, recolor, or delete an existing label')"
check "it keys own credentials under secrets.issueTrackers.<REF>" "$(ok says "$TRACKER_SKILL" 'secrets.issueTrackers.<REF>.token')"
check "setting-up-a-repo delegates trackers to add-an-issue-tracker" \
	"$(ok says "$SETUP_SKILL" '**REQUIRED SUB-SKILL:** run [add-an-issue-tracker](../add-an-issue-tracker/SKILL.md)')"
check "setting-up-a-repo keeps the preflight gate question (#229)" \
	"$(says "$SETUP_SKILL" '| Repo check command (preflight gate) | `code.preflight`' && says "$SETUP_SKILL" 'Offer a repo check command — the preflight gate' && echo 1 || echo 0)"
check "setting-up-a-repo no longer asks the starting status itself" \
	"$(! grep -q '^| Starting status' "$SETUP_SKILL" && echo 1 || echo 0)"
check "setting-up-a-repo keeps worker model, prompt ledger, gitignore and breadcrumb steps" \
	"$(says "$SETUP_SKILL" '`code.queueBatches.defaultModel`' && says "$SETUP_SKILL" '`code.promptLog.enabled`' \
		&& says "$SETUP_SKILL" '`.flightdirector/batches/`' && says "$SETUP_SKILL" '`.flightdirector/config.local.json`' \
		&& says "$SETUP_SKILL" 'Issue tracking — flight' && echo 1 || echo 0)"
check "setting-up-a-repo describes batches/ as manifests and retained work identities" \
	"$(ok says "$SETUP_SKILL" 'retained work identities')"
check "setting-up-a-repo keeps the legacy .lightspeed/ migration" "$(ok says "$SETUP_SKILL" 'git mv .lightspeed/config.json .flightdirector/config.json')"
check "setting-up-a-repo migrates older schemas with reconcile, never by hand" \
	"$(says "$SETUP_SKILL" 'Never hand-convert an older config' && says "$SETUP_SKILL" 'flight reconcile' && echo 1 || echo 0)"
check "the breadcrumb example uses tracker-qualified branches" \
	"$(says "$SETUP_SKILL" 'feature/<ref>-<N>-<slug>' && says "$SETUP_SKILL" '--tracker <REF>' && echo 1 || echo 0)"

section "breadcrumb target file — AGENTS.md by default, no CLAUDE.md stub (FJ-246)"
check "only AGENTS.md: the block goes in AGENTS.md and no CLAUDE.md is created" \
	"$(ok says "$SETUP_SKILL" '| only `AGENTS.md` | Put the block in `AGENTS.md`. Don'"'"'t create a `CLAUDE.md`. |')"
check "neither: only AGENTS.md is created" \
	"$(ok says "$SETUP_SKILL" '| neither | Create `AGENTS.md` with the block — only `AGENTS.md`. |')"
check "only CLAUDE.md: the block goes in CLAUDE.md as-is, no split" \
	"$(ok says "$SETUP_SKILL" '| only `CLAUDE.md` | Put the block in `CLAUDE.md` and use it as-is — no `AGENTS.md`, no split. |')"
check "both: the block goes in AGENTS.md, with the @AGENTS.md import offer kept" \
	"$(ok says "$SETUP_SKILL" '| both | Put the block in `AGENTS.md`. If `CLAUDE.md` has no `@AGENTS.md` import, offer to add one at its top. |')"
check "the skill no longer offers to create a CLAUDE.md containing @AGENTS.md" \
	"$(! grep -qiE 'create (one|a `CLAUDE\.md`) contain|a `CLAUDE\.md` containing `@AGENTS\.md`' "$SETUP_SKILL" && echo 1 || echo 0)"
check "the skill no longer recommends splitting a CLAUDE.md-only repo" \
	"$(! grep -qi 'Recommend the split' "$SETUP_SKILL" && echo 1 || echo 0)"
check "the description no longer says AGENTS.md is imported by CLAUDE.md" \
	"$(! sed -n '/^description:/p' "$SETUP_SKILL" | grep -q 'imported by CLAUDE.md' && echo 1 || echo 0)"

section "skill inventories"
skills_dir="$(find "$REPO_ROOT/flight/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | sed 's#/SKILL.md$##; s#.*/##' | sort)"
readme_rows="$(grep -oE '^\| `[a-z-]+` \|' "$REPO_ROOT/flight/README.md" | tr -d '|` ' | sort)"
check "flight/README.md lists exactly the packaged skills" "$([ "$skills_dir" = "$readme_rows" ] && echo 1 || echo 0)" "dir: $(tr '\n' ' ' <<<"$skills_dir") readme: $(tr '\n' ' ' <<<"$readme_rows")"
guide_rows="$(grep -oE '\| \*\*[a-z-]+\*\* \|' "$REPO_ROOT/flight/GUIDE.md" | sed 's/[|* ]//g' | sort -u)"
check "the GUIDE's workflow table lists exactly the packaged skills" "$([ "$skills_dir" = "$guide_rows" ] && echo 1 || echo 0)" "dir: $(tr '\n' ' ' <<<"$skills_dir") guide: $(tr '\n' ' ' <<<"$guide_rows")"
count="$(printf '%s\n' "$skills_dir" | wc -l | tr -d ' ')"
words="zero one two three four five six seven eight nine ten eleven twelve"
word="$(echo "$words" | cut -d' ' -f$((count + 1)))"
check "flight/README.md's skill count matches ($count)" "$(grep -qi "^$word skills" "$REPO_ROOT/flight/README.md" && echo 1 || echo 0)"

section "no private hosts or token contents in shared setup docs"
DOCS=(flight/skills/setting-up-a-repo/SKILL.md flight/skills/add-an-issue-tracker/SKILL.md
	flight/references/flight-setup.md flight/references/adapter-contract.md flight/references/backends.md
	flight/references/default-labels.md flight/GUIDE.md flight/README.md README.md)
bad_hosts=""
for d in "${DOCS[@]}"; do
	hosts="$(grep -oE 'https?://[A-Za-z0-9.<>_-]+' "$REPO_ROOT/$d" | sed -E 's#https?://##' | sort -u || true)"
	for h in $hosts; do
		case "$h" in
			example.com|*.example.com|example.atlassian.net|your-site.atlassian.net|\<*) ;;
			github.com|api.github.com|gitlab.com|docs.github.com|docs.gitlab.com) ;;
			id.atlassian.com|developer.atlassian.com|support.atlassian.com|keepachangelog.com|semver.org) ;;
			claude.com|aaronwood.dev|davewood.com) ;;
			*) bad_hosts="$bad_hosts $d:$h" ;;
		esac
	done
done
check "every URL in the shared docs is a public service or an example.com placeholder" "$([ -z "$bad_hosts" ] && echo 1 || echo 0)" "$bad_hosts"
forbidden="$(cd "$REPO_ROOT" && grep -liE 'darkstar|tulip|telus' "${DOCS[@]}" || true)"
check "no internal project or host names" "$([ -z "$forbidden" ] && echo 1 || echo 0)" "$forbidden"
tokens="$(cd "$REPO_ROOT" && grep -nE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}|ATATT[A-Za-z0-9_-]{20,}|"token"[[:space:]]*:[[:space:]]*"[^"<…]{12,}"' "${DOCS[@]}" || true)"
check "no token-shaped values (only <placeholders>)" "$([ -z "$tokens" ] && echo 1 || echo 0)" "$tokens"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
