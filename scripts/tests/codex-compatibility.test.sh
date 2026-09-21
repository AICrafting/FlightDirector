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
# INVARIANT: one positive per CONDITION that decides whether a zone is finished, and each
# pattern spans the WHOLE condition rather than a recognisable fragment of it. The site is not
# the unit of failure: Section 5 alone carries three conditions (every zone, marker form, 4a
# sweep finished), so pinning one leaves the other two rewritable — "every" became "any" and the
# sweep conjunct vanished while the marker positive still matched. Antecedent without consequent
# is the same trap one level down: "look for the ticket=all line" kept matching when the
# "unfinished" it leads to was flipped to "finished". A condition added below with no line here
# is a visible omission. Each pattern is still as short as it can be while covering the whole
# condition, because every positive is a hostage to rewording; `.` stands in for a backtick and
# `..` for a bold marker, so the patterns survive SC2016 and BRE quantifier quirks alike.
# The connective is part of the condition too: Section 5's two halves are pinned by ONE pattern
# spanning the `**and**` between them, because two separate patterns both kept matching when the
# `and` was changed to an `or`.
says "$QB/SKILL.md" 'classify from its .ticket=all. line, wherever it sits: no .ticket=all status=done. → ..agent still working..'
says "$QB/SKILL.md" 'ticket=all. line reads .status=done., render that zone.s header'
says "$QB/SKILL.md" 'look for that zone.s .ticket=all. line. No such line means the zone is ..unfinished, regardless of what the agent said..'
says "$QB/SKILL.md" 'match on .ticket=all., not on position'
says "$QB/SKILL.md" 'Once every zone has a .ticket=all. line reading .status=done. or .status=safety-valved. ..and.. its 4a sweep .when one is configured. has finished'
says "$QB/SKILL.md" 'Look for the zone.s .ticket=all. line; no such line means unfinished, whatever the report said'
says "$QB/references/dispatch-claude.md" 'ticket=all'

if says "$QB/SKILL.md" run_in_background; then exit 1; fi
says "$QB/references/dispatch-claude.md" 'dies with'

printf 'Codex compatibility contract tests passed\n'
