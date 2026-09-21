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

# Phrase checks flatten the file first: markdown rewraps at will, the property does not move.
# `.gitattributes` gives *.md NATIVE line endings, so the MSYS leg reads CRLF and the \r has to
# go before a phrase spanning a line break can match. The herestring keeps `grep -q` out of a
# pipeline, which under `pipefail` can SIGPIPE and fail the script (SC2337).
says() {
    local flat
    flat="$(tr -d '\r' < "$1" | tr '\n' ' ' | tr -s ' ')"
    grep -q "$2" <<<"$flat"
}

# (`! grep` is exempt from `set -e`, so the negative checks are spelled out.)
if says "$QB/SKILL.md" 'When all agents return'; then exit 1; fi
says "$QB/SKILL.md" 'regardless of what the agent said'
says "$QB/SKILL.md" "own log watcher"

# The terminal line is found by its ticket=all marker, never by position: with code.preflight
# configured the orchestrator appends 4a lines after it. This is a CLASS check, not a phrase one
# — no instruction anywhere in the skill may key on a line being last, so the skill states the
# property as "never on position" and the three below stay blanket. A legitimate need to write
# "last line" here would mean the rule has an exception, which is what #207 exists to prevent.
if says "$QB/SKILL.md" "last line"; then exit 1; fi
if says "$QB/SKILL.md" "final line"; then exit 1; fi
if says "$QB/SKILL.md" "ends in a terminal line"; then exit 1; fi
says "$QB/SKILL.md" 'never on position'
# Positives pin the three gates to the marker form, since a positional rewrite can always be
# phrased in words the negatives above do not carry ("ends in", "closes with", …).
says "$QB/SKILL.md" 'ticket=all. line reads .status=done'      # 4's render trigger
says "$QB/SKILL.md" 'look for that zone.s .ticket=all. line'   # 4's terminal-line check
says "$QB/SKILL.md" 'zone has a .ticket=all. line reading'     # 5's opening condition

if says "$QB/SKILL.md" run_in_background; then exit 1; fi
says "$QB/references/dispatch-claude.md" 'dies with'

printf 'Codex compatibility contract tests passed\n'
