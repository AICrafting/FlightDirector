#!/usr/bin/env bash
# Regression tests for schema-3 named issue tracker migration.
set -euo pipefail

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

repo() {
	local r="$SANDBOX/$1"
	mkdir -p "$r/.flightdirector"
	git -C "$r" init -q
	printf '%s\n' "$r"
}

# Split legacy issue config becomes one independent default tracker. Machine-local
# effective values stay in the local file, and every unrelated/stamp value survives.
R="$(repo split)"
cat >"$R/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 2,
  "custom": {"keep": true},
  "code": {"backend":"forgejo","api":"https://code.invalid/api","owner":"public","repo":"app","stages":[{"name":"develop"}]},
  "issues": {"backend":"github","api":"https://issues.invalid/api","owner":"public-issues","repo":"backlog","customFalse":false,"customNull":null},
  "labels": {"status":{"new":false,"done":"status/done"},"unknown":{"x":"y"}},
  "harnesses": {"claude":{"plugins":{"other":{"reconciledWith":"8.0.0"}}}}
}
JSON
cat >"$R/.flightdirector/config.local.json" <<'JSON'
{"issues":{"owner":"private-owner"},"labels":{"status":{"new":"status/inbox"}},"localOnly":true}
JSON
cat >"$R/.flightdirector/secrets.json" <<'JSON'
{"code":{"token":"code-secret"},"issues":{"token":"issue-secret","extra":false}}
JSON
(cd "$R" && "$DISP" reconcile --harness codex >/dev/null)
CFG="$R/.flightdirector/config.json"; LOCAL="$R/.flightdirector/config.local.json"; SEC="$R/.flightdirector/secrets.json"
check "migration advances to schema 3" "$([ "$(jq -r '.schemaVersion' "$CFG")" = 3 ] && echo 1 || echo 0)"
check "split issue backend chooses its shorthand ref" "$([ "$(jq -r '.issueTrackers[0].ref' "$CFG")" = GH ] && echo 1 || echo 0)"
check "migration creates exactly one default" "$(jq -e '[.issueTrackers[] | select(.default == true)] | length == 1' "$CFG" >/dev/null && echo 1 || echo 0)"
check "tracked config never receives local coordinates" "$(jq -e '.issueTrackers[0].owner == "public-issues" and (.issueTrackers[0].owner != "private-owner")' "$CFG" >/dev/null && echo 1 || echo 0)"
check "local override becomes a complete replacement tracker array" "$(jq -e '.issueTrackers | length == 1 and .[0].owner == "private-owner" and .[0].repo == "backlog"' "$LOCAL" >/dev/null && echo 1 || echo 0)"
check "local starting status remains a configured string" "$(jq -e '.issueTrackers[0].labels.status.new == "status/inbox"' "$LOCAL" >/dev/null && echo 1 || echo 0)"
check "tracked declined starting status remains false" "$(jq -e '.issueTrackers[0].labels.status.new == false' "$CFG" >/dev/null && echo 1 || echo 0)"
check "unknown issue false/null fields survive" "$(jq -e '.issueTrackers[0].customFalse == false and (.issueTrackers[0] | has("customNull")) and .issueTrackers[0].customNull == null' "$CFG" >/dev/null && echo 1 || echo 0)"
check "unknown labels and top-level values survive" "$(jq -e '.issueTrackers[0].labels.unknown.x == "y" and .custom.keep == true' "$CFG" >/dev/null && echo 1 || echo 0)"
check "only the running harness stamp changes" "$(jq -e --arg v "$VERSION" '.harnesses.codex.plugins.flight.reconciledWith == $v and .harnesses.claude.plugins.other.reconciledWith == "8.0.0"' "$CFG" >/dev/null && echo 1 || echo 0)"
check "issue secret moves under stable tracker ref" "$(jq -e '.issueTrackers.GH.token == "issue-secret" and .issueTrackers.GH.extra == false' "$SEC" >/dev/null && echo 1 || echo 0)"
check "code secret is preserved and legacy issue secret removed" "$(jq -e '.code.token == "code-secret" and (has("issues") | not)' "$SEC" >/dev/null && echo 1 || echo 0)"

before="$(sha256sum "$CFG" "$LOCAL" "$SEC")"
(cd "$R" && "$DISP" reconcile --harness codex >/dev/null)
after="$(sha256sum "$CFG" "$LOCAL" "$SEC")"
check "repeated reconciliation is byte-identical" "$([ "$before" = "$after" ] && echo 1 || echo 0)"

# An inherited tracker copies only issue coordinates (not stage policy), and gets
# an independent keyed credential even when the old effective token came from code.
R="$(repo inherited)"
cat >"$R/.flightdirector/config.json" <<'JSON'
{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://one.invalid/api","owner":"acme","repo":"widget","stages":[{"name":"main"}],"signature":{"enabled":false}},"labels":{"status":{"new":"status/new"}}}
JSON
printf '%s\n' '{"code":{"token":"shared-old-token"}}' >"$R/.flightdirector/secrets.json"
(cd "$R" && "$DISP" reconcile --harness claude >/dev/null)
check "inherited Forgejo tracker resolves to FJ" "$(jq -e '.issueTrackers[0].ref == "FJ" and .issueTrackers[0].backend == "forgejo"' "$R/.flightdirector/config.json" >/dev/null && echo 1 || echo 0)"
check "code stage policy stays out of tracker" "$(jq -e '.code.stages[0].name == "main" and (.issueTrackers[0] | has("stages") | not) and (.issueTrackers[0] | has("signature") | not)' "$R/.flightdirector/config.json" >/dev/null && echo 1 || echo 0)"
check "configured starting status string survives" "$(jq -e '.issueTrackers[0].labels.status.new == "status/new"' "$R/.flightdirector/config.json" >/dev/null && echo 1 || echo 0)"
check "inherited code token is copied, never implicitly referenced" "$(jq -e '.code.token == "shared-old-token" and .issueTrackers.FJ.token == "shared-old-token"' "$R/.flightdirector/secrets.json" >/dev/null && echo 1 || echo 0)"

# Absence is distinct from false and a string.
R="$(repo absent)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"gitlab","api":"https://git.invalid/api","owner":"acme","repo":"x"},"labels":{"status":{"done":"done"}}}' >"$R/.flightdirector/config.json"
(cd "$R" && "$DISP" reconcile --harness codex >/dev/null)
check "absent starting status stays absent" "$(jq -e '.issueTrackers[0].labels.status | has("new") | not' "$R/.flightdirector/config.json" >/dev/null && echo 1 || echo 0)"

# A retry can resume after secrets/local conversion but before the tracked config
# was stamped. This is the on-disk state an interrupted ordered migration leaves.
R="$(repo retry)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://x.invalid","owner":"o","repo":"r"},"issues":{"backend":"forgejo"},"labels":{}}' >"$R/.flightdirector/config.json"
printf '%s\n' '{"issueTrackers":{"FJ":{"token":"already-moved"}},"code":{"token":"keep"}}' >"$R/.flightdirector/secrets.json"
(cd "$R" && "$DISP" reconcile --harness codex >/dev/null)
check "interrupted migration retry completes" "$(jq -e '.schemaVersion == 3 and .issueTrackers[0].ref == "FJ"' "$R/.flightdirector/config.json" >/dev/null && echo 1 || echo 0)"
check "retry preserves already-moved secret" "$(jq -e '.issueTrackers.FJ.token == "already-moved" and .code.token == "keep"' "$R/.flightdirector/secrets.json" >/dev/null && echo 1 || echo 0)"

# Mixed legacy/new forms in one file are repairable errors and do not mutate it.
R="$(repo conflict)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo"},"issues":{"backend":"github"},"issueTrackers":[{"ref":"FJ","name":"One","default":true,"backend":"forgejo","labels":{}}]}' >"$R/.flightdirector/config.json"
before="$(sha256sum "$R/.flightdirector/config.json")"
if (cd "$R" && "$DISP" reconcile --harness codex >/dev/null 2>"$R/err"); then rc=0; else rc=$?; fi
check "mixed old/new tracker config is rejected" "$([ "$rc" != 0 ] && grep -qi 'both.*issues.*issueTrackers\|mixed' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
after="$(sha256sum "$R/.flightdirector/config.json")"
check "failed migration leaves tracked config byte-identical" "$([ "$before" = "$after" ] && echo 1 || echo 0)"

# This runtime must reject a future schema on both reconciliation and normal reads.
R="$(repo future)"
printf '%s\n' '{"schemaVersion":4,"code":{"backend":"forgejo"},"issueTrackers":[{"ref":"FJ","name":"One","default":true,"backend":"forgejo","labels":{}}]}' >"$R/.flightdirector/config.json"
if (cd "$R" && "$DISP" reconcile --harness codex >/dev/null 2>"$R/reconcile.err"); then r1=0; else r1=$?; fi
if (cd "$R" && "$DISP" config '.code.backend' >/dev/null 2>"$R/config.err"); then r2=0; else r2=$?; fi
check "future schema is rejected by reconcile" "$([ "$r1" != 0 ] && grep -qi 'newer schema\|schema.*4' "$R/reconcile.err" && echo 1 || echo 0)" "$(cat "$R/reconcile.err")"
check "future schema is rejected by ordinary config reads" "$([ "$r2" != 0 ] && grep -qi 'newer schema\|schema.*4' "$R/config.err" && echo 1 || echo 0)" "$(cat "$R/config.err")"

# New routing switches must not silently fall through to legacy single-tracker dispatch.
R="$(repo legacy-selector)"
printf '%s\n' '{"schemaVersion":2,"code":{"backend":"forgejo","api":"https://old.invalid/api","owner":"o","repo":"r"}}' >"$R/.flightdirector/config.json"
if (cd "$R" && "$DISP" issues list --tracker FJ >"$R/out" 2>"$R/err"); then rc=0; else rc=$?; fi
check "tracker selector requires migration" "$([ "$rc" != 0 ] && grep -qi 'reconcile\|schema 3' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"
if (cd "$R" && "$DISP" issues list --all-trackers >"$R/out" 2>"$R/err"); then rc=0; else rc=$?; fi
check "all-trackers view requires migration" "$([ "$rc" != 0 ] && grep -qi 'reconcile\|schema 3' "$R/err" && echo 1 || echo 0)" "$(cat "$R/err")"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
