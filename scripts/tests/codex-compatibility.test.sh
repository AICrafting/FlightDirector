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

# Phrase checks flatten newlines first: markdown rewraps at will, the property does not move.
says() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -q "$2"; }

# (`! grep` is exempt from `set -e`, so the negative checks are spelled out.)
if says "$QB/SKILL.md" 'When all agents return'; then exit 1; fi
says "$QB/SKILL.md" 'regardless of what the agent said'
says "$QB/SKILL.md" "own log watcher"
# The terminal line is found by its ticket=all marker, never by being last: with code.preflight
# configured the orchestrator appends 4a lines after it (see the status log contract).
if says "$QB/SKILL.md" "log ends in a terminal line"; then exit 1; fi
if says "$QB/SKILL.md" "read its log's last line"; then exit 1; fi
says "$QB/SKILL.md" 'ticket=all. line reads .status=done'   # . stands in for a backtick
says "$QB/SKILL.md" 'never on the log.s last line'
if says "$QB/SKILL.md" run_in_background; then exit 1; fi
says "$QB/references/dispatch-claude.md" 'dies with'

printf 'Codex compatibility contract tests passed\n'
