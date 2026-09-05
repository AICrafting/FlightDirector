#!/usr/bin/env bash
# Unit tests for per-harness Flight config reconciliation metadata.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
EXPECTED_VERSION="$(jq -r '.version' "$REPO_ROOT/flight/.codex-plugin/plugin.json")"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

git -C "$SANDBOX" init -q
mkdir -p "$SANDBOX/.flightdirector"
cat >"$SANDBOX/.flightdirector/config.json" <<'JSON'
{"custom":{"preserve":true},"code":{"backend":"forgejo"}}
JSON

(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r '.schemaVersion' "$SANDBOX/.flightdirector/config.json")" = 1 ]
[ "$(jq -r '.harnesses.codex.reconciledWith' "$SANDBOX/.flightdirector/config.json")" = "$EXPECTED_VERSION" ]
[ "$(jq -r '.custom.preserve' "$SANDBOX/.flightdirector/config.json")" = true ]

before="$(sha256sum "$SANDBOX/.flightdirector/config.json" | cut -d' ' -f1)"
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
after="$(sha256sum "$SANDBOX/.flightdirector/config.json" | cut -d' ' -f1)"
[ "$before" = "$after" ]

if (cd "$SANDBOX" && "$DISP" reconcile --harness unknown) 2>/dev/null; then
	exit 1
fi

printf 'reconcile tests passed\n'
