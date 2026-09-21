#!/usr/bin/env bash
# Static contract checks for the shared Claude/Codex plugin package.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CODEX_MANIFEST="$REPO_ROOT/flight/.codex-plugin/plugin.json"

[ -f "$CODEX_MANIFEST" ]
[ "$(jq -r '.skills' "$CODEX_MANIFEST")" = ./skills/ ]
grep -q 'labels ensure' "$REPO_ROOT/flight/skills/working-an-issue/SKILL.md"
grep -q 'dispatch-codex.md' "$REPO_ROOT/flight/skills/queue-batches/SKILL.md"
grep -q 'dispatch-claude.md' "$REPO_ROOT/flight/skills/queue-batches/SKILL.md"

# #207: a zone is finished when its log says so, not when its agent returns. The rule is
# harness-agnostic (SKILL.md); why a parked agent happens is Claude Code specific (the reference).
QB="$REPO_ROOT/flight/skills/queue-batches"
# (`! grep` is exempt from `set -e`, so the negative checks are spelled out.)
if grep -q 'When all agents return' "$QB/SKILL.md"; then exit 1; fi
grep -q 'regardless of what the agent' "$QB/SKILL.md"
grep -q 'own log watcher' "$QB/SKILL.md"
if grep -q 'run_in_background' "$QB/SKILL.md"; then exit 1; fi
grep -q 'dies with' "$QB/references/dispatch-claude.md"

printf 'Codex compatibility contract tests passed\n'
