#!/usr/bin/env bash
# Unit tests for lightspeed/scripts/batch-manifest.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/lightspeed/scripts/batch-manifest"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export BATCH_MANIFEST_ROOT="$SANDBOX"
DIR="$SANDBOX/.lightspeed/batches"

# --- write ---
"$BM" write --run-id RUN1 --zone lightspeed --issues "18 93 12" --zone docs --issues "40 41"
check "write creates the manifest file" "$([ -f "$DIR/RUN1.json" ] && echo 1 || echo 0)"
check "write records zone lightspeed issues" \
	"$([ "$(jq -c '.zones.lightspeed' "$DIR/RUN1.json")" = "[18,93,12]" ] && echo 1 || echo 0)"
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
	"$([ ! -e "$SANDBOX/.lightspeed/evil.json" ] && echo 1 || echo 0)"

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
"$BM" write --run-id RUN2 --zone lightspeed --issues "12 7" --zone rig --issues "50"
groups_out="$("$BM" groups | sort)"
check "groups lists lightspeed union sorted (7,12,18,93)" \
	"$(printf '%s\n' "$groups_out" | grep -qxF "$(printf 'lightspeed\t7,12,18,93')" && echo 1 || echo 0)"
check "groups lists docs (40,41)" \
	"$(printf '%s\n' "$groups_out" | grep -qxF "$(printf 'docs\t40,41')" && echo 1 || echo 0)"
check "groups lists rig (50)" \
	"$(printf '%s\n' "$groups_out" | grep -qxF "$(printf 'rig\t50')" && echo 1 || echo 0)"

# --- heal: keep only live issues; drop empty zones; delete empty manifests ---
# Live set keeps only docs's 40,41. RUN1 loses lightspeed but keeps docs;
# RUN2 loses both lightspeed and rig → deleted.
"$BM" heal --live "40 41"
check "heal deletes a manifest with no zones left (RUN2)" \
	"$([ ! -f "$DIR/RUN2.json" ] && echo 1 || echo 0)"
check "heal keeps RUN1 (docs survives)" \
	"$([ -f "$DIR/RUN1.json" ] && echo 1 || echo 0)"
check "heal drops emptied zone lightspeed from RUN1" \
	"$([ "$(jq -c '.zones.lightspeed // "gone"' "$DIR/RUN1.json")" = '"gone"' ] && echo 1 || echo 0)"
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

printf '\033[1m────────────────────────────\033[0m\n'
printf 'Passed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
