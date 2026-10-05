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
check "stop writes exactly one row" "$([ "$(wc -l <"$LOG")" -eq 1 ] && echo 1 || echo 0)"
assert_jq "identity fields are the frozen schema" '.provider=="anthropic" and .harness=="claude" and .session_id=="session-main" and (.turn_id|length)>0 and .prompt=="main prompt" and .model=="claude-fable-5-1"' "$LOG"
# req_1 (10 + 1000 + 20000, out 300) counted once despite two content blocks; req_2 (5 + 500 + 21000, out 200); old turn + sidechain excluded
assert_jq "input_tokens is the TOTAL prompt (uncached + cache write + cache read) across the turn" '.input_tokens == (10+1000+20000)+(5+500+21000)' "$LOG"
assert_jq "output and reasoning tokens summed once per request" '.output_tokens==500 and .reasoning_output_tokens==120' "$LOG"
assert_jq "cache counters summed" '.cache_creation_tokens==1500 and .cache_read_tokens==41000' "$LOG"
# fable-5 family: uncached 15 @10, cache write 1500 @12.5, cache read 41000 @1.0, output 500 @50  (per million)
assert_jq "cost uses the bundled family pricing for claude-fable-5-1" '(.cost_usd*1e9|round) == ((15*10 + 1500*12.5 + 41000*0.25 + 500*50)/1e6*1e9|round)' "$LOG"
assert_jq "cost_basis defaults to api-equivalent without an API key" '.cost_basis=="api-equivalent"' "$LOG"
assert_jq "duration is recorded" '.duration_seconds != null and .duration_seconds > 0' "$LOG"
check "no warnings on a clean main turn" "$([ ! -s "$T/main.err" ] && echo 1 || echo 0)"
invoke stop "$stop" "$R" "$S" 2>/dev/null || true
check "a second Stop for the same session without a new prompt writes nothing" "$([ "$(wc -l <"$LOG")" -eq 1 ] && echo 1 || echo 0)"

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
check "repeated SubagentStop for the same agent does not duplicate" "$([ "$(wc -l <"$LOG")" -eq 1 ] && echo 1 || echo 0)"

# --- streamed requests: early content blocks carry a placeholder output count (#155) ---
R="$T/stream"; S="$T/state-stream"; make_repo "$R" true
invoke subagent-stop "$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-subagent-streaming.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"agent-str",agent_type:"general-purpose",agent_transcript_path:$path}')" "$R" "$S" 2>/dev/null
assert_jq "a request's final usage wins over its streaming-start blocks" '.output_tokens==165+500 and .reasoning_output_tokens==40 and .input_tokens==(2+1000+0)+(3+100+1000)' "$R/.flightdirector/prompt-log.jsonl"

# --- harness-internal SubagentStop (no agent_type, nothing measurable) writes no row (#155) ---
R="$T/phantom"; S="$T/state-phantom"; make_repo "$R" true
invoke subagent-stop "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"agent-tick",agent_transcript_path:"/nonexistent/agent-tick.jsonl"}')" "$R" "$S" 2>"$T/phantom.err"
check "untyped SubagentStop with no usage writes no row" "$([ ! -s "$R/.flightdirector/prompt-log.jsonl" ] && echo 1 || echo 0)"
check "skipped SubagentStop says why on stderr" "$(grep -q 'agent-tick.*no row written' "$T/phantom.err" && echo 1 || echo 0)"
invoke subagent-stop "$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-main.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"agent-tick2",transcript_path:$path}')" "$R" "$S" 2>/dev/null
check "untyped SubagentStop falling back to the parent transcript writes no row" "$([ ! -s "$R/.flightdirector/prompt-log.jsonl" ] && echo 1 || echo 0)"
invoke subagent-stop "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"agent-real",agent_type:"general-purpose",agent_transcript_path:"/nonexistent/agent-real.jsonl"}')" "$R" "$S" 2>/dev/null
assert_jq "a typed subagent that cannot be measured still gets a row, with the reason" '.turn_id=="agent-real" and .output_tokens==null and .usage_missing=="unreadable"' "$R/.flightdirector/prompt-log.jsonl"

# --- an agent stops several times; each stop logs only what it adds (#155) ---
# Live capture: every agent fired SubagentStop 2-4 times — parked on a background shell or a
# child agent, woken, then once more after handing its report back. Keeping the first stop
# only (the old dedup) logged 72% of the real cost; logging every stop whole logged 239%.
R="$T/multi"; S="$T/state-multi"; make_repo "$R" true; LOG="$R/.flightdirector/prompt-log.jsonl"
mkdir -p "$T/live"
stop_at() {	# stop_at <agent_id> <fixture.jsonl> <lines>  — the transcript as it stood at that stop, then the hook
	head -n "$3" "$2" >"$T/live/agent-$1.jsonl"
	if [ -f "${2%.jsonl}.meta.json" ]; then cp "${2%.jsonl}.meta.json" "$T/live/agent-$1.meta.json"; fi
	invoke subagent-stop "$(jq -nc --arg cwd "$R" --arg id "$1" --arg path "$T/live/agent-$1.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:$id,agent_type:"general-purpose",agent_transcript_path:$path}')" "$R" "$S" 2>/dev/null
}
MULTI="$FIXTURES/claude-subagent-multistop.jsonl"
stop_at agent-multi "$MULTI" 2	# parked on a background shell
stop_at agent-multi "$MULTI" 4	# woken, answered
stop_at agent-multi "$MULTI" 4	# a stop with nothing new
stop_at agent-multi "$MULTI" 6	# after the hand-back
check "three stops that each added usage write three rows; the idle stop writes none" "$([ "$(wc -l <"$LOG")" -eq 3 ] && echo 1 || echo 0)"
check "each row holds only that stop's increment" "$(jq -se '[.[].output_tokens]==[100,50,400] and [.[].input_tokens]==[30002,30503,30704] and [.[].cache_read_tokens]==[0,30000,30500]' "$LOG" >/dev/null && echo 1 || echo 0)"
check "the rows sum to the whole transcript, tokens and cost" "$(jq -se '(map(.output_tokens)|add)==550 and (map(.input_tokens)|add)==(2+30000)+(3+500+30000)+(4+200+30500) and ((map(.cost_usd)|add)*1e9|round)==((9*5 + 30700*6.25 + 60500*0.5 + 550*25)/1e6*1e9|round)' "$LOG" >/dev/null && echo 1 || echo 0)"
check "later rows are numbered, the first is not" "$(jq -se '[.[]|.part]==[null,2,3]' "$LOG" >/dev/null && echo 1 || echo 0)"

# an agent first seen unmeasured, then readable: one null row, then everything
R="$T/late"; S="$T/state-late"; make_repo "$R" true; LOG="$R/.flightdirector/prompt-log.jsonl"
late="$(jq -nc --arg cwd "$R" --arg path "$T/live/agent-late.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"agent-late",agent_type:"general-purpose",agent_transcript_path:$path}')"
invoke subagent-stop "$late" "$R" "$S" 2>/dev/null; invoke subagent-stop "$late" "$R" "$S" 2>/dev/null
check "an unmeasurable agent gets one null row, not one per stop" "$(jq -se 'length==1 and .[0].usage_missing=="unreadable"' "$LOG" >/dev/null && echo 1 || echo 0)"
cp "$MULTI" "$T/live/agent-late.jsonl"; invoke subagent-stop "$late" "$R" "$S" 2>/dev/null
check "once its transcript is readable the full usage is logged" "$(jq -se 'length==2 and .[1].output_tokens==550 and (.[1]|has("usage_missing")|not)' "$LOG" >/dev/null && echo 1 || echo 0)"

# --- agents launched by agents: own stops, own transcripts, lineage on the row (#155) ---
# worker (depth 1) -> child (2) -> grandchild (3, the deepest Claude Code allows: it has no
# Agent tool). Stops interleave the way the live capture did.
R="$T/nested"; S="$T/state-nested"; make_repo "$R" true; LOG="$R/.flightdirector/prompt-log.jsonl"
NEST="$FIXTURES/claude-nested"
stop_at worker "$NEST/agent-worker.jsonl" 2			# parked on its child
stop_at child "$NEST/agent-child.jsonl" 2			# parked on the grandchild
stop_at grandchild "$NEST/agent-grandchild.jsonl" 2	# done
stop_at grandchild "$NEST/agent-grandchild.jsonl" 2	# hand-back stop, nothing new
stop_at child "$NEST/agent-child.jsonl" 4
stop_at worker "$NEST/agent-worker.jsonl" 4
check "nested run: one row per stop that added usage (5 of 6)" "$([ "$(wc -l <"$LOG")" -eq 5 ] && echo 1 || echo 0)"
check "each agent's rows sum to its own transcript — a parent never absorbs its child" "$(jq -se 'def out(id): map(select(.turn_id==id).output_tokens)|add; out("worker")==200 and out("child")==100 and out("grandchild")==30' "$LOG" >/dev/null && echo 1 || echo 0)"
check "the ledger total is the three transcripts, nothing twice" "$(jq -se '(map(.input_tokens)|add)==(2+20000)+(3+300+20000)+(2+10000)+(3+200+10000)+(2+5000) and (map(.cost_usd)|all(.!=null))' "$LOG" >/dev/null && echo 1 || echo 0)"
check "rows carry who launched them and how deep" "$(jq -se 'def row(id): map(select(.turn_id==id))[0]; (row("worker")|.spawn_depth==1 and (has("parent_agent_id")|not)) and (row("child")|.spawn_depth==2 and .parent_agent_id=="worker") and (row("grandchild")|.spawn_depth==3 and .parent_agent_id=="child")' "$LOG" >/dev/null && echo 1 || echo 0)"
check "children are priced on their own model" "$(jq -se 'map(select(.turn_id!="worker").model)|unique==["claude-haiku-4-5-20251001"]' "$LOG" >/dev/null && echo 1 || echo 0)"
J5="$(python3 "$ROOT/flight/scripts/prompt-logger/summary.py" --log "$LOG" --session session-main --json)"
check "summary counts agents as well as their rows" "$(jq -e '.subagent_rows==5 and .subagent_agents==3' <<<"$J5" >/dev/null && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 4. failure modes: missing transcript → null usage + warning; unknown model → null cost + warning
# ---------------------------------------------------------------------------
R="$T/missing"; S="$T/state-missing"; make_repo "$R" true
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"s-miss",cwd:$cwd,prompt:"p"}')" "$R" "$S"
invoke stop "$(jq -nc --arg cwd "$R" '{session_id:"s-miss",cwd:$cwd,transcript_path:"/nonexistent/transcript.jsonl"}')" "$R" "$S" 2>"$T/miss.err"
assert_jq "unreadable transcript → null usage and cost, row still written" '.input_tokens==null and .output_tokens==null and .cost_usd==null and .cost_basis==null' "$R/.flightdirector/prompt-log.jsonl"
assert_jq "null-usage row records why" '.usage_missing=="unreadable"' "$R/.flightdirector/prompt-log.jsonl"
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
# re-priced from the tokens (FJ-270): fable-5-1 100 uncached x10 + 900 read x0.25 + 100 out x50;
# gpt-5.6-sol 2000 x4 + 200 out x20; opus-5 500 x5 + 50 out x25 — the logged 0.85 is not used
check "summary filters to the session" "$(jq -e '.rows==4 and (.cost_usd*1e6|round)==21975' <<<"$J" >/dev/null && echo 1 || echo 0)"
check "summary --as-logged sums the logged costs" "$(cd "$R" && "$DISP" prompt-log summary --session S1 --json --as-logged | jq -e '.cost_usd==0.85' >/dev/null && echo 1 || echo 0)"
check "summary groups per harness/provider/model" "$(jq -e '(.groups|length)==3 and (.groups[]|select(.model=="claude-fable-5-1")|.rows)==2' <<<"$J" >/dev/null && echo 1 || echo 0)"
check "summary counts unmeasured and subagent rows" "$(jq -e '.unmeasured_rows==1 and .subagent_rows==1' <<<"$J" >/dev/null && echo 1 || echo 0)"
MD="$(cd "$R" && "$DISP" prompt-log summary --session S1)"
check "markdown summary has the table and the lower-bound note" "$(grep -q '| codex | gpt-5.6-sol |' <<<"$MD" && grep -q 'lower bound' <<<"$MD" && echo 1 || echo 0)"
check "legacy null row (no usage_missing) is reported as reason not recorded" "$(grep -q '1 reason not recorded' <<<"$MD" && echo 1 || echo 0)"
cat >>"$R/.flightdirector/prompt-log.jsonl" <<'EOF'
{"timestamp":"2026-09-06T12:05:00+00:00","provider":"anthropic","harness":"claude","session_id":"S3","turn_id":"u1","prompt":"d","model":"","input_tokens":null,"output_tokens":null,"cost_usd":null,"usage_missing":"unreadable"}
{"timestamp":"2026-09-06T12:06:00+00:00","provider":"anthropic","harness":"claude","session_id":"S3","turn_id":"u2","prompt":"e","model":"","input_tokens":null,"output_tokens":null,"cost_usd":null,"usage_missing":"no-usage"}
{"timestamp":"2026-09-06T12:07:00+00:00","provider":"anthropic","harness":"claude","session_id":"S3","turn_id":"u3","prompt":"f","model":"","input_tokens":null,"output_tokens":null,"cost_usd":null,"usage_missing":"no-usage"}
EOF
MD3="$(cd "$R" && "$DISP" prompt-log summary --session S3)"
check "summary names each null-usage cause" "$(grep -q '3 row(s) had no usage (2 transcript had no usage for the turn, 1 transcript unreadable)' <<<"$MD3" && echo 1 || echo 0)"
check "summary --json breaks unmeasured rows down by cause" "$(cd "$R" && "$DISP" prompt-log summary --session S3 --json | jq -e '.unmeasured_reasons=={"no-usage":2,"unreadable":1}' >/dev/null && echo 1 || echo 0)"
# legacy logs: untyped, unmeasured SubagentStop rows are harness helpers, not unmeasured agents (#155)
cat >>"$R/.flightdirector/prompt-log.jsonl" <<'EOF'
{"timestamp":"2026-09-06T12:08:00+00:00","provider":"anthropic","harness":"claude","session_id":"S6","turn_id":"a1","prompt":"[subagent a1]","model":"","input_tokens":null,"output_tokens":null,"cost_usd":null,"subagent":true}
{"timestamp":"2026-09-06T12:08:30+00:00","provider":"anthropic","harness":"claude","session_id":"S6","turn_id":"a2","prompt":"[subagent a2 (general-purpose)]","model":"","input_tokens":null,"output_tokens":null,"cost_usd":null,"subagent":true}
EOF
J4="$(cd "$R" && "$DISP" prompt-log summary --session S6 --json)"
check "legacy helper-stop rows are set aside, a typed unmeasured agent is not" "$(jq -e '.helper_stop_rows==1 and .unmeasured_rows==1 and .rows==1 and .subagent_rows==1' <<<"$J4" >/dev/null && echo 1 || echo 0)"
MD8="$(cd "$R" && "$DISP" prompt-log summary --session S6)"
check "markdown summary mentions the ignored helper rows" "$(grep -q '1 untyped SubagentStop row(s) from harness helpers ignored' <<<"$MD8" && echo 1 || echo 0)"
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
check "priced models do not appear in the note" "$(grep -qv 'claude-fable-5-1' < <(grep 'No pricing for' <<<"$MD4") && echo 1 || echo 0)"
J4="$(cd "$R" && "$DISP" prompt-log summary --session S3 --json)"
check "json aggregate lists unpriced_models with row counts" "$(jq -e '.unpriced_models==[{"model":"gpt-7-nova","provider":"openai","harness":"codex","rows":2}]' <<<"$J4" >/dev/null && echo 1 || echo 0)"
MD5="$(cd "$R" && "$DISP" prompt-log summary --session S1)"
check "no unpriced note when every measured row is priced" "$(grep -q 'No pricing for' <<<"$MD5" && echo 0 || echo 1)"

# --- zero-cost 'unknown' model rows are trimmed from the rendered table (#121) ---
cat >>"$R/.flightdirector/prompt-log.jsonl" <<'EOF'
{"timestamp":"2026-09-06T12:08:00+00:00","provider":"anthropic","harness":"claude","session_id":"S4","turn_id":"k1","prompt":"real","model":"claude-fable-5-1","input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":0.01,"cost_basis":"api-equivalent","duration_seconds":1}
{"timestamp":"2026-09-06T12:09:00+00:00","provider":"anthropic","harness":"claude","session_id":"S4","turn_id":"k2","prompt":"hook-only","model":"unknown","input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":0.0,"cost_basis":"api-equivalent","duration_seconds":1}
{"timestamp":"2026-09-06T12:10:00+00:00","provider":"anthropic","harness":"claude","session_id":"S4","turn_id":"k3","prompt":"hook-only","model":"unknown","input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":0.0,"cost_basis":"api-equivalent","duration_seconds":1}
{"timestamp":"2026-09-06T12:11:00+00:00","provider":"anthropic","harness":"claude","session_id":"S5","turn_id":"m1","prompt":"real","model":"claude-fable-5-1","input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":0.01,"cost_basis":"api-equivalent","duration_seconds":1}
{"timestamp":"2026-09-06T12:12:00+00:00","provider":"anthropic","harness":"claude","session_id":"S5","turn_id":"m2","prompt":"unpriced","model":"unknown","input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":null,"cost_basis":null,"duration_seconds":1}
EOF
MD6="$(cd "$R" && "$DISP" prompt-log summary --session S4)"
check "zero-cost 'unknown' model rows are dropped from the table" "$(grep -q '| claude | unknown |' <<<"$MD6" && echo 0 || echo 1)"
check "…the Total line still counts every row" "$(grep -q '^| \*\*Total\*\* | | 3 |' <<<"$MD6" && echo 1 || echo 0)"
check "…and a note says how many turns had no model recorded" "$(grep -q '2 turn(s) recorded no model and cost nothing (omitted from the table)' <<<"$MD6" && echo 1 || echo 0)"
J6="$(cd "$R" && "$DISP" prompt-log summary --session S4 --json)"
check "json output still carries the 'unknown' group (trimming is render-only)" "$(jq -e '(.groups|length)==2 and (.groups[]|select(.model=="unknown")|.rows)==2' <<<"$J6" >/dev/null && echo 1 || echo 0)"
MD7="$(cd "$R" && "$DISP" prompt-log summary --session S5)"
check "an 'unknown' row with tokens but no price is kept, marked unpriced" "$(grep -q '| claude | unknown | 1 | .* (+1 unpriced) |' <<<"$MD7" && echo 1 || echo 0)"
check "…and no omitted-turns note is emitted for it" "$(grep -q 'recorded no model' <<<"$MD7" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# 7. pricing (FJ-270): current rates, 5-minute vs 1-hour cache writes, a turn that
#    spans models keeps each model's usage, and summary re-prices from the tokens
# ---------------------------------------------------------------------------
PRICE() {	# PRICE <repo> <model> <usage-json>  → common.price_usage, printed
	python3 -c '
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from common import price_usage
print(price_usage(Path(sys.argv[2]), sys.argv[3], json.loads(sys.argv[4])))
' "$ROOT/flight/scripts/prompt-logger" "$@"
}
R="$T/pricing"; make_repo "$R" true
ISSUE='{"input_tokens":1110000,"output_tokens":100000,"reasoning_output_tokens":0,"cache_creation_tokens":100000,"cache_creation_1h_tokens":100000,"cache_read_tokens":1000000}'
check "Opus 5.5 at published rates: the issue's worked request costs \$3.04" "$([ "$(PRICE "$R" claude-opus-5-5 "$ISSUE")" = 3.04 ] && echo 1 || echo 0)"
check "a [1m] context tag prices as its base model" "$([ "$(PRICE "$R" 'claude-opus-5-5[1m]' "$ISSUE")" = 3.04 ] && echo 1 || echo 0)"
FIVE='{"input_tokens":1110000,"output_tokens":100000,"reasoning_output_tokens":0,"cache_creation_tokens":100000,"cache_read_tokens":1000000}'
check "cache writes with no 1-hour split price at the 5-minute rate" "$([ "$(PRICE "$R" claude-opus-5-5 "$FIVE")" = 2.74 ] && echo 1 || echo 0)"
check "Sonnet 5.x priced at \$2/\$10 with \$0.20 cache reads" "$([ "$(PRICE "$R" claude-sonnet-5-5 "$FIVE")" = 1.47 ] && echo 1 || echo 0)"
check "Fable 5.1 cache reads at \$0.25, Fable 5 at \$1" "$([ "$(PRICE "$R" claude-fable-5-1 "$FIVE")" = 6.6 ] && [ "$(PRICE "$R" claude-fable-5 "$FIVE")" = 7.35 ] && echo 1 || echo 0)"
printf '%s\n' '{"families":{"claude-opus-5-5":{"input_per_million":4,"output_per_million":20,"cache_creation_per_million":5,"cache_read_per_million":0.2}}}' >"$R/.flightdirector/pricing.json"
check "an override without a 1-hour rate falls back to its 5-minute rate" "$([ "$(PRICE "$R" claude-opus-5-5 "$ISSUE")" = 2.74 ] && echo 1 || echo 0)"
rm "$R/.flightdirector/pricing.json"

S="$T/state-ttl"; LOG="$R/.flightdirector/prompt-log.jsonl"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"session-ttl",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"ttl prompt"}')" "$R" "$S"; backdate_state "$S"
invoke stop "$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-cache-ttl.jsonl" '{session_id:"session-ttl",cwd:$cwd,hook_event_name:"Stop",transcript_path:$path}')" "$R" "$S" 2>/dev/null
assert_jq "the 1-hour share of the cache writes is recorded" '.cache_creation_tokens==3500 and .cache_creation_1h_tokens==1300' "$LOG"
assert_jq "a turn that spans models keeps each model's usage" '.usage_by_model["claude-opus-5-5"].output_tokens==500 and .usage_by_model["claude-opus-5-5"].cache_creation_1h_tokens==1300 and .usage_by_model["claude-sonnet-5-5"].cache_creation_tokens==2000 and .usage_by_model["claude-sonnet-5-5"].cache_creation_1h_tokens==0' "$LOG"
# opus-5-5: 15 uncached x4, 200 5m x5, 1300 1h x8, 41000 read x0.2, 500 out x20; sonnet-5-5: 3 x2, 2000 5m x2.5, 50 out x10
assert_jq "each model is priced at its own rates, each cache write at its own TTL" '(.cost_usd*1e9|round) == (((15*4 + 200*5 + 1300*8 + 41000*0.2 + 500*20) + (3*2 + 2000*2.5 + 50*10))/1e6*1e9|round)' "$LOG"

# an agent that changes model between stops: its per-model usage is an increment too
R="$T/inc-models"; S="$T/state-inc-models"; make_repo "$R" true; LOG="$R/.flightdirector/prompt-log.jsonl"
sed 's/"isSidechain":false/"isSidechain":true/' "$FIXTURES/claude-cache-ttl.jsonl" >"$T/sidechain-ttl.jsonl"
stop_at agent-switch "$T/sidechain-ttl.jsonl" 3	# opus-5-5 only so far
stop_at agent-switch "$T/sidechain-ttl.jsonl" 4	# then a sonnet-5-5 request
check "the first stop (one model) records no per-model split" "$(jq -se '.[0].usage_by_model==null and .[0].model=="claude-opus-5-5"' "$LOG" >/dev/null && echo 1 || echo 0)"
check "the next stop's per-model usage holds only what it added" "$(jq -se '.[1].usage_by_model|keys==["claude-sonnet-5-5"] and .["claude-sonnet-5-5"].output_tokens==50' "$LOG" >/dev/null && echo 1 || echo 0)"
check "re-priced, the agent's rows cost what the turn did" "$(python3 "$ROOT/flight/scripts/prompt-logger/summary.py" --log "$LOG" --session session-main --json | jq -e '(.cost_usd*1e9|round) == ((((15*4 + 200*5 + 1300*8 + 41000*0.2 + 500*20) + (3*2 + 2000*2.5 + 50*10))/1e6)*1e9|round)' >/dev/null && echo 1 || echo 0)"

# summary prices from the stored tokens, so a pricing fix reaches turns already logged
R="$T/reprice"; make_repo "$R" true
cat >"$R/.flightdirector/prompt-log.jsonl" <<'EOF'
{"timestamp":"2026-09-06T12:00:00+00:00","provider":"anthropic","harness":"claude","session_id":"R1","turn_id":"r1","prompt":"stale","model":"claude-opus-5-5","input_tokens":1110000,"output_tokens":100000,"reasoning_output_tokens":0,"cache_creation_tokens":100000,"cache_creation_1h_tokens":100000,"cache_read_tokens":1000000,"cost_usd":3.675,"cost_basis":"api-equivalent","duration_seconds":1}
{"timestamp":"2026-09-06T12:01:00+00:00","provider":"anthropic","harness":"claude","session_id":"R1","turn_id":"r2","prompt":"legacy multi-model","model":"claude-opus-5","input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":1.5,"cost_basis":"api-equivalent","duration_seconds":1,"models":{"claude-opus-5":6,"claude-haiku-4-5":4}}
{"timestamp":"2026-09-06T12:02:00+00:00","provider":"openai","harness":"codex","session_id":"R1","turn_id":"r3","prompt":"once unpriced","model":"gpt-7-nova","input_tokens":1000000,"output_tokens":0,"reasoning_output_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"cost_usd":null,"cost_basis":"api-equivalent","duration_seconds":1}
EOF
printf '%s\n' '{"models":{"gpt-7-nova":{"input_per_million":1,"output_per_million":1,"cache_read_per_million":0.1}}}' >"$R/.flightdirector/pricing.json"
JR="$(cd "$R" && "$DISP" prompt-log summary --session R1 --json)"
check "summary re-prices a stale row from its tokens (3.675 logged → 3.04)" "$(jq -e '(.groups[]|select(.model=="claude-opus-5-5")|.cost_usd*1e6|round)==3040000' <<<"$JR" >/dev/null && echo 1 || echo 0)"
check "a row logged unpriced is priced once the override names its model" "$(jq -e '(.groups[]|select(.model=="gpt-7-nova")|.cost_usd==1 and .unpriced_rows==0) and .unpriced_models==[]' <<<"$JR" >/dev/null && echo 1 || echo 0)"
check "a legacy multi-model row (no per-model usage) keeps its logged cost" "$(jq -e '(.groups[]|select(.model=="claude-opus-5")|.cost_usd)==1.5' <<<"$JR" >/dev/null && echo 1 || echo 0)"
check "summary --as-logged adds up the stored costs instead" "$(cd "$R" && "$DISP" prompt-log summary --session R1 --json --as-logged | jq -e '(.cost_usd*1e6|round)==5175000 and (.unpriced_models|length)==1' >/dev/null && echo 1 || echo 0)"
check "re-pricing is quiet (no per-row warnings on stderr)" "$( (cd "$R" && "$DISP" prompt-log summary --session R1 >/dev/null 2>"$T/reprice.err"); [ ! -s "$T/reprice.err" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 8. a message sent while a turn is running (FJ-269): Claude Code fires
#    UserPromptSubmit again inside the same turn, so the turn keeps its id and its
#    start and the prompts accumulate; the one Stop then covers the whole turn
# ---------------------------------------------------------------------------
R="$T/midturn"; S="$T/state-midturn"; make_repo "$R" true; LOG="$R/.flightdirector/prompt-log.jsonl"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"main prompt"}')" "$R" "$S"; backdate_state "$S"
FIRST_TURN="$(jq -r .turn_id "$S"/state-*.json)"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"also check the docs"}')" "$R" "$S"
invoke stop "$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-main.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"Stop",transcript_path:$path}')" "$R" "$S" 2>/dev/null
check "one row for the turn" "$([ "$(wc -l <"$LOG")" -eq 1 ] && echo 1 || echo 0)"
assert_jq "the turn keeps the first prompt's id" ".turn_id==\"$FIRST_TURN\"" "$LOG"
assert_jq "the row counts the turn from its first prompt, not from the queued one" '.input_tokens == (10+1000+20000)+(5+500+21000) and .output_tokens==500' "$LOG"
assert_jq "both prompts are kept, in order, and the queued one is counted" '(.prompt|startswith("main prompt")) and (.prompt|endswith("also check the docs")) and .queued_prompts==1' "$LOG"
assert_jq "a turn with one prompt has no queued_prompts field" '.queued_prompts==null and .prompt=="main prompt"' "$T/main/.flightdirector/prompt-log.jsonl"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"next turn"}')" "$R" "$S"
check "after the Stop, the next prompt starts a new turn" "$([ "$(jq -r .turn_id "$S"/state-*.json)" != "$FIRST_TURN" ] && [ "$(jq -r .prompt "$S"/state-*.json)" = "next turn" ] && echo 1 || echo 0)"

# a turn already logged is closed even if its state outlived the Stop (a Stop racing the hook)
R="$T/stale"; S="$T/state-stale"; make_repo "$R" true; LOG="$R/.flightdirector/prompt-log.jsonl"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"main prompt"}')" "$R" "$S"; backdate_state "$S"
STATE_FILE="$(ls "$S"/state-*.json)"; cp "$STATE_FILE" "$T/stale-state.json"
invoke stop "$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-main.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"Stop",transcript_path:$path}')" "$R" "$S" 2>/dev/null
cp "$T/stale-state.json" "$STATE_FILE"	# the state the racing hook read comes back
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"next turn"}')" "$R" "$S"
check "a logged turn's leftover state does not swallow the next prompt" "$([ "$(jq -r .turn_id "$STATE_FILE")" != "$(jq -r .turn_id "$T/stale-state.json")" ] && [ "$(jq -r .prompt "$STATE_FILE")" = "next turn" ] && echo 1 || echo 0)"

# the next prompt landing between the Stop's row and its state cleanup (FJ-276): the Stop
# must not delete the new turn's state, or that whole turn is missing from the ledger
R="$T/gap"; S="$T/state-gap"; make_repo "$R" true; LOG="$R/.flightdirector/prompt-log.jsonl"
invoke prompt "$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"main prompt"}')" "$R" "$S"; backdate_state "$S"
GAP_FIRST="$(jq -r .turn_id "$S"/state-*.json)"
STOP_GAP="$(jq -nc --arg cwd "$R" --arg path "$FIXTURES/claude-main.jsonl" '{session_id:"session-main",cwd:$cwd,hook_event_name:"Stop",transcript_path:$path}')"
NEXT_GAP="$(jq -nc --arg cwd "$R" '{session_id:"session-main",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"next turn"}')"
env -u ANTHROPIC_API_KEY -u FLIGHT_CLAUDE_AUTH_TOKEN -u FLIGHT_CLAUDE_AUTH_MODE \
	FLIGHT_REPO_ROOT="$R" FLIGHT_PROMPT_LOG_STATE_DIR="$S" python3 - "$ROOT/flight/scripts/prompt-logger" "$STOP_GAP" "$NEXT_GAP" 2>/dev/null <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1])
import claude
written = claude.append_record
def append_then_prompt(*args, **kwargs):
	written(*args, **kwargs)
	claude.save_prompt(json.loads(sys.argv[3]))	# the user's next prompt fires here
claude.append_record = append_then_prompt
claude.finish(json.loads(sys.argv[2]), delegated=False)
EOF
check "the Stop logs its own turn" "$([ "$(wc -l <"$LOG")" -eq 1 ] && [ "$(jq -r .turn_id "$LOG")" = "$GAP_FIRST" ] && echo 1 || echo 0)"
check "the next turn's state, written mid-Stop, survives the Stop's cleanup" "$(ls "$S"/state-*.json >/dev/null 2>&1 && [ "$(jq -r .turn_id "$S"/state-*.json)" != "$GAP_FIRST" ] && [ "$(jq -r .prompt "$S"/state-*.json)" = "next turn" ] && echo 1 || echo 0)"
backdate_state "$S" 2>/dev/null || true
invoke stop "$STOP_GAP" "$R" "$S" 2>/dev/null || true
check "…and the following Stop logs that turn's row" "$([ "$(wc -l <"$LOG")" -eq 2 ] && jq -se '.[1].prompt=="next turn" and .[1].turn_id!=.[0].turn_id' "$LOG" >/dev/null && echo 1 || echo 0)"
check "a Stop still clears its own turn's state" "$(ls "$S"/state-*.json >/dev/null 2>&1 && echo 0 || echo 1)"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
