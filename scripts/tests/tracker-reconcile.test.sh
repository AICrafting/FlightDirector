#!/usr/bin/env bash
# Schema-3 named issue tracker migration through `flight reconcile` (#197): tracked
# config, machine-local override, secrets and legacy-work bindings — each migrated,
# validated, written resume-safely, and left byte-identical on a repeat run.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
VERSION="$(jq -r '.version' "$REPO_ROOT/flight/.codex-plugin/plugin.json")"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
check() {
	if [ "$2" = 1 ]; then
		printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else
		printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail + 1))
	fi
}
section() { printf '\033[1m── %s ──\033[0m\n' "$1"; }
jqt() { jq -e "$1" "$2" >/dev/null 2>&1 && echo 1 || echo 0; }	# jqt <filter> <file> → 1/0

repo() {
	local r="$SANDBOX/$1"
	mkdir -p "$r/.flightdirector"
	git -C "$r" init -q
	printf '%s\n' "$r"
}
reconcile() {	# reconcile <repo> [harness] — stderr kept in <repo>/err
	local h="${2:-codex}"
	(cd "$1" && "$DISP" reconcile --harness "$h" 2>"$1/err")
}
# sha256sum is GNU; the macOS leg (BSD userland) has shasum.
sum256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
hashes() { (cd "$1/.flightdirector" && find . -type f -not -name '*.lock' | sort | while IFS= read -r f; do sum256 "$f"; done); }

refuses() {	# refuses <name> <pattern> — reconcile fails with <pattern>, no file changes
	local r="$SANDBOX/$1" before rc
	before="$(hashes "$r")"
	if reconcile "$r"; then rc=0; else rc=$?; fi
	[ "$rc" != 0 ] && grep -Eqi -- "$2" "$r/err" && [ "$before" = "$(hashes "$r")" ]
}

# Fake curl for the few dispatches below: record the Authorization header and URL.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""; url=""; hdr=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) : >"$2"; shift 2 ;;
		-w|-X|--data-binary) shift 2 ;;
		-H) hdr="$hdr|$2"; shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf '%s\t%s\n' "$url" "$hdr" >>"${CURL_LOG:?}"
if [ -n "$out" ]; then printf '[]' >"$out"; else printf '[]'; fi
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"
CURL_LOG="$SANDBOX/curl.log"; export CURL_LOG
dispatch() {	# dispatch <repo> [VAR=value …] — issues list; prints the tracker call log
	local r="$1"; shift
	: >"$CURL_LOG"
	(cd "$r" && env PATH="$SANDBOX/bin:$PATH" "$@" "$DISP" issues list --limit 1 >/dev/null 2>&1) || true
	cat "$CURL_LOG"
}

section "split tracker + local override + separate issue token"
R="$(repo split)"
cat >"$R/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 2,
  "custom": {"keep": true},
  "code": {"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"public","repo":"app","stages":[{"name":"develop"}],"signature":{"enabled":false}},
  "issues": {"backend":"github","api":"https://api.github.example.com","owner":"public-issues","repo":"backlog","customFalse":false,"customNull":null},
  "labels": {"status":{"new":false,"done":"status/done"},"model":{"sol":"model/sol"},"unknown":{"x":"y"}},
  "harnesses": {"claude":{"plugins":{"other":{"reconciledWith":"8.0.0"}}}}
}
JSON
cat >"$R/.flightdirector/config.local.json" <<'JSON'
{"issues":{"owner":"private-owner"},"labels":{"status":{"new":"status/inbox"}},"localOnly":true}
JSON
cat >"$R/.flightdirector/secrets.json" <<'JSON'
{"code":{"token":"code-secret"},"issues":{"token":"issue-secret","extra":false}}
JSON
chmod 600 "$R/.flightdirector/secrets.json"
reconcile "$R"
CFG="$R/.flightdirector/config.json"; LOCAL="$R/.flightdirector/config.local.json"; SEC="$R/.flightdirector/secrets.json"
check "migration advances the tracked config to schema 3" "$(jqt '.schemaVersion == 3' "$CFG")"
check "a split GitHub tracker gets the GH ref and is the one default" "$(jqt '(.issueTrackers | length) == 1 and .issueTrackers[0].ref == "GH" and .issueTrackers[0].default == true' "$CFG")"
check "the legacy issues/labels form is gone (only the old-runtime stub remains)" "$(jqt '(has("labels") | not) and .issues.backend == "requires-newer-flight"' "$CFG")"
check "legacyIssueTracker records the migrated default" "$(jqt '.legacyIssueTracker == "GH"' "$CFG")"
check "a tracker on another host gets its own credential slot" "$(jqt '.issueTrackers[0].credentialRef == "GH"' "$CFG")"
check "the complete label map moves into the tracker (model and unknown roles too)" "$(jqt '.issueTrackers[0].labels.model.sol == "model/sol" and .issueTrackers[0].labels.unknown.x == "y" and .issueTrackers[0].labels.status.done == "status/done"' "$CFG")"
check "a declined starting status stays false" "$(jqt '.issueTrackers[0].labels.status.new == false' "$CFG")"
check "unknown issue fields and explicit false/null survive" "$(jqt '.issueTrackers[0].customFalse == false and (.issueTrackers[0] | has("customNull")) and .issueTrackers[0].customNull == null' "$CFG")"
check "code settings and unknown top-level values are untouched" "$(jqt '.code.signature.enabled == false and .code.stages[0].name == "develop" and .custom.keep == true and (.issueTrackers[0] | has("signature") | not)' "$CFG")"
check "only the running harness stamp changes" "$(jq -e --arg v "$VERSION" '.harnesses.codex.plugins.flight.reconciledWith == $v and .harnesses.claude.plugins.other.reconciledWith == "8.0.0" and (.harnesses.claude.plugins | has("flight") | not)' "$CFG" >/dev/null && echo 1 || echo 0)"
check "the tracked config never receives local values" "$(jqt '.issueTrackers[0].owner == "public-issues" and (tostring | test("private-owner|inbox|localOnly") | not)' "$CFG")"
check "the local override becomes a complete tracker array" "$(jqt '(.issueTrackers | length) == 1 and .issueTrackers[0].ref == "GH" and .issueTrackers[0].owner == "private-owner" and .issueTrackers[0].repo == "backlog"' "$LOCAL")"
check "a local starting-status string survives in the local array" "$(jqt '.issueTrackers[0].labels.status.new == "status/inbox" and .issueTrackers[0].labels.status.done == "status/done"' "$LOCAL")"
check "the local file keeps its other keys and drops its legacy keys" "$(jqt '.localOnly == true and (has("issues") | not) and (has("labels") | not)' "$LOCAL")"
check "the issue secret moves under the stable tracker ref" "$(jqt '.issueTrackers.GH.token == "issue-secret" and .issueTrackers.GH.extra == false' "$SEC")"
check "the code secret stays and the legacy issues secret is gone" "$(jqt '.code.token == "code-secret" and (has("issues") | not)' "$SEC")"
# Windows (MSYS / Cygwin) has no POSIX modes — chmod is a no-op on NTFS — so the check means
# nothing there; every other leg still holds reconcile to it.
case "${OSTYPE:-}" in
	msys* | cygwin* | win32) ;;
	*) check "secrets keep their restrictive mode" "$([ "$(stat -c %a "$SEC" 2>/dev/null || stat -f %Lp "$SEC")" = 600 ] && echo 1 || echo 0)" ;;
esac
check "no token appears in reconcile output" "$(! grep -Eq 'code-secret|issue-secret' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
before="$(hashes "$R")"
reconcile "$R"
check "a repeat run changes nothing (config, local, secrets)" "$([ "$before" = "$(hashes "$R")" ] && echo 1 || echo 0)"
check "a repeat run is silent about migration" "$(! grep -q 'migrated\|moved' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
calls="$(dispatch "$R" FLIGHT_TOKEN=env-code-token)"
check "after migration the local coordinates and the tracker's own token are used" "$(grep -q 'repos/private-owner/backlog' <<<"$calls" && grep -q 'issue-secret' <<<"$calls" && ! grep -q 'env-code-token' <<<"$calls" && echo 1 || echo 0)" "$calls"
reconcile "$R" claude
check "the other harness stamps without re-migrating" "$(jq -e --arg v "$VERSION" '.harnesses.claude.plugins.flight.reconciledWith == $v and (.issueTrackers | length) == 1' "$CFG" >/dev/null && echo 1 || echo 0)"

section "issues on the code repository (inherited) — env tokens keep working"
R="$(repo inherited)"
cat >"$R/.flightdirector/config.json" <<'JSON'
{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"widget","stages":[{"name":"main"}]},"labels":{"status":{"new":"status/new"}}}
JSON
printf '%s\n' '{"code":{"token":"shared-token"}}' >"$R/.flightdirector/secrets.json"
reconcile "$R" claude
CFG="$R/.flightdirector/config.json"; SEC="$R/.flightdirector/secrets.json"
check "an inherited Forgejo tracker is FJ with the code coordinates" "$(jqt '.issueTrackers[0].ref == "FJ" and .issueTrackers[0].backend == "forgejo" and .issueTrackers[0].owner == "acme" and .issueTrackers[0].repo == "widget"' "$CFG")"
check "it reuses the code credential explicitly (credentialRef code)" "$(jqt '.issueTrackers[0].credentialRef == "code"' "$CFG")"
check "code stage policy stays out of the tracker" "$(jqt '.code.stages[0].name == "main" and (.issueTrackers[0] | has("stages") | not)' "$CFG")"
check "a configured starting status string survives" "$(jqt '.issueTrackers[0].labels.status.new == "status/new"' "$CFG")"
check "the code token is not copied" "$(jqt '.code.token == "shared-token" and .issueTrackers == {}' "$SEC")"
calls="$(dispatch "$R" FLIGHT_TOKEN=env-token)"
check "an env token still reaches issue operations (CI / rigs)" "$(grep -q 'token env-token' <<<"$calls" && echo 1 || echo 0)" "$calls"
calls="$(dispatch "$R")"
check "without env the code secret is used" "$(grep -q 'token shared-token' <<<"$calls" && echo 1 || echo 0)" "$calls"
R="$(repo inherited-nosecrets)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"widget"}}' >"$R/.flightdirector/config.json"
reconcile "$R"
calls="$(dispatch "$R" LS_TOKEN=ci-token)"
check "an env-only setup (no secrets file) migrates and keeps working" "$(grep -q 1 <<<"$(jqt '.issueTrackers[0].credentialRef == "code"' "$R/.flightdirector/config.json")" && grep -q 'token ci-token' <<<"$calls" && [ ! -e "$R/.flightdirector/secrets.json" ] && echo 1 || echo 0)" "$calls"

section "credential choices"
R="$(repo same-target-own-token)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"widget"},"issues":{"owner":"acme"}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"code":{"token":"code-t"},"issues":{"token":"issue-t"}}' >"$R/.flightdirector/secrets.json"
reconcile "$R"
check "same target but a separate issue token → own credential, token moved" "$(grep -q 1 <<<"$(jqt '.issueTrackers[0].credentialRef == "FJ"' "$R/.flightdirector/config.json")" && jqt '.issueTrackers.FJ.token == "issue-t" and .code.token == "code-t"' "$R/.flightdirector/secrets.json")"
calls="$(dispatch "$R" FLIGHT_TOKEN=env-t)"
check "…and an env token never shadows it" "$(grep -q 'token issue-t' <<<"$calls" && echo 1 || echo 0)" "$calls"

R="$(repo same-host-other-repo)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"widget"},"issues":{"repo":"tickets"}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"code":{"token":"code-t"}}' >"$R/.flightdirector/secrets.json"
reconcile "$R"
check "same host, other repo, no issue token → shares the code credential (credentialRef code)" "$(jqt '.issueTrackers[0].credentialRef == "code" and .issueTrackers[0].repo == "tickets"' "$R/.flightdirector/config.json")"
check "…and the code token is never copied into issueTrackers" "$(jqt '.issueTrackers == {} and .code.token == "code-t"' "$R/.flightdirector/secrets.json")"
calls="$(dispatch "$R" LS_TOKEN=env-t)"
check "…so an env token still reaches the sibling repo's issues" "$(grep -q 'repos/acme/tickets/issues.*token env-t' <<<"$calls" && echo 1 || echo 0)" "$calls"
# The reviewer's fixture: an env-only setup whose issues live in a sibling repo on the
# code host. Before, migration gave it its own (empty) credential and LS_TOKEN stopped working.
R="$(repo sibling-env-only)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"o","repo":"r","stages":[{"name":"develop"}]},"issues":{"repo":"backlog"}}' >"$R/.flightdirector/config.json"
reconcile "$R"
calls="$(dispatch "$R" LS_TOKEN=ci-token)"
check "a sibling-repo tracker with no secrets file keeps working with LS_TOKEN" "$(grep -q 1 <<<"$(jqt '.issueTrackers[0].credentialRef == "code"' "$R/.flightdirector/config.json")" && grep -q 'repos/o/backlog/issues.*token ci-token' <<<"$calls" && [ ! -e "$R/.flightdirector/secrets.json" ] && echo 1 || echo 0)" "$calls"

R="$(repo same-token-twice)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"widget"},"issues":{"repo":"tickets"}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"code":{"token":"same-t"},"issues":{"token":"same-t"}}' >"$R/.flightdirector/secrets.json"
reconcile "$R"
check "an issue token equal to the code token is not a separate token (credentialRef code)" "$(jqt '.issueTrackers[0].credentialRef == "code"' "$R/.flightdirector/config.json")"
check "…and it is dropped, not copied under issueTrackers" "$(jqt '.issueTrackers == {} and (has("issues") | not) and .code.token == "same-t"' "$R/.flightdirector/secrets.json")"

R="$(repo other-host-no-token)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"widget"},"issues":{"backend":"github","api":"https://api.github.example.com","owner":"acme","repo":"widget"}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"code":{"token":"code-t"}}' >"$R/.flightdirector/secrets.json"
reconcile "$R"
check "another host with no issue token → the code token is NOT sent there" "$(jqt '(.issueTrackers.GH // {}) | has("token") | not' "$R/.flightdirector/secrets.json")"
check "…and reconcile says the tracker needs its own credential" "$(grep -q 'issueTrackers\["GH"\].token' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
R="$(repo other-host-no-secrets)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"widget"},"issues":{"backend":"github","api":"https://api.github.example.com","owner":"acme","repo":"widget"}}' >"$R/.flightdirector/config.json"
reconcile "$R"
check "another host with no secrets file at all → still says the tracker needs its own credential" "$(grep -q 'issueTrackers\["GH"\].token' "$R/err" && [ ! -e "$R/.flightdirector/secrets.json" ] && echo 1 || echo 0)" "$(cat "$R/err")"

R="$(repo jira)"
printf '%s\n' '{"code":{"backend":"none","stages":[{"name":"main","merge":"pr"}]},"issues":{"backend":"jira","api":"https://example.atlassian.net","project":"KAN","email":"bot@example.com"},"labels":{"status":{"to-test":"status/to-test"}}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"issues":{"token":"jira-t"}}' >"$R/.flightdirector/secrets.json"
reconcile "$R"
check "a Jira tracker takes its project key as ref" "$(jqt '.issueTrackers[0].ref == "KAN" and .issueTrackers[0].project == "KAN" and .issueTrackers[0].email == "bot@example.com" and .issueTrackers[0].credentialRef == "KAN"' "$R/.flightdirector/config.json")"
check "the Jira token moves under the project ref" "$(jqt '.issueTrackers.KAN.token == "jira-t"' "$R/.flightdirector/secrets.json")"

section "the three starting-status states"
R="$(repo absent)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"gitlab","api":"https://gitlab.example.com/api/v4","owner":"acme","repo":"x"},"labels":{"status":{"done":"done"}}}' >"$R/.flightdirector/config.json"
reconcile "$R"
check "an absent starting status stays absent" "$(jqt '.issueTrackers[0].ref == "GL" and (.issueTrackers[0].labels.status | has("new") | not)' "$R/.flightdirector/config.json")"
R="$(repo nolabels)"
printf '%s\n' '{"code":{"backend":"github","api":"https://api.github.example.com","owner":"acme","repo":"x"}}' >"$R/.flightdirector/config.json"
reconcile "$R"
check "a config with no labels at all gets an empty label map" "$(jqt '.issueTrackers[0].labels == {}' "$R/.flightdirector/config.json")"

section "schema-3 configs: two same-backend trackers, independent secrets"
R="$(repo two-trackers)"
cat >"$R/.flightdirector/config.json" <<'JSON'
{"schemaVersion":3,"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"app"},
 "issueTrackers":[
  {"ref":"FJ","name":"Private","default":true,"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"app","credentialRef":"code","labels":{"status":{"new":false}}},
  {"ref":"FJB","name":"Other","default":false,"backend":"forgejo","api":"https://other.example.com/api/v1","owner":"x","repo":"y","labels":{}}
 ],
 "harnesses":{"codex":{"plugins":{"flight":{"reconciledWith":"0.0.1"}}}}}
JSON
printf '%s\n' '{"code":{"token":"a"},"issueTrackers":{"FJB":{"token":"b"}}}' >"$R/.flightdirector/secrets.json"
before_trackers="$(jq -S '.issueTrackers' "$R/.flightdirector/config.json")"; sec_before="$(sum256 <"$R/.flightdirector/secrets.json")"
reconcile "$R"
check "an old stamp is refreshed" "$(jq -e --arg v "$VERSION" '.harnesses.codex.plugins.flight.reconciledWith == $v' "$R/.flightdirector/config.json" >/dev/null && echo 1 || echo 0)"
check "trackers, refs, default and label decisions are preserved" "$([ "$before_trackers" = "$(jq -S '.issueTrackers' "$R/.flightdirector/config.json")" ] && echo 1 || echo 0)"
check "secrets associations are untouched" "$([ "$sec_before" = "$(sum256 <"$R/.flightdirector/secrets.json")" ] && echo 1 || echo 0)"
check "no second default is appended" "$(jqt '[.issueTrackers[] | select(.default)] | length == 1' "$R/.flightdirector/config.json")"
before="$(hashes "$R")"; reconcile "$R"
check "an up-to-date schema-3 repo is a no-op" "$([ "$before" = "$(hashes "$R")" ] && echo 1 || echo 0)"
printf '%s\n' '{"code":{"promptLog":{"enabled":true}}}' >"$R/.flightdirector/config.local.json"
before="$(hashes "$R")"; reconcile "$R"
check "a local override that does not touch trackers is left byte-identical" "$([ "$before" = "$(hashes "$R")" ] && echo 1 || echo 0)"
jq '.issueTrackers[1].default = true' "$R/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$R/.flightdirector/config.json"
before="$(hashes "$R")"
if reconcile "$R"; then rc=0; else rc=$?; fi
check "an invalid schema-3 config fails reconcile" "$([ "$rc" != 0 ] && grep -q 'exactly one tracker' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
check "…without writing anything" "$([ "$before" = "$(hashes "$R")" ] && echo 1 || echo 0)"

section "another clone pulls an already-migrated config"
R="$(repo clone2)"
cat >"$R/.flightdirector/config.json" <<'JSON'
{"schemaVersion":3,"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"app"},
 "issues":{"backend":"requires-newer-flight"},"legacyIssueTracker":"FJ",
 "issueTrackers":[{"ref":"FJ","name":"Forgejo issues","default":true,"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"acme","repo":"app","credentialRef":"code","labels":{"status":{"done":"status/done"}}}]}
JSON
jq --arg v "$VERSION" '.harnesses.codex.plugins.flight.reconciledWith = $v' "$R/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$R/.flightdirector/config.json"
printf '%s\n' '{"code":{"owner":"me"},"labels":{"status":{"new":"status/mine"}}}' >"$R/.flightdirector/config.local.json"
printf '%s\n' '{"code":{"token":"c"},"issues":{"token":"legacy-issue"}}' >"$R/.flightdirector/secrets.json"
tracked_before="$(sum256 <"$R/.flightdirector/config.json")"
reconcile "$R"
check "the tracked config is not rewritten (already current)" "$([ "$tracked_before" = "$(sum256 <"$R/.flightdirector/config.json")" ] && echo 1 || echo 0)"
check "its legacy local override is still migrated" "$(jqt '(has("labels") | not) and .issueTrackers[0].labels.status.new == "status/mine" and .issueTrackers[0].labels.status.done == "status/done"' "$R/.flightdirector/config.local.json")"
check "a local code-coordinate override still reaches the inherited tracker" "$(jqt '.issueTrackers[0].owner == "me" and .issueTrackers[0].ref == "FJ"' "$R/.flightdirector/config.local.json")"
check "its legacy secrets are still migrated" "$(jqt '(has("issues") | not) and .issueTrackers.FJ.token == "legacy-issue" and .code.token == "c"' "$R/.flightdirector/secrets.json")"
before="$(hashes "$R")"; reconcile "$R"
check "and a repeat run is a no-op" "$([ "$before" = "$(hashes "$R")" ] && echo 1 || echo 0)"

section "legacy work bindings (no lifecycle helper required)"
R="$(repo bindings)"
git -C "$R" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$R" branch feature/12-old-work; git -C "$R" branch bugfix/7; git -C "$R" branch feature/fj-3-new-style
git -C "$R" branch feature/007-zeros; git -C "$R" branch release/1.2
git -C "$R" update-ref refs/remotes/origin/feature/30-remote-only HEAD
mkdir -p "$R/.flightdirector/batches"
printf '%s\n' '{"runId":"run1","zones":{"a":[12]}}' >"$R/.flightdirector/batches/run1.json"
printf '.flightdirector/batches/\n.flightdirector/secrets*\n' >"$R/.gitignore"
printf '%s\n' '{"code":{"backend":"github","api":"https://api.github.example.com","owner":"o","repo":"r"}}' >"$R/.flightdirector/config.json"
reconcile "$R"
WI="$R/.flightdirector/batches/work-items/identities.json"
check "reconcile succeeds with legacy branches and manifests present" "$([ -f "$WI" ] && grep -q 1 <<<"$(jqt '.schemaVersion == 3' "$R/.flightdirector/config.json")" && echo 1 || echo 0)" "$(cat "$R/err")"
check "the binding file records the legacy default" "$(jqt '.schemaVersion == 1 and .legacyDefaultTracker == "GH"' "$WI")"
check "a local legacy branch is bound to its full identity" "$(jqt '.branches["feature/12-old-work"] == {tracker:"GH",number:"12",qualified:"GH-12",branchPrefix:"gh-12",legacy:true}' "$WI")"
check "a slug-less legacy branch is bound" "$(jqt '.branches["bugfix/7"].qualified == "GH-7"' "$WI")"
check "a remote-only legacy branch is bound by its branch name" "$(jqt '.branches["feature/30-remote-only"].qualified == "GH-30"' "$WI")"
check "leading zeros bind to the canonical number" "$(jqt '.branches["feature/007-zeros"].number == "7"' "$WI")"
check "qualified and non-issue branches are not bound" "$(jqt '(.branches | has("feature/fj-3-new-style") | not) and (.branches | has("release/1.2") | not) and (.branches | has("main") | not)' "$WI")"
check "a pre-migration batch manifest is bound" "$(jqt '.manifests.run1 == {tracker:"GH",legacy:true}' "$WI")"
check "the manifest itself is left alone" "$(jqt '.zones.a == [12]' "$R/.flightdirector/batches/run1.json")"
check "the binding file is covered by the ignore rule setup already writes" "$(git -C "$R" check-ignore -q .flightdirector/batches/work-items/identities.json && echo 1 || echo 0)"
check "the binding lock is released" "$([ ! -e "$WI.lock" ] && echo 1 || echo 0)"
before="$(hashes "$R")"; reconcile "$R"
check "a repeat run leaves the bindings byte-identical" "$([ "$before" = "$(hashes "$R")" ] && echo 1 || echo 0)"
# Another clone of the same repo reconciles after the default has changed: its own
# unqualified branches must still bind to the tracker the repo migrated FROM.
rm -f "$WI"
jq '.issueTrackers[0].default = false | .issueTrackers += [{ref:"FJ",name:"New default",default:true,backend:"forgejo",api:"https://forge.example.com/api/v1",owner:"o",repo:"r",labels:{}}]' \
	"$R/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$R/.flightdirector/config.json"
reconcile "$R"
check "a later clone binds legacy work to legacyIssueTracker, not the new default" "$(jqt '.legacyDefaultTracker == "GH" and .branches["feature/12-old-work"].tracker == "GH"' "$WI")" "$(cat "$WI" 2>/dev/null)"

section "a failed migration writes nothing, and the retry ends where a clean run does"
R="$(repo interrupted)"
git -C "$R" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$R" branch feature/5-x
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"o","repo":"r"},"issues":{"repo":"tickets"},"labels":{"status":{"new":false}}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"issues":{"owner":"mine"}}' >"$R/.flightdirector/config.local.json"
printf '%s\n' '{"code":{"token":"c"},"issues":{"token":"i"}}' >"$R/.flightdirector/secrets.json"
cp -R "$R" "$SANDBOX/interrupted-clean"
# A binding file bound to a different tracker is found before the first write: secrets,
# the local override and the tracked config must all stay exactly as they were.
mkdir -p "$R/.flightdirector/batches/work-items"
printf '%s\n' '{"schemaVersion":1,"legacyDefaultTracker":"XX","branches":{}}' >"$R/.flightdirector/batches/work-items/identities.json"
before="$(hashes "$R")"
if reconcile "$R"; then rc=0; else rc=$?; fi
check "the run fails with a repairable message" "$([ "$rc" != 0 ] && grep -q "already bound to tracker 'XX'" "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
check "every file is untouched (config, local, secrets, bindings)" "$([ "$before" = "$(hashes "$R")" ] && echo 1 || echo 0)"
check "the failed run reports nothing as moved or migrated" "$(! grep -q 'moved\|migrated' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
check "a failed bind leaves no lock behind" "$([ ! -e "$R/.flightdirector/batches/work-items/identities.json.lock" ] && echo 1 || echo 0)"
rm -f "$R/.flightdirector/batches/work-items/identities.json"
reconcile "$R"
reconcile "$SANDBOX/interrupted-clean"
same=1
for f in config.json config.local.json secrets.json batches/work-items/identities.json; do
	[ "$(jq -S . "$R/.flightdirector/$f")" = "$(jq -S . "$SANDBOX/interrupted-clean/.flightdirector/$f")" ] || same=0
done
check "the retried run ends exactly where an uninterrupted run does" "$same"
check "the retried run kept the separate credential choice" "$(grep -q 1 <<<"$(jqt '.issueTrackers[0].credentialRef == "FJ"' "$R/.flightdirector/config.json")" && jqt '.issueTrackers.FJ.token == "i"' "$R/.flightdirector/secrets.json")"
# The reviewer's fixture: a Jira split whose leftover bindings name FJ. Before, the Jira
# token had already been moved under issueTrackers.PROJ when the bind check failed.
R="$(repo jira-bind-conflict)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"o","repo":"r","stages":[{"name":"develop"}]},"issues":{"backend":"jira","api":"https://acme.atlassian.net","project":"PROJ","email":"a@b.c"}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"code":{"token":"FORGE"},"issues":{"token":"JIRATOK"}}' >"$R/.flightdirector/secrets.json"
mkdir -p "$R/.flightdirector/batches/work-items"
printf '%s\n' '{"schemaVersion":1,"legacyDefaultTracker":"FJ","branches":{},"manifests":{}}' >"$R/.flightdirector/batches/work-items/identities.json"
check "a bind conflict on a Jira migration is refused with every file untouched" "$(refuses jira-bind-conflict "already bound to tracker 'FJ'" && echo 1 || echo 0)" "$(cat "$R/err")"
check "…the Jira token is still in the legacy slot" "$(jqt '.issues.token == "JIRATOK" and (has("issueTrackers") | not)' "$R/.flightdirector/secrets.json")"

section "per-machine migration targets legacyIssueTracker, not today's default"
# The repo migrated from GitHub (legacyIssueTracker GH); since then a Jira project became
# the default. A clone that still has the pre-migration secrets and local override pulls it.
clone_repo() {	# clone_repo <name> — the reviewer's scenario, before this clone reconciles
	local r; r="$(repo "$1")"
	cat >"$r/.flightdirector/config.json" <<'JSON'
{"schemaVersion":3,"code":{"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"o","repo":"r","stages":[{"name":"develop"}]},
 "issues":{"backend":"requires-newer-flight"},"legacyIssueTracker":"GH",
 "issueTrackers":[
  {"ref":"GH","name":"GitHub issues","backend":"github","api":"https://api.github.com","owner":"o","repo":"backlog","credentialRef":"GH"},
  {"ref":"PROJ","name":"Jira","default":true,"backend":"jira","api":"https://acme.atlassian.net","project":"PROJ","email":"a@b.c"}]}
JSON
	jq --arg v "$VERSION" '.harnesses.codex.plugins.flight.reconciledWith = $v' "$r/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$r/.flightdirector/config.json"
	printf '%s\n' '{"code":{"token":"FORGE"},"issues":{"token":"GITHUB_PAT"}}' >"$r/.flightdirector/secrets.json"
	printf '%s\n' '{"issues":{"repo":"private-backlog"},"labels":{"status":{"to-test":"gh/to-test"}}}' >"$r/.flightdirector/config.local.json"
	printf '%s\n' "$r"
}
R="$(clone_repo legacy-target)"
reconcile "$R"
check "the clone's legacy issue token moves under the legacy tracker (GH)" "$(jqt '.issueTrackers.GH.token == "GITHUB_PAT" and (.issueTrackers | has("PROJ") | not) and (has("issues") | not)' "$R/.flightdirector/secrets.json")" "$(cat "$R/.flightdirector/secrets.json")"
check "the clone's legacy local override lands on GH, not on the Jira default" "$(jqt '(.issueTrackers[] | select(.ref == "GH") | .repo == "private-backlog" and .labels.status["to-test"] == "gh/to-test") and (.issueTrackers[] | select(.ref == "PROJ") | (has("repo") | not) and (has("labels") | not))' "$R/.flightdirector/config.local.json")" "$(cat "$R/.flightdirector/config.local.json")"
check "the default stays the Jira project" "$(jqt '[.issueTrackers[] | select(.default == true) | .ref] == ["PROJ"]' "$R/.flightdirector/config.local.json")"
check "no token appears in the output" "$(! grep -Eq 'GITHUB_PAT|FORGE' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
calls="$(cd "$R" && : >"$CURL_LOG" && env PATH="$SANDBOX/bin:$PATH" "$DISP" issues list --tracker GH --limit 1 >/dev/null 2>&1; cat "$CURL_LOG")"
check "GH then uses the GitHub token on the local repo" "$(grep -q 'repos/o/private-backlog/issues' <<<"$calls" && grep -q 'GITHUB_PAT' <<<"$calls" && echo 1 || echo 0)" "$calls"

R="$(clone_repo legacy-target-missing)"
jq '.legacyIssueTracker = "NOPE"' "$R/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$R/.flightdirector/config.json"
check "legacyIssueTracker naming no tracker is refused, nothing changed" "$(refuses legacy-target-missing "legacyIssueTracker 'NOPE'.*names no configured tracker" && echo 1 || echo 0)" "$(cat "$R/err")"
R="$(clone_repo legacy-target-absent)"
jq 'del(.legacyIssueTracker)' "$R/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$R/.flightdirector/config.json"
check "no legacyIssueTracker on a schema-3 config is refused, nothing changed" "$(refuses legacy-target-absent 'has no legacyIssueTracker' && echo 1 || echo 0)" "$(cat "$R/err")"
R="$(clone_repo legacy-target-secrets-only)"
rm "$R/.flightdirector/config.local.json"
jq 'del(.legacyIssueTracker)' "$R/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$R/.flightdirector/config.json"
check "…also when only the secrets are legacy" "$(refuses legacy-target-secrets-only 'legacy issues credential in .*has no legacyIssueTracker' && echo 1 || echo 0)" "$(cat "$R/err")"
# This clone's own local tracker array re-points GH at another host: the legacy token
# was never used there, so it must not be moved onto it.
R="$(clone_repo legacy-target-host)"
jq '.issueTrackers[0].backend = "gitlab" | .issueTrackers[0].api = "https://gitlab.example.com/api/v4" | {issueTrackers}' "$R/.flightdirector/config.json" >"$R/.flightdirector/config.local.json"
check "a legacy token is not moved to a tracker on another host" "$(refuses legacy-target-host 'cannot move to tracker GH: it was used with github at https://api.github.com, but tracker GH is gitlab' && echo 1 || echo 0)" "$(cat "$R/err")"
check "…and the refusal never prints the token" "$(! grep -Eq 'GITHUB_PAT|FORGE' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"

section "a code-only local override stays a plain override"
R="$(repo code-only-local)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"o","repo":"r","stages":[{"name":"develop"}]}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"code":{"api":"https://tunnel.example.com/api/v1"}}' >"$R/.flightdirector/config.local.json"
printf '%s\n' '{"code":{"token":"T"}}' >"$R/.flightdirector/secrets.json"
local_before="$(sum256 <"$R/.flightdirector/config.local.json")"
reconcile "$R"
check "no frozen tracker array is written into the local file" "$([ "$local_before" = "$(sum256 <"$R/.flightdirector/config.local.json")" ] && echo 1 || echo 0)" "$(cat "$R/.flightdirector/config.local.json")"
check "reconcile says trackers no longer follow local code overrides" "$(grep -q 'issue trackers no longer follow local code overrides' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
calls="$(dispatch "$R")"
check "the tracker keeps the committed code host and the code credential" "$(grep -q 'https://code.example.com/api/v1/repos/o/r/issues.*token T' <<<"$calls" && echo 1 || echo 0)" "$calls"
reconcile "$R"
check "…once: a repeat run is silent about it" "$(! grep -q 'no longer follow' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
jq '.issueTrackers[0].default = false | .issueTrackers += [{ref:"GH",name:"g",default:true,backend:"github",api:"https://api.github.com",owner:"o",repo:"pub"}]' \
	"$R/.flightdirector/config.json" >"$SANDBOX/x" && cp "$SANDBOX/x" "$R/.flightdirector/config.json"
out="$(cd "$R" && "$DISP" issues tracker 2>"$R/err")"
check "a tracker added to the tracked config later is seen on this clone" "$(jq -e '.ref == "GH"' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out $(cat "$R/err")"
# A local array that predates a tracked addition hides it: warn, once per command.
jq '{code: {api: "https://tunnel.example.com/api/v1"}, issueTrackers: [.issueTrackers[0] | .default = true]}' "$R/.flightdirector/config.json" >"$R/.flightdirector/config.local.json"
(cd "$R" && "$DISP" issues tracker >/dev/null 2>"$R/err") || true
check "a local tracker array missing a tracked ref warns, naming it" "$(grep -q 'lacks GH from' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
(cd "$R" && env PATH="$SANDBOX/bin:$PATH" "$DISP" issues list --all-trackers --limit 1 >/dev/null 2>"$R/err") || true
check "…once per command, even across --all-trackers dispatches" "$([ "$(grep -c 'lacks GH' "$R/err")" = 1 ] && echo 1 || echo 0)" "$(cat "$R/err")"
jq '.issueTrackers[1].default = false' "$R/.flightdirector/config.json" | jq '{issueTrackers}' >"$R/.flightdirector/config.local.json"
(cd "$R" && "$DISP" issues tracker >/dev/null 2>"$R/err") || true
check "a complete local tracker array does not warn" "$(! grep -q 'lacks' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"

section "refusals leave every file untouched"
R="$(repo mixed)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo"},"issues":{"backend":"github"},"issueTrackers":[{"ref":"FJ","name":"One","default":true,"backend":"forgejo","labels":{}}]}' >"$R/.flightdirector/config.json"
check "mixed legacy/named tracked config is refused" "$(refuses mixed 'mixed tracker config' && echo 1 || echo 0)" "$(cat "$R/err")"
R="$(repo mixed-local)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com"}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"labels":{},"issueTrackers":[]}' >"$R/.flightdirector/config.local.json"
check "a mixed local override is refused" "$(refuses mixed-local 'mixed tracker config: .flightdirector/config.local.json' && echo 1 || echo 0)" "$(cat "$R/err")"
R="$(repo mixed-secrets)"
printf '%s\n' '{"code":{"backend":"forgejo","api":"https://forge.example.com"}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"issues":{"token":"a"},"issueTrackers":{"FJ":{"token":"b"}}}' >"$R/.flightdirector/secrets.json"
check "mixed secrets are refused" "$(refuses mixed-secrets 'mixed tracker secrets' && echo 1 || echo 0)" "$(cat "$R/err")"
R="$(repo nobackend)"
printf '%s\n' '{"code":{"stages":[{"name":"main"}]}}' >"$R/.flightdirector/config.json"
check "a config with no tracker backend is refused" "$(refuses nobackend 'neither issues.backend nor code.backend' && echo 1 || echo 0)" "$(cat "$R/err")"
R="$(repo future)"
printf '%s\n' '{"schemaVersion":4,"code":{"backend":"forgejo"},"issueTrackers":[{"ref":"FJ","name":"One","default":true,"backend":"forgejo","labels":{}}]}' >"$R/.flightdirector/config.json"
check "a future schema is refused by reconcile" "$(refuses future 'schema 4, newer than this Flight' && echo 1 || echo 0)" "$(cat "$R/err")"
if (cd "$R" && "$DISP" config '.code.backend' >/dev/null 2>"$R/err"); then rc=0; else rc=$?; fi
check "a future schema is refused by plain config reads" "$([ "$rc" != 0 ] && grep -q 'newer than this Flight' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
if (cd "$R" && LS_HARNESS=claude "$DISP" prompt-log prompt </dev/null >"$R/out" 2>"$R/err"); then rc=0; else rc=$?; fi
check "prompt-log hooks stay silent on a future schema" "$([ "$rc" = 0 ] && [ ! -s "$R/err" ] && echo 1 || echo 0)" "rc=$rc $(cat "$R/err")"

section "routing needs the migration"
R="$(repo legacy-selector)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://forge.example.com/api/v1","owner":"o","repo":"r"}}' >"$R/.flightdirector/config.json"
for args in "issues list --tracker FJ" "issues list --all-trackers" "issues resolve --number 1" "issues tracker" "labels list --tracker FJ" "auth check --tracker FJ"; do
	# shellcheck disable=SC2086
	if (cd "$R" && "$DISP" $args >/dev/null 2>"$R/err"); then rc=0; else rc=$?; fi
	check "'$args' on a schema-2 config asks for reconcile" "$([ "$rc" != 0 ] && grep -q 'run flight reconcile' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
done
calls="$(dispatch "$R" FLIGHT_TOKEN=t)"
check "ordinary legacy dispatch keeps working before migration" "$(grep -q 'repos/o/r/issues' <<<"$calls" && echo 1 || echo 0)" "$calls"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
