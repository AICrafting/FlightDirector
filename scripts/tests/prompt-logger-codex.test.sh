#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOGGER="$ROOT/flight/scripts/prompt-logger/codex.py"
DISPATCHER="$ROOT/flight/scripts/flight"
FIXTURES="$ROOT/scripts/tests/fixtures/prompt-logger"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

pass=0
fail=0

ok() {
	printf '  ✓ %s\n' "$1"
	pass=$((pass + 1))
}

not_ok() {
	printf '  ✗ %s\n' "$1"
	fail=$((fail + 1))
}

assert_jq() {
	label="$1"
	filter="$2"
	file="$3"
	if jq -e "$filter" "$file" >/dev/null; then
		ok "$label"
	else
		not_ok "$label"
	fi
}

invoke() {
	mode="$1"
	event="$2"
	repo="$3"
	state="$4"
	printf '%s' "$event" | env \
		FLIGHT_REPO_ROOT="$repo" \
		FLIGHT_PROMPT_LOG_STATE_DIR="$state" \
		FLIGHT_CODEX_AUTH_MODE=chatgpt \
		python3 "$LOGGER" "$mode"
}

make_repo() {
	repo="$1"
	enabled="$2"
	mkdir -p "$repo/.flightdirector"
	git -C "$repo" init -q
	printf '{"code":{"promptLog":{"enabled":%s}}}\n' "$enabled" >"$repo/.flightdirector/config.json"
}

repo="$TEST_TMP/main"
state="$TEST_TMP/state-main"
make_repo "$repo" true
prompt_event="$(jq -nc --arg cwd "$repo" '{session_id:"session-main",turn_id:"turn-main",prompt:"main prompt",model:"gpt-5.6-sol",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
stop_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-main.jsonl" '{session_id:"session-main",turn_id:"turn-main",model:"gpt-5.6-sol",cwd:$cwd,transcript_path:$path,hook_event_name:"Stop"}')"
invoke prompt "$prompt_event" "$repo" "$state"
invoke stop "$stop_event" "$repo" "$state" 2>"$TEST_TMP/main.err"
assert_jq "main row uses the frozen identity fields" '.harness == "codex" and .provider == "openai" and .session_id == "session-main" and .turn_id == "turn-main" and .prompt == "main prompt" and .model == "gpt-5.6-sol"' "$repo/prompt_log.jsonl"
assert_jq "main row maps current rollout usage" '.input_tokens == 1200 and .output_tokens == 90 and .reasoning_output_tokens == 30 and .cache_creation_tokens == 0 and .cache_read_tokens == 800' "$repo/prompt_log.jsonl"
assert_jq "bundled Codex pricing sets API-equivalent cost" '.cost_usd == 0.00372 and .cost_basis == "api-equivalent" and .duration_seconds == 2' "$repo/prompt_log.jsonl"
if [ ! -s "$TEST_TMP/main.err" ]; then ok "known Codex model pricing does not warn"; else not_ok "known Codex model pricing does not warn"; fi
if jq -e '
	.families["gpt-6-astra"] == {"input_per_million":10,"output_per_million":50,"cache_creation_per_million":12.5,"cache_read_per_million":1}
	and .families["gpt-5.6-sol"] == {"input_per_million":4,"output_per_million":20,"cache_creation_per_million":5,"cache_read_per_million":0.4}
	and .families["gpt-5.6-terra"] == {"input_per_million":2,"output_per_million":12,"cache_creation_per_million":2.5,"cache_read_per_million":0.2}
	and .families["gpt-5.6-luna"] == {"input_per_million":0.2,"output_per_million":1.2,"cache_creation_per_million":0.25,"cache_read_per_million":0.02}
' "$ROOT/flight/scripts/prompt-logger/pricing.json" >/dev/null; then
	ok "bundled Codex rates match official Standard short-context prices"
else
	not_ok "bundled Codex rates match official Standard short-context prices"
fi
invoke stop "$stop_event" "$repo" "$state" 2>/dev/null
if [ "$(wc -l <"$repo/prompt_log.jsonl")" -eq 1 ]; then ok "repeated stop delivery does not duplicate a turn"; else not_ok "repeated stop delivery does not duplicate a turn"; fi

repo="$TEST_TMP/priced"
state="$TEST_TMP/state-priced"
make_repo "$repo" true
printf '%s\n' '{"models":{"gpt-5.6-sol":{"input_per_million":10,"cached_input_per_million":2,"output_per_million":30}}}' >"$repo/.flightdirector/pricing.json"
prompt_event="$(jq -nc --arg cwd "$repo" '{session_id:"session-main",turn_id:"turn-main",prompt:"priced prompt",model:"gpt-5.6-sol",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
stop_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-main.jsonl" '{session_id:"session-main",turn_id:"turn-main",model:"gpt-5.6-sol",cwd:$cwd,transcript_path:$path,hook_event_name:"Stop"}')"
invoke prompt "$prompt_event" "$repo" "$state"
printf '%s' "$stop_event" | env \
	FLIGHT_REPO_ROOT="$repo" \
	FLIGHT_PROMPT_LOG_STATE_DIR="$state" \
	FLIGHT_CODEX_AUTH_MODE=chatgpt \
	CODEX_API_KEY=test-only \
	python3 "$LOGGER" stop 2>/dev/null
assert_jq "override pricing excludes reasoning from output cost" '.cost_usd == 0.0083 and .cost_basis == "actual-api"' "$repo/prompt_log.jsonl"

repo="$TEST_TMP/multi"
state="$TEST_TMP/state-multi"
make_repo "$repo" true
prompt_event="$(jq -nc --arg cwd "$repo" '{session_id:"session-multi",turn_id:"turn-multi",prompt:"multi prompt",model:"gpt-6-astra",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
stop_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-multi-request.jsonl" '{session_id:"session-multi",turn_id:"turn-multi",cwd:$cwd,transcript_path:$path,hook_event_name:"Stop"}')"
invoke prompt "$prompt_event" "$repo" "$state"
invoke stop "$stop_event" "$repo" "$state" 2>/dev/null
assert_jq "multi-request uses the latest cumulative matching turn record" '.input_tokens == 3500 and .output_tokens == 450 and .reasoning_output_tokens == 120 and .model == "gpt-6-astra"' "$repo/prompt_log.jsonl"

repo="$TEST_TMP/interrupted"
state="$TEST_TMP/state-interrupted"
make_repo "$repo" true
prompt_event="$(jq -nc --arg cwd "$repo" '{session_id:"session-interrupt",turn_id:"turn-interrupt",prompt:"interrupt me",model:"gpt-5.6-terra",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
interrupt_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-interrupted.jsonl" '{session_id:"session-interrupt",turn_id:"turn-interrupt",cwd:$cwd,transcript_path:$path,hook_event_name:"Interrupt"}')"
invoke prompt "$prompt_event" "$repo" "$state"
invoke interrupt "$interrupt_event" "$repo" "$state" 2>/dev/null
assert_jq "interrupt records partial matching usage" '.turn_id == "turn-interrupt" and .interrupted == true and .input_tokens == 700 and .output_tokens == 40 and .duration_seconds >= 0' "$repo/prompt_log.jsonl"

repo="$TEST_TMP/subagent"
state="$TEST_TMP/state-subagent"
make_repo "$repo" true
subagent_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-subagent.jsonl" '{session_id:"session-parent",turn_id:"turn-subagent",agent_id:"agent-one",agent_type:"worker",cwd:$cwd,agent_transcript_path:$path,hook_event_name:"SubagentStop"}')"
invoke subagent-stop "$subagent_event" "$repo" "$state" 2>/dev/null
assert_jq "subagent row keeps parent session and uses agent id/model" '.subagent == true and .session_id == "session-parent" and .turn_id == "agent-one" and .model == "gpt-5.6-luna" and .prompt == "delegated work"' "$repo/prompt_log.jsonl"
assert_jq "subagent row uses delegated cumulative usage" '.input_tokens == 1800 and .cache_read_tokens == 1400 and .output_tokens == 210 and .reasoning_output_tokens == 80' "$repo/prompt_log.jsonl"

repo="$TEST_TMP/missing-usage"
state="$TEST_TMP/state-missing"
make_repo "$repo" true
prompt_event="$(jq -nc --arg cwd "$repo" '{session_id:"session-missing",turn_id:"turn-missing",prompt:"missing usage",model:"gpt-5.6-sol",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
stop_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-main.jsonl" '{session_id:"session-missing",turn_id:"turn-missing",cwd:$cwd,transcript_path:$path,hook_event_name:"Stop"}')"
invoke prompt "$prompt_event" "$repo" "$state"
invoke stop "$stop_event" "$repo" "$state" 2>"$TEST_TMP/missing.err"
assert_jq "wrong-turn transcript never supplies another turn's usage" '.turn_id == "turn-missing" and .input_tokens == null and .output_tokens == null and .reasoning_output_tokens == null and .cache_creation_tokens == null and .cache_read_tokens == null and .cost_usd == null' "$repo/prompt_log.jsonl"
if grep -q 'turn-missing' "$TEST_TMP/missing.err"; then ok "missing exact turn writes a visible warning"; else not_ok "missing exact turn writes a visible warning"; fi

repo="$TEST_TMP/disabled"
state="$TEST_TMP/state-disabled"
make_repo "$repo" false
prompt_event="$(jq -nc --arg cwd "$repo" '{session_id:"session-disabled",turn_id:"turn-disabled",prompt:"disabled",model:"gpt-5.6-sol",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
printf '%s' "$prompt_event" | env LS_HARNESS=codex FLIGHT_PROMPT_LOG_STATE_DIR="$state" "$DISPATCHER" prompt-log prompt >"$TEST_TMP/disabled.out" 2>"$TEST_TMP/disabled.err"
if [ ! -e "$repo/prompt_log.jsonl" ] && [ ! -s "$TEST_TMP/disabled.out" ] && [ ! -s "$TEST_TMP/disabled.err" ]; then ok "config opt-out exits silently without writing"; else not_ok "config opt-out exits silently without writing"; fi

repo="$TEST_TMP/dispatcher"
state="$TEST_TMP/state-dispatcher"
make_repo "$repo" true
prompt_event="$(jq -nc --arg cwd "$repo" '{session_id:"session-main",turn_id:"turn-main",prompt:"dispatcher prompt",model:"gpt-5.6-sol",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
stop_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-main.jsonl" '{session_id:"session-main",turn_id:"turn-main",cwd:$cwd,transcript_path:$path,hook_event_name:"Stop"}')"
(
	cd "$repo"
	printf '%s' "$prompt_event" | env LS_HARNESS=codex FLIGHT_PROMPT_LOG_STATE_DIR="$state" FLIGHT_CODEX_AUTH_MODE=chatgpt "$DISPATCHER" prompt-log prompt
	printf '%s' "$stop_event" | env LS_HARNESS=codex FLIGHT_PROMPT_LOG_STATE_DIR="$state" FLIGHT_CODEX_AUTH_MODE=chatgpt "$DISPATCHER" prompt-log stop 2>/dev/null
)
assert_jq "dispatcher route invokes the Codex producer" '.prompt == "dispatcher prompt" and .harness == "codex"' "$repo/prompt_log.jsonl"

repo="$TEST_TMP/main-worktree"
linked="$TEST_TMP/linked-worktree"
state="$TEST_TMP/state-linked"
make_repo "$repo" true
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
git -C "$repo" worktree add -q -b fixture-linked "$linked"
prompt_event="$(jq -nc --arg cwd "$linked" '{session_id:"session-main",turn_id:"turn-main",prompt:"linked prompt",model:"gpt-5.6-sol",cwd:$cwd,hook_event_name:"UserPromptSubmit"}')"
stop_event="$(jq -nc --arg cwd "$linked" --arg path "$FIXTURES/codex-main.jsonl" '{session_id:"session-main",turn_id:"turn-main",cwd:$cwd,transcript_path:$path,hook_event_name:"Stop"}')"
(
	cd "$linked"
	printf '%s' "$prompt_event" | env LS_HARNESS=codex FLIGHT_PROMPT_LOG_STATE_DIR="$state" FLIGHT_CODEX_AUTH_MODE=chatgpt "$DISPATCHER" prompt-log prompt
	printf '%s' "$stop_event" | env LS_HARNESS=codex FLIGHT_PROMPT_LOG_STATE_DIR="$state" FLIGHT_CODEX_AUTH_MODE=chatgpt "$DISPATCHER" prompt-log stop 2>/dev/null
)
if [ -f "$repo/prompt_log.jsonl" ] && [ ! -e "$linked/prompt_log.jsonl" ]; then ok "linked worktree appends only at the main worktree"; else not_ok "linked worktree appends only at the main worktree"; fi

repo="$TEST_TMP/concurrent"
state="$TEST_TMP/state-concurrent"
make_repo "$repo" true
pids=()
for index in 1 2 3 4 5 6 7 8; do
	subagent_event="$(jq -nc --arg cwd "$repo" --arg path "$FIXTURES/codex-subagent.jsonl" --arg agent "agent-$index" '{session_id:"session-parent",turn_id:"turn-subagent",agent_id:$agent,agent_type:"worker",cwd:$cwd,agent_transcript_path:$path,hook_event_name:"SubagentStop"}')"
	invoke subagent-stop "$subagent_event" "$repo" "$state" >/dev/null 2>&1 &
	pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
if [ "$(wc -l <"$repo/prompt_log.jsonl")" -eq 8 ] && jq -e . "$repo/prompt_log.jsonl" >/dev/null; then ok "concurrent hook appends remain complete JSONL rows"; else not_ok "concurrent hook appends remain complete JSONL rows"; fi

if jq -e '.hooks == "./hooks/codex-hooks.json"' "$ROOT/flight/.codex-plugin/plugin.json" >/dev/null \
	&& jq -e '.hooks.UserPromptSubmit and .hooks.Stop and .hooks.Interrupt and .hooks.SubagentStop' "$ROOT/flight/hooks/codex-hooks.json" >/dev/null \
	&& grep -Fq "\$PLUGIN_ROOT/bin/flight" "$ROOT/flight/hooks/codex-hooks.json"; then
	ok "Codex manifest bundles all four plugin-root hooks"
else
	not_ok "Codex manifest bundles all four plugin-root hooks"
fi

printf '\nPassed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
