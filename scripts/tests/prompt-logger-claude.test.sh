#!/usr/bin/env bash
# Unit tests for the Claude Code prompt-log producer (flight/scripts/prompt-logger/claude.py),
# the shared pricing file, the `flight prompt-log` dispatcher route (opt-in gating), and the
# `summary` consumer. Fixtures mimic Claude Code's transcript JSONL: one entry per content
# block sharing a requestId, isSidechain flags, and Anthropic usage blocks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOGGER="$ROOT/flight/scripts/prompt-logger/claude.py"
DISP="$ROOT/flight/scripts/flight"
FIXTURES="$ROOT/scripts/tests/fixtures/prompt-logger"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }
assert_jq() { check "$1" "$(jq -e "$2" "$3" >/dev/null 2>&1 && echo 1 || echo 0)"; }

make_repo() {	# make_repo <dir> <enabled true|false>
	mkdir -p "$1/.flightdirector"; git -C "$1" init -q
	printf '{"code":{"promptLog":{"enabled":%s}}}\n' "$2" >"$1/.flightdirector/config.json"
}
invoke() {	# invoke <mode> <event-json> <repo> <state-dir>  (direct producer call)
	printf '%s' "$2" | env -u ANTHROPIC_API_KEY -u FLIGHT_CLAUDE_AUTH_TOKEN -u FLIGHT_CLAUDE_AUTH_MODE \
		FLIGHT_REPO_ROOT="$3" FLIGHT_PROMPT_LOG_STATE_DIR="$4" python3 "$LOGGER" "$1"
}
# The prompt hook records time.time() as the turn start and Stop only counts assistant
# entries at/after it. The fixtures carry fixed 2026-09-06T12:00 timestamps, so after each
# `prompt` we backdate the recorded start to 11:59 — between the fixture's stale earlier
# turn (10:00) and the turn under test.
backdate_state() {	# backdate_state <state-dir>
	for f in "$1"/state-*.json; do
		python3 - "$f" <<'EOF'
import json,sys,datetime
p=sys.argv[1]; s=json.load(open(p))
s["started_at"]=datetime.datetime(2026,9,6,11,59,0,tzinfo=datetime.timezone.utc).timestamp()
json.dump(s,open(p,"w"))
EOF
	done
}

# ---------------------------------------------------------------------------
# 1. main turn: sums the turn's requests, dedupes content blocks, skips older
#    turns and sidechains, prices via the bundled family table
# ---------------------------------------------------------------------------
R="$T/main"; S="$T/state-main"; make_repo "$R" true
prompt="$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"main prompt"}')"
invoke prompt "$prompt" "$R" "$S"; backdate_state "$S"
stop="$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-main.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"Stop",transcript_path:$path,stop_hook_active:false}')"
invoke stop "$stop" "$R" "$S" 2>"$T/main.err"
LOG="$R/.flightdirector/prompt-log.jsonl"
check "stop writes exactly one row" "$([ "$(wc -l <"$LOG")" = 1 ] && echo 1 || echo 0)"
assert_jq "identity fields are the frozen schema" '.provider=="anthropic" and .harness=="claude" and .session_id=="session-main" and (.turn_id|length)>0 and .prompt=="main prompt" and .model=="claude-fable-5-1"' "$LOG"
# req_1 (10 + 1000 + 20000, out 300) counted once despite two content blocks; req_2 (5 + 500 + 21000, out 200); old turn + sidechain excluded
assert_jq "input_tokens is the TOTAL prompt (uncached + cache write + cache read) across the turn" '.input_tokens == (10+1000+20000)+(5+500+21000)' "$LOG"
assert_jq "output and reasoning tokens summed once per request" '.output_tokens==500 and .reasoning_output_tokens==120' "$LOG"
assert_jq "cache counters summed" '.cache_creation_tokens==1500 and .cache_read_tokens==41000' "$LOG"
# fable-5 family: uncached 15 @10, cache write 1500 @12.5, cache read 41000 @1.0, output 500 @50  (per million)
assert_jq "cost uses the bundled family pricing for claude-fable-5-1" '(.cost_usd*1e9|round) == ((15*10 + 1500*12.5 + 41000*1.0 + 500*50)/1e6*1e9|round)' "$LOG"
assert_jq "cost_basis defaults to api-equivalent without an API key" '.cost_basis=="api-equivalent"' "$LOG"
assert_jq "duration is recorded" '.duration_seconds != null and .duration_seconds > 0' "$LOG"
check "no warnings on a clean main turn" "$([ ! -s "$T/main.err" ] && echo 1 || echo 0)"
invoke stop "$stop" "$R" "$S" 2>/dev/null || true
check "a second Stop for the same session without a new prompt writes nothing" "$([ "$(wc -l <"$LOG")" = 1 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 2. API-key auth → actual-api
# ---------------------------------------------------------------------------
R="$T/api"; S="$T/state-api"; make_repo "$R" true
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"s-api",cwd:$cwd,prompt:"p"}')" "$R" "$S"; backdate_state "$S"
printf '%s' "$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-main.jsonl" '{session_id:"s-api",cwd:$cwd,transcript_path:$path}')" \
	| env FLIGHT_REPO_ROOT="$R" FLIGHT_PROMPT_LOG_STATE_DIR="$S" ANTHROPIC_API_KEY=test-only python3 "$LOGGER" stop 2>/dev/null
assert_jq "ANTHROPIC_API_KEY → cost_basis actual-api" '.cost_basis=="actual-api"' "$R/.flightdirector/prompt-log.jsonl"

# ---------------------------------------------------------------------------
# 3. subagent: own transcript, parent session, agent_id as turn_id, priced per model
# ---------------------------------------------------------------------------
R="$T/sub"; S="$T/state-sub"; make_repo "$R" true
sub="$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-subagent.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"agent-abc",agent_type:"general-purpose",agent_transcript_path:$path}')"
invoke subagent-stop "$sub" "$R" "$S" 2>"$T/sub.err"
LOG="$R/.flightdirector/prompt-log.jsonl"
assert_jq "subagent row keeps the parent session and uses agent_id as turn_id" '.subagent==true and .session_id=="session-main" and .turn_id=="agent-abc" and .model=="claude-opus-5"' "$LOG"
assert_jq "subagent usage summed once per request" '.input_tokens==(2+33000+0)+(3+1000+33000) and .output_tokens==3000 and .reasoning_output_tokens==400' "$LOG"
assert_jq "subagent priced with the opus-5 family" '(.cost_usd*1e9|round) == ((5*5 + 34000*6.25 + 33000*0.5 + 3000*25)/1e6*1e9|round)' "$LOG"
invoke subagent-stop "$sub" "$R" "$S" 2>/dev/null
check "repeated SubagentStop for the same agent does not duplicate" "$([ "$(wc -l <"$LOG")" = 1 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 4. failure modes: missing transcript → null usage + warning; unknown model → null cost + warning
# ---------------------------------------------------------------------------
R="$T/missing"; S="$T/state-missing"; make_repo "$R" true
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"s-miss",cwd:$cwd,prompt:"p"}')" "$R" "$S"
invoke stop "$(jq -nc --arg cwd "$R" '{session_id:"s-miss",cwd:$cwd,transcript_path:"/nonexistent/transcript.jsonl"}')" "$R" "$S" 2>"$T/miss.err"
assert_jq "unreadable transcript → null usage and cost, row still written" '.input_tokens==null and .output_tokens==null and .cost_usd==null and .cost_basis==null' "$R/.flightdirector/prompt-log.jsonl"
check "unreadable transcript warns on stderr" "$(grep -q 'cannot read transcript' "$T/miss.err" && echo 1 || echo 0)"

R="$T/unknown"; S="$T/state-unknown"; make_repo "$R" true
sed 's/claude-fable-5-1/mystery-model-9/g' "$FIXTURES/claude-main.jsonl" >"$T/unknown.jsonl"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"s-unk",cwd:$cwd,prompt:"p"}')" "$R" "$S"; backdate_state "$S"
invoke stop "$(jq -nc --arg cwd "$R" --arg path "$T/unknown.jsonl" '{session_id:"s-unk",cwd:$cwd,transcript_path:$path}')" "$R" "$S" 2>"$T/unk.err"
assert_jq "unknown model keeps tokens but null cost" '.model=="mystery-model-9" and .output_tokens==500 and .cost_usd==null' "$R/.flightdirector/prompt-log.jsonl"
check "unknown model warns on stderr" "$(grep -q 'no pricing entry for model mystery-model-9' "$T/unk.err" && echo 1 || echo 0)"

# repo override pricing supplies the unknown model
R="$T/override"; S="$T/state-override"; make_repo "$R" true
printf '%s\n' '{"models":{"mystery-model-9":{"input_per_million":1,"output_per_million":2,"cache_creation_per_million":1,"cache_read_per_million":1}}}' >"$R/.flightdirector/pricing.json"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"s-ovr",cwd:$cwd,prompt:"p"}')" "$R" "$S"; backdate_state "$S"
invoke stop "$(jq -nc --arg cwd "$R" --arg path "$T/unknown.jsonl" '{session_id:"s-ovr",cwd:$cwd,transcript_path:$path}')" "$R" "$S" 2>/dev/null
assert_jq ".flightdirector/pricing.json override prices an otherwise unknown model" '.cost_usd != null and .cost_usd > 0' "$R/.flightdirector/prompt-log.jsonl"

# ---------------------------------------------------------------------------
# 5. dispatcher route: opt-in gating, harness required, summary needs neither
# ---------------------------------------------------------------------------
R="$T/disabled"; make_repo "$R" false
out="$(cd "$R" && printf '{"session_id":"x","prompt":"p"}' | LS_HARNESS=claude FLIGHT_PROMPT_LOG_STATE_DIR="$T/state-dis" "$DISP" prompt-log prompt 2>&1)"; rc=$?
check "promptLog.enabled=false → dispatcher exits 0 silently" "$([ "$rc" = 0 ] && [ -z "$out" ] && echo 1 || echo 0)"
check "…and writes no state" "$([ ! -d "$T/state-dis" ] || [ -z "$(ls -A "$T/state-dis")" ] && echo 1 || echo 0)"
R="$T/noconfig"; mkdir -p "$R"; git -C "$R" init -q
out="$(cd "$R" && printf '{}' | LS_HARNESS=claude "$DISP" prompt-log stop 2>&1)"; rc=$?
check "no .flightdirector/config.json → dispatcher exits 0 silently" "$([ "$rc" = 0 ] && [ -z "$out" ] && echo 1 || echo 0)"
R="$T/enabled"; make_repo "$R" true
(cd "$R" && printf '{}' | "$DISP" prompt-log stop >/dev/null 2>&1) && rc=0 || rc=$?
check "enabled repo without LS_HARNESS → non-zero (misconfigured hook is loud)" "$([ "$rc" != 0 ] && echo 1 || echo 0)"
(cd "$R" && jq -nc --arg cwd "$R" '{session_id:"s-disp",prompt:"via dispatcher",cwd:$cwd}' | LS_HARNESS=claude FLIGHT_PROMPT_LOG_STATE_DIR="$T/state-disp" "$DISP" prompt-log prompt)
check "enabled repo + LS_HARNESS=claude reaches the producer" "$([ -n "$(ls -A "$T/state-disp" 2>/dev/null)" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 6. summary: per harness/model totals across a mixed-provider log, session filter
# ---------------------------------------------------------------------------
R="$T/sum"; make_repo "$R" true
cat >"$R/.flightdirector/prompt-log.jsonl" <<'EOF'
{"timestamp":"2026-09-06T12:00:00+00:00","provider":"anthropic","harness":"claude","session_id":"S1","turn_id":"t1","prompt":"a","model":"claude-fable-5-1","input_tokens":1000,"output_tokens":100,"reasoning_output_tokens":10,"cache_creation_tokens":0,"cache_read_tokens":900,"cost_usd":0.5,"cost_basis":"api-equivalent","duration_seconds":1}
{"timestamp":"2026-09-06T12:01:00+00:00","provider":"openai","harness":"codex","session_id":"S1","turn_id":"t2","prompt":"b","model":"gpt-5.6-sol","input_tokens":2000,"output_tokens":200,"reasoning_output_tokens":50,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":0.25,"cost_basis":"api-equivalent","duration_seconds":2}
{"timestamp":"2026-09-06T12:02:00+00:00","provider":"anthropic","harness":"claude","session_id":"S1","turn_id":"agent-1","prompt":"[subagent]","model":"claude-opus-5","input_tokens":500,"output_tokens":50,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":0.1,"cost_basis":"api-equivalent","duration_seconds":null,"subagent":true}
{"timestamp":"2026-09-06T12:03:00+00:00","provider":"anthropic","harness":"claude","session_id":"S1","turn_id":"t3","prompt":"c","model":"claude-fable-5-1","input_tokens":null,"output_tokens":null,"reasoning_output_tokens":null,"cache_creation_tokens":null,"cache_read_tokens":null,"cost_usd":null,"cost_basis":null,"duration_seconds":3}
{"timestamp":"2026-09-06T12:04:00+00:00","session_id":"S2","prompt":"other session","model":"claude-sonnet-4-6","input_tokens":1,"output_tokens":1,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":9.0,"duration_seconds":1}
EOF
J="$(cd "$R" && "$DISP" prompt-log summary --session S1 --json)"
check "summary filters to the session" "$(jq -e '.rows==4 and .cost_usd==0.85' <<<"$J" >/dev/null && echo 1 || echo 0)"
check "summary groups per harness/provider/model" "$(jq -e '(.groups|length)==3 and (.groups[]|select(.model=="claude-fable-5-1")|.rows)==2' <<<"$J" >/dev/null && echo 1 || echo 0)"
check "summary counts unmeasured and subagent rows" "$(jq -e '.unmeasured_rows==1 and .subagent_rows==1' <<<"$J" >/dev/null && echo 1 || echo 0)"
MD="$(cd "$R" && "$DISP" prompt-log summary --session S1)"
check "markdown summary has the table and the lower-bound note" "$(grep -q '| codex | gpt-5.6-sol |' <<<"$MD" && grep -q 'lower bound' <<<"$MD" && echo 1 || echo 0)"
MD2="$(cd "$R" && "$DISP" prompt-log summary --session NOPE)"
check "no rows → explicit 'estimate only' line" "$(grep -q 'estimate only' <<<"$MD2" && echo 1 || echo 0)"
J3="$(cd "$R" && "$DISP" prompt-log summary --session S2 --json)"
check "legacy rows without provider/harness default to claude/anthropic" "$(jq -e '.groups[0].harness=="claude" and .groups[0].provider=="anthropic"' <<<"$J3" >/dev/null && echo 1 || echo 0)"

# --- unpriced models are named, with the fix (#60) ---
cat >>"$R/.flightdirector/prompt-log.jsonl" <<'EOF'
{"timestamp":"2026-09-06T12:05:00+00:00","provider":"openai","harness":"codex","session_id":"S3","turn_id":"u1","prompt":"x","model":"gpt-7-nova","input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":null,"cost_basis":null,"duration_seconds":1}
{"timestamp":"2026-09-06T12:06:00+00:00","provider":"openai","harness":"codex","session_id":"S3","turn_id":"u2","prompt":"y","model":"gpt-7-nova","input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":null,"cost_basis":null,"duration_seconds":1}
{"timestamp":"2026-09-06T12:07:00+00:00","provider":"anthropic","harness":"claude","session_id":"S3","turn_id":"u3","prompt":"z","model":"claude-fable-5-1","input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":0.01,"cost_basis":"api-equivalent","duration_seconds":1}
EOF
MD4="$(cd "$R" && "$DISP" prompt-log summary --session S3)"
check "unpriced model is named in the summary note" "$(grep -q 'No pricing for \*\*gpt-7-nova\*\* (openai, 2 rows)' <<<"$MD4" && echo 1 || echo 0)"
check "the note says how to fix it (pricing.json override)" "$(grep -q '\.flightdirector/pricing\.json' <<<"$MD4" && echo 1 || echo 0)"
check "priced models do not appear in the note" "$(grep 'No pricing for' <<<"$MD4" | grep -qv 'claude-fable-5-1' && echo 1 || echo 0)"
J4="$(cd "$R" && "$DISP" prompt-log summary --session S3 --json)"
check "json aggregate lists unpriced_models with row counts" "$(jq -e '.unpriced_models==[{"model":"gpt-7-nova","provider":"openai","harness":"codex","rows":2}]' <<<"$J4" >/dev/null && echo 1 || echo 0)"
MD5="$(cd "$R" && "$DISP" prompt-log summary --session S1)"
check "no unpriced note when every measured row is priced" "$(grep -q 'No pricing for' <<<"$MD5" && echo 0 || echo 1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
