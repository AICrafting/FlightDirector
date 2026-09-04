#!/usr/bin/env bash
# Unit tests for per-harness Lightspeed config reconciliation metadata.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/lightspeed/scripts/lightspeed"
EXPECTED_VERSION="$(jq -r '.version' "$REPO_ROOT/lightspeed/.codex-plugin/plugin.json")"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

git -C "$SANDBOX" init -q
mkdir -p "$SANDBOX/.lightspeed"
cat >"$SANDBOX/.lightspeed/config.json" <<'JSON'
{"custom":{"preserve":true},"code":{"backend":"forgejo"}}
JSON

(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r '.schemaVersion' "$SANDBOX/.lightspeed/config.json")" = 1 ]
[ "$(jq -r '.harnesses.codex.reconciledWith' "$SANDBOX/.lightspeed/config.json")" = "$EXPECTED_VERSION" ]
[ "$(jq -r '.custom.preserve' "$SANDBOX/.lightspeed/config.json")" = true ]

before="$(sha256sum "$SANDBOX/.lightspeed/config.json" | cut -d' ' -f1)"
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
after="$(sha256sum "$SANDBOX/.lightspeed/config.json" | cut -d' ' -f1)"
[ "$before" = "$after" ]

if (cd "$SANDBOX" && "$DISP" reconcile --harness unknown) 2>/dev/null; then
	exit 1
fi

printf 'reconcile tests passed\n'
