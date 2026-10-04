#!/usr/bin/env bash
# Static contract checks for the shared Claude/Codex plugin package.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CODEX_MANIFEST="$REPO_ROOT/flight/.codex-plugin/plugin.json"

[ -f "$CODEX_MANIFEST" ]
[ "$(jq -r '.skills' "$CODEX_MANIFEST")" = ./skills/ ]
# FJ-257: /flight:version is a Claude Code command (commands/ is auto-discovered there). Codex
# manifests have no commands field, so none is invented; GUIDE.md points Codex at the script.
[ "$(jq -r 'has("commands")' "$CODEX_MANIFEST")" = false ]
[ -f "$REPO_ROOT/flight/commands/version.md" ]
grep -q 'scripts/plugin-version.sh' "$REPO_ROOT/flight/GUIDE.md"
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
# INVARIANT: one positive per STATUS VALUE the orchestrator branches on when deciding whether a
# zone is finished, plus one per condition guarding a handoff. That set is CLOSED and enumerated
# in the status-log contract block of the skill itself, so completeness is checkable against the
# file rather than against whether anyone thought of another phrasing — a status added to the
# contract with no line here is a visible omission a reader can spot in ten seconds.
#
#   ticket=all status=done           -> finished; render ⇥
#   ticket=all status=safety-valved  -> NOT finished; render ✗, issues surfaced as deferred
#   status=blocked                   -> NOT finished; the question gets routed
#   no ticket=all line at all        -> NOT finished, whatever the agent reported (two sites)
#   preflight-pass / -fail / -skip   -> the orchestrator's own lines, never the verdict
#
# Each pattern spans a WHOLE condition, antecedent through consequent, and includes the
# connective. Three failure modes are behind that, all found by mutation rather than reasoning:
# a pattern starting after the quantifier matched when "every zone" became "any zone"; a pattern
# covering only the antecedent matched when the "unfinished" it leads to was flipped to
# "finished"; and two patterns over the halves of one condition both matched when the `and`
# between them became an `or`. `.` stands in for a backtick and `..` for a bold marker, which
# keeps the patterns clear of SC2016 and of BRE quantifier quirks.
#
# Both statements of the handoff condition are pinned. Section 5 opens by deferring to "the
# Section 4 condition", so Section 4's sentence IS the condition and Section 5's is a restatement
# — guarding only the restatement is this issue's own defect one level up.
#
# NOT pinned, deliberately, and both of these were checked rather than assumed:
#  - The rationale prose in dispatch-claude.md ("its report is wrong by construction"). It argues
#    FOR the rule rather than being a condition anything branches on, and SKILL.md carries the
#    instruction. Pinning rationale is where a contract test stops guarding a property and starts
#    transcribing the skill.
#  - Text appended AFTER a satisfied gate, e.g. "proceed to Section 5 without waiting". The
#    condition in front of it is untouched, so nothing about the gate changes and there is no
#    behaviour to guard. Do not read that as a hole and pin a fourth fragment of the sentence: a
#    mutation that genuinely weakens the same gate ("Without waiting for the sweep, proceed")
#    does trip, which is what tells the two cases apart.
says "$QB/SKILL.md" 'classify from its .ticket=all. line, wherever it sits: no .ticket=all status=done. → ..agent still working..'
says "$QB/SKILL.md" 'ticket=all. line reads .status=done., render that zone.s header'
says "$QB/SKILL.md" 'ticket=all status=safety-valved. means the zone did not finish its queue'
says "$QB/SKILL.md" 'render its header with .✗. and surface its unfinished issues as deferred'
says "$QB/SKILL.md" 'Once every zone has emitted its terminal line ..and.. its sweep has finished, proceed to Section 5'
says "$QB/SKILL.md" 'look for that zone.s .ticket=all. line. No such line means the zone is ..unfinished, regardless of what the agent said..'
says "$QB/SKILL.md" 'latest line is .status=blocked., that is a question still to route'
says "$QB/SKILL.md" 'match on .ticket=all., not on position'
says "$QB/SKILL.md" 'Once every zone has a .ticket=all. line reading .status=done. or .status=safety-valved. ..and.. its 4a sweep .when one is configured. has finished'
says "$QB/SKILL.md" 'Look for the zone.s .ticket=all. line; no such line means unfinished, whatever the report said'
says "$QB/references/dispatch-claude.md" 'ticket=all'

if says "$QB/SKILL.md" run_in_background; then exit 1; fi
says "$QB/references/dispatch-claude.md" 'dies with'

# FJ-231: promoting-branches' `pr` hop publishes a group only inside the guard on the gate's
# verdict file. Structural, not a phrase check: in the fenced block that opens the PR, the verdict
# guard comes first, then the push, then `pr open`, then the `else` that skips the group — and no
# `continue`, which has no shell loop around it there and falls through to the push.
# (scripts/tests/promote-branches-gate.test.sh runs the real blocks against a red gate.)
PB="$REPO_ROOT/flight/skills/promoting-branches/SKILL.md"
tr -d '\r' < "$PB" | awk '
	/^```/ { if (inb) { if (hit) done = 1; inb = 0 } else if (!done) { inb = 1; n = 0; hit = 0 }; next }
	inb && !done { L[++n] = $0; if (index($0, "pr open --head \"$INT\"")) hit = 1 }
	END {
		if (!done) exit 1
		for (i = 1; i <= n; i++) {
			if (L[i] ~ /continue/) exit 1
			if (!guard && index(L[i], "preflight-verdict-<zone>")) guard = i
			if (!push && index(L[i], "push -u origin \"$INT\"")) push = i
			if (!open && index(L[i], "pr open --head")) open = i
			if (L[i] == "else") els = i
		}
		exit !(guard && push > guard && open > push && els > open)
	}'

printf 'Codex compatibility contract tests passed\n'
