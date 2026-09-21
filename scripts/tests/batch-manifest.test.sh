#!/usr/bin/env bash
# Unit tests for flight/scripts/batch-manifest. The first half runs on a pre-schema-3
# repo (plain numbers, unchanged behaviour); the second on schema 3, where entries are
# retained tracker identities (#198) resolved by the real dispatcher.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/flight/scripts/batch-manifest"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export BATCH_MANIFEST_ROOT="$SANDBOX"
DIR="$SANDBOX/.flightdirector/batches"

# --- write ---
"$BM" write --run-id RUN1 --zone flight --issues "18 93 12" --zone docs --issues "40 41"
check "write creates the manifest file" "$([ -f "$DIR/RUN1.json" ] && echo 1 || echo 0)"
check "write records zone flight issues" \
	"$([ "$(jq -c '.zones.flight' "$DIR/RUN1.json")" = "[18,93,12]" ] && echo 1 || echo 0)"
check "write records zone docs issues" \
	"$([ "$(jq -c '.zones.docs' "$DIR/RUN1.json")" = "[40,41]" ] && echo 1 || echo 0)"
check "write records runId" \
	"$([ "$(jq -r '.runId' "$DIR/RUN1.json")" = "RUN1" ] && echo 1 || echo 0)"

# --- error handling ---
if "$BM" write --zone z --issues "1" 2>/dev/null; then
	check "errors when --run-id missing" 0
else
	check "errors when --run-id missing" 1
fi

if "$BM" write --run-id X --issues "1" 2>/dev/null; then
	check "errors when --issues given before --zone" 0
else
	check "errors when --issues given before --zone" 1
fi

if "$BM" write --run-id '../evil' --zone z --issues "1" 2>/dev/null; then
	check "errors on path-traversal --run-id" 0
else
	check "errors on path-traversal --run-id" 1
fi
check "path-traversal --run-id wrote no file outside batches dir" \
	"$([ ! -e "$SANDBOX/.flightdirector/evil.json" ] && echo 1 || echo 0)"

if "$BM" write --run-id 2>/dev/null; then
	check "errors on trailing flag with no value" 0
else
	check "errors on trailing flag with no value" 1
fi

if "$BM" bogus 2>/dev/null; then
	check "errors on unknown command" 0
else
	check "errors on unknown command" 1
fi

# --- groups: merges same-named zones across manifests, unions + sorts ---
"$BM" write --run-id RUN2 --zone flight --issues "12 7" --zone rig --issues "50"
groups_out="$("$BM" groups | sort)"
check "groups lists flight union sorted (7,12,18,93)" \
	"$(grep -qxF "$(printf 'flight\t7,12,18,93')" <<<"$groups_out" && echo 1 || echo 0)"
check "groups lists docs (40,41)" \
	"$(grep -qxF "$(printf 'docs\t40,41')" <<<"$groups_out" && echo 1 || echo 0)"
check "groups lists rig (50)" \
	"$(grep -qxF "$(printf 'rig\t50')" <<<"$groups_out" && echo 1 || echo 0)"

# --- heal: keep only live issues; drop empty zones; delete empty manifests ---
# Live set keeps only docs's 40,41. RUN1 loses flight but keeps docs;
# RUN2 loses both flight and rig → deleted.
"$BM" heal --live "40 41"
check "heal deletes a manifest with no zones left (RUN2)" \
	"$([ ! -f "$DIR/RUN2.json" ] && echo 1 || echo 0)"
check "heal keeps RUN1 (docs survives)" \
	"$([ -f "$DIR/RUN1.json" ] && echo 1 || echo 0)"
check "heal drops emptied zone flight from RUN1" \
	"$([ "$(jq -c '.zones.flight // "gone"' "$DIR/RUN1.json")" = '"gone"' ] && echo 1 || echo 0)"
check "heal keeps docs in RUN1" \
	"$([ "$(jq -c '.zones.docs' "$DIR/RUN1.json")" = "[40,41]" ] && echo 1 || echo 0)"

# Healing against an empty live set removes everything.
"$BM" heal --live ""
check "heal with empty live set clears all manifests" \
	"$([ -z "$(ls -A "$DIR" 2>/dev/null)" ] && echo 1 || echo 0)"

# --- heal tolerates a malformed manifest (missing .zones) without aborting ---
"$BM" write --run-id RUN3 --zone core --issues "60 61"
printf '%s\n' '{"runId":"BAD"}' > "$DIR/BAD.json"
"$BM" heal --live "60 61"   # must NOT crash on BAD.json
check "heal survives a manifest with no .zones (others still healed)" \
	"$([ "$(jq -c '.zones.core' "$DIR/RUN3.json")" = "[60,61]" ] && echo 1 || echo 0)"
check "heal deletes the malformed zero-zone manifest" \
	"$([ ! -f "$DIR/BAD.json" ] && echo 1 || echo 0)"

# --- consume: remove exactly the promoted issues, regardless of their status label ---
rm -f "$DIR"/*.json
"$BM" write --run-id RUN4 --zone skills --issues "64 65 66 84" --zone docs --issues "78 79 87" --zone config --issues "80 88"
"$BM" consume --issues "80 88"
check "consume removes an entire zone when all its issues were promoted (config)" \
	"$([ "$(jq -c '.zones.config // "gone"' "$DIR/RUN4.json")" = '"gone"' ] && echo 1 || echo 0)"
check "consume leaves the other zones untouched" \
	"$([ "$(jq -c '.zones.skills' "$DIR/RUN4.json")" = "[64,65,66,84]" ] && [ "$(jq -c '.zones.docs' "$DIR/RUN4.json")" = "[78,79,87]" ] && echo 1 || echo 0)"
"$BM" consume --issues "65 84"
check "consume removes a subset within a zone" \
	"$([ "$(jq -c '.zones.skills' "$DIR/RUN4.json")" = "[64,66]" ] && echo 1 || echo 0)"
"$BM" consume --issues "999"
check "consume with an unknown issue is a no-op" \
	"$([ "$(jq -c '.zones.skills' "$DIR/RUN4.json")" = "[64,66]" ] && echo 1 || echo 0)"
"$BM" consume --issues "64 66 78 79 87"
check "consume deletes the manifest once every zone is emptied" \
	"$([ ! -f "$DIR/RUN4.json" ] && echo 1 || echo 0)"
if "$BM" consume --issues "" 2>/dev/null; then
	check "consume errors on an empty --issues (would silently do nothing)" 0
else
	check "consume errors on an empty --issues (would silently do nothing)" 1
fi
if "$BM" consume --live "1" 2>/dev/null; then
	check "consume rejects --live (heal's flag)" 0
else
	check "consume rejects --live (heal's flag)" 1
fi
# heal still works unchanged after the refactor
"$BM" write --run-id RUN5 --zone a --issues "1 2" --zone b --issues "3"
"$BM" heal --live "2 3"
check "heal after refactor keeps only the live issues" \
	"$([ "$(jq -c '.zones' "$DIR/RUN5.json")" = '{"a":[2],"b":[3]}' ] && echo 1 || echo 0)"

# ── schema 3: retained tracker identities (#198) ─────────────────────────────
unset FLIGHT_SELF FLIGHT_REPO_ROOT
S3="$SANDBOX/s3"; mkdir -p "$S3/.flightdirector"; git -C "$S3" init -q
export BATCH_MANIFEST_ROOT="$S3"
DIR="$S3/.flightdirector/batches"
cat >"$S3/.flightdirector/config.json" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"acme","repo":"widget","stages":[{"name":"develop"}]},
  "issueTrackers": [
    {"ref":"FJ","name":"Code issues","default":true,"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"acme","repo":"widget"},
    {"ref":"GH","name":"Public issues","backend":"github","api":"https://api.github.com","owner":"acme","repo":"widget"},
    {"ref":"JIR","name":"Jira","backend":"jira","api":"https://jira.example.com","project":"PROJ","email":"bot@example.com"}
  ]
}
JSON
cp "$S3/.flightdirector/config.json" "$SANDBOX/s3.good"
q() { jq -c "[.zones.$2[]?.qualified]" "$DIR/$1.json"; }

"$BM" write --run-id M1 --zone same --issues "FJ-1 GH-1" --zone jira --issues "PROJ-9" --zone bare --issues "12"
check "entries are the resolver's identity objects" \
	"$(jq -e '.zones.same[0] == {"tracker":"FJ","number":"1","qualified":"FJ-1","branchPrefix":"fj-1"}' "$DIR/M1.json" >/dev/null && echo 1 || echo 0)" "$(cat "$DIR/M1.json")"
check "two trackers' issue 1 stay two entries" "$([ "$(q M1 same)" = '["FJ-1","GH-1"]' ] && echo 1 || echo 0)" "$(q M1 same)"
check "a Jira entry keeps its native key" "$(jq -e '.zones.jira[0].number == "PROJ-9" and .zones.jira[0].qualified == "JIR-9"' "$DIR/M1.json" >/dev/null && echo 1 || echo 0)"
check "a bare number given at write time means the current default" "$([ "$(q M1 bare)" = '["FJ-12"]' ] && echo 1 || echo 0)" "$(q M1 bare)"

# The default changes mid-run: retained entries never move.
jq '.issueTrackers |= map(.default = (.ref == "GH"))' "$SANDBOX/s3.good" >"$S3/.flightdirector/config.json"
out="$("$BM" groups | sort)"
check "groups prints qualified ids, unaffected by a default change" \
	"$(grep -qxF "$(printf 'same\tFJ-1,GH-1')" <<<"$out" && grep -qxF "$(printf 'bare\tFJ-12')" <<<"$out" && echo 1 || echo 0)" "$out"
"$BM" consume --issues "GH-1"
check "consume removes only the named tracker's issue 1" "$([ "$(q M1 same)" = '["FJ-1"]' ] && echo 1 || echo 0)" "$(q M1 same)"
"$BM" consume --issues "JIR-9"
check "consume matches a Jira entry by its qualified id" "$(jq -e '.zones.jira == null' "$DIR/M1.json" >/dev/null && echo 1 || echo 0)"
cp "$SANDBOX/s3.good" "$S3/.flightdirector/config.json"
"$BM" write --run-id M2 --zone same --issues "FJ-10 FJ-9 GH-2"
out="$("$BM" groups | sort)"
check "groups merges zones across runs, ordered by tracker then number" \
	"$(grep -qxF "$(printf 'same\tFJ-1,FJ-9,FJ-10,GH-2')" <<<"$out" && echo 1 || echo 0)" "$out"
"$BM" heal --live "FJ-9 FJ-12 GH-2"
check "heal keeps exactly the live qualified ids" \
	"$([ "$(jq -c '.zones | keys' "$DIR/M1.json")" = '["bare"]' ] && [ "$(q M2 same)" = '["FJ-9","GH-2"]' ] && echo 1 || echo 0)" "$(q M2 same)"
rm -f "$DIR"/*.json

# A pre-schema-3 manifest: bound by reconcile to its original tracker.
mkdir -p "$DIR/work-items"
printf '%s\n' '{"runId":"OLD","zones":{"z":[5,6]}}' >"$DIR/OLD.json"
printf '%s\n' '{"runId":"LOOSE","zones":{"z":[7]}}' >"$DIR/LOOSE.json"
printf '%s\n' '{"schemaVersion":1,"branches":{},"manifests":{"OLD":{"tracker":"GH","legacy":true}}}' >"$DIR/work-items/identities.json"
out="$("$BM" groups 2>"$SANDBOX/err")"
check "a legacy manifest resolves through its run's binding, not the default" "$(grep -qxF "$(printf 'z\tGH-5,GH-6')" <<<"$out" && echo 1 || echo 0)" "$out"
check "a legacy manifest with no binding is reported, never guessed" \
	"$(grep -q 'manifest LOOSE' "$SANDBOX/err" && ! grep -q '7' <<<"$out" && echo 1 || echo 0)" "$(cat "$SANDBOX/err")"
"$BM" consume --issues "GH-5" 2>/dev/null
check "consume upgrades a bound legacy manifest to identities" "$([ "$(q OLD z)" = '["GH-6"]' ] && echo 1 || echo 0)" "$(cat "$DIR/OLD.json")"
check "an unbound legacy manifest is left untouched" "$([ "$(jq -c '.zones.z' "$DIR/LOOSE.json")" = '[7]' ] && echo 1 || echo 0)"
printf '%s\n' '{"schemaVersion":1,"legacyDefaultTracker":"FJ","branches":{},"manifests":{"OLD":{"tracker":"GH","legacy":true}}}' >"$DIR/work-items/identities.json"
out="$("$BM" groups | sort)"
check "an unlisted legacy manifest falls back to the migrated legacy default" "$(grep -qxF "$(printf 'z\tFJ-7,GH-6')" <<<"$out" && echo 1 || echo 0)" "$out"
"$BM" heal --live ""
check "heal/consume never touch the work-items bindings subdirectory" "$([ -f "$DIR/work-items/identities.json" ] && echo 1 || echo 0)"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
