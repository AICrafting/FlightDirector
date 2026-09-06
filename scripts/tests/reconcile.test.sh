#!/usr/bin/env bash
# Unit tests for per-harness × per-plugin Flight config reconciliation metadata.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"
MANIFEST="$REPO_ROOT/flight/.codex-plugin/plugin.json"
EXPECTED_VERSION="$(jq -r '.version' "$MANIFEST")"
EXPECTED_PLUGIN="$(jq -r '.name' "$MANIFEST")"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

CFG="$SANDBOX/.flightdirector/config.json"
git -C "$SANDBOX" init -q
mkdir -p "$SANDBOX/.flightdirector"

# Seed the sandbox config; every test starts from a known shape.
seed() {
	printf '%s\n' "$1" >"$CFG"
}

# --- fresh config: schema 2, stamp nested under the plugin, unknown keys kept ---
seed '{"custom":{"preserve":true},"code":{"backend":"forgejo"}}'

(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r '.schemaVersion' "$CFG")" = 2 ]
[ "$(jq -r --arg p "$EXPECTED_PLUGIN" '.harnesses.codex.plugins[$p].reconciledWith' "$CFG")" = "$EXPECTED_VERSION" ]
[ "$(jq -r '.harnesses.codex.reconciledWith // "absent"' "$CFG")" = absent ]
[ "$(jq -r '.custom.preserve' "$CFG")" = true ]

# --- re-running is a no-op (byte-identical) ---
before="$(sha256sum "$CFG" | cut -d' ' -f1)"
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
after="$(sha256sum "$CFG" | cut -d' ' -f1)"
[ "$before" = "$after" ]

# --- unsupported harness is rejected ---
if (cd "$SANDBOX" && "$DISP" reconcile --harness unknown) 2>/dev/null; then
	exit 1
fi

# --- migration: a legacy (schema 1) bare stamp moves into plugins.flight ---
seed '{"schemaVersion":1,"custom":{"preserve":true},"harnesses":{"codex":{"reconciledWith":"0.9.0"},"claude":{"reconciledWith":"0.9.0"}}}'
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r '.schemaVersion' "$CFG")" = 2 ]
[ "$(jq -r '.harnesses.codex.plugins.flight.reconciledWith' "$CFG")" = "$EXPECTED_VERSION" ]
[ "$(jq -r '.harnesses.codex.reconciledWith // "absent"' "$CFG")" = absent ]
[ "$(jq -r '.custom.preserve' "$CFG")" = true ]
# the other harness is left untouched until it is itself reconciled
[ "$(jq -r '.harnesses.claude.reconciledWith' "$CFG")" = "0.9.0" ]

# --- migration keeps a same-version legacy stamp (and still drops the old key) ---
seed "{\"harnesses\":{\"codex\":{\"reconciledWith\":\"$EXPECTED_VERSION\"}}}"
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r '.harnesses.codex.plugins.flight.reconciledWith' "$CFG")" = "$EXPECTED_VERSION" ]
[ "$(jq -r '.harnesses.codex.reconciledWith // "absent"' "$CFG")" = absent ]

# --- two plugins under one harness do not collide ---
seed '{"schemaVersion":2,"harnesses":{"codex":{"plugins":{"multiclaude":{"reconciledWith":"0.2.0"}}}}}'
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r '.harnesses.codex.plugins.multiclaude.reconciledWith' "$CFG")" = "0.2.0" ]
[ "$(jq -r --arg p "$EXPECTED_PLUGIN" '.harnesses.codex.plugins[$p].reconciledWith' "$CFG")" = "$EXPECTED_VERSION" ]

# --- the downgrade guard is scoped to this plugin's own stamp ---
seed '{"schemaVersion":2,"harnesses":{"codex":{"plugins":{"flight":{"reconciledWith":"99.0.0"}}}}}'
if (cd "$SANDBOX" && "$DISP" reconcile --harness codex) 2>/dev/null; then
	exit 1
fi
# …and a newer *other* plugin never blocks this one
seed '{"schemaVersion":2,"harnesses":{"codex":{"plugins":{"multiclaude":{"reconciledWith":"99.0.0"}}}}}'
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r --arg p "$EXPECTED_PLUGIN" '.harnesses.codex.plugins[$p].reconciledWith' "$CFG")" = "$EXPECTED_VERSION" ]

# --- a newer schemaVersion is never rolled back ---
seed '{"schemaVersion":7,"harnesses":{}}'
(cd "$SANDBOX" && "$DISP" reconcile --harness codex)
[ "$(jq -r '.schemaVersion' "$CFG")" = 7 ]

printf 'reconcile tests passed\n'
