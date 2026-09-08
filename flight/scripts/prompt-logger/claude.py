#!/usr/bin/env python3
"""Claude Code hook producer for Flight's shared prompt ledger (.flightdirector/prompt-log.jsonl).

Invoked by the plugin's bundled hooks (flight/hooks/hooks.json) through the
dispatcher: `LS_HARNESS=claude flight prompt-log <prompt|stop|interrupt|subagent-stop>`.
The dispatcher has already checked that the repo opted in (code.promptLog.enabled).

Claude Code hook payloads carry no turn_id and no model, so:
- `prompt` mints a turn_id (uuid4), records the prompt + start time, and stores it
  as the session's *active* turn (one active turn per session).
- `stop` / `interrupt` read that active turn, then sum every assistant message in
  the transcript that belongs to the turn (timestamp >= start, not a sidechain),
  de-duplicated by requestId — Claude Code writes one JSONL entry per content
  block, all sharing the request's usage, so naive summing would over-count.
- `subagent-stop` reads the subagent's own transcript and appends a `subagent: true`
  row keyed by agent_id, keeping the parent session_id.

Anthropic reports `input_tokens` as the *uncached* portion, separate from the cache
counters. The shared record format defines `input_tokens` as the *total* prompt
tokens (uncached + cache_read + cache_creation), matching OpenAI's convention and
what common.price_usage expects, so this producer sums them.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time
import uuid
from typing import Any

from common import append_record, main_worktree, price_usage, read_state, remove_state, stable_key, state_path, warn, write_json_atomic


SUPPORTED_MODES = {"prompt", "stop", "interrupt", "subagent-stop"}
ACTIVE = "active"	# state slot: the session's one in-flight turn


def read_event() -> dict[str, Any]:
	try:
		value = json.load(sys.stdin)
	except json.JSONDecodeError as error:
		raise ValueError(f"hook input is not valid JSON: {error}") from error
	if not isinstance(value, dict):
		raise ValueError("hook input must be a JSON object")
	return value


def require_string(event: dict[str, Any], field: str) -> str:
	value = event.get(field)
	if not isinstance(value, str) or not value:
		raise ValueError(f"hook input is missing {field}")
	return value


def auth_cost_basis() -> str | None:
	"""API-key / cloud-provider auth is billed per token (actual-api); a claude.ai
	login is normally a subscription, so its rows are API-equivalent estimates.
	FLIGHT_CLAUDE_AUTH_MODE=api|subscription overrides the guess."""
	mode = os.environ.get("FLIGHT_CLAUDE_AUTH_MODE")
	if mode in {"api", "api-key", "apikey"}:
		return "actual-api"
	if mode in {"subscription", "chatgpt", "claude-ai"}:
		return "api-equivalent"
	if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"):
		return "actual-api"
	for flag in ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"):
		if os.environ.get(flag) not in (None, "", "0", "false"):
			return "actual-api"
	return "api-equivalent"


def parse_timestamp(value: Any) -> float | None:
	if not isinstance(value, str) or not value:
		return None
	try:
		return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
	except ValueError:
		return None


def save_prompt(event: dict[str, Any]) -> None:
	session_id = require_string(event, "session_id")
	turn_id = str(uuid.uuid4())
	repo_root = main_worktree(event.get("cwd"))
	state = {
		"session_id": session_id,
		"turn_id": turn_id,
		"prompt": event.get("prompt"),
		"repo_root": str(repo_root),
		"started_at": time.time(),
	}
	write_json_atomic(state_path(session_id, ACTIVE), state)


def empty_usage() -> dict[str, int]:
	return {"input_tokens": 0, "output_tokens": 0, "reasoning_output_tokens": 0, "cache_creation_tokens": 0, "cache_read_tokens": 0}


def add_usage(total: dict[str, int], usage: dict[str, Any]) -> bool:
	"""Fold one Anthropic usage block into `total`. Returns False (and leaves
	`total` untouched) when the block lacks the required integer counters."""
	def count(key: str, default: int | None = None) -> int | None:
		value = usage.get(key, default)
		if isinstance(value, bool) or not isinstance(value, int) or value < 0:
			return None
		return value

	uncached = count("input_tokens")
	output = count("output_tokens")
	cache_creation = count("cache_creation_input_tokens", 0)
	cache_read = count("cache_read_input_tokens", 0)
	if None in (uncached, output, cache_creation, cache_read):
		return False
	details = usage.get("output_tokens_details")
	reasoning = 0
	if isinstance(details, dict):
		thinking = details.get("thinking_tokens", 0)
		if isinstance(thinking, int) and not isinstance(thinking, bool) and thinking >= 0:
			reasoning = thinking
	total["input_tokens"] += uncached + cache_creation + cache_read
	total["output_tokens"] += output
	total["reasoning_output_tokens"] += reasoning
	total["cache_creation_tokens"] += cache_creation
	total["cache_read_tokens"] += cache_read
	return True


def parse_transcript(path: str | None, since: float | None, sidechain: bool) -> dict[str, Any]:
	"""Sum the assistant usage of one turn.

	Main turn: entries with isSidechain false and timestamp >= `since`.
	Subagent transcript (`sidechain=True`): every assistant entry in the file.
	Usage is grouped by model so a turn that changed model is priced per model.
	Returns {"by_model": {model: usage}, "requests": n, "model": dominant} or
	by_model None when nothing usable was found.
	"""
	result: dict[str, Any] = {"by_model": None, "requests": 0, "model": None}
	if not path:
		warn("no transcript path in the hook payload; token and cost fields are null")
		return result

	by_model: dict[str, dict[str, int]] = {}
	seen_requests: set[str] = set()
	order: list[str] = []
	try:
		with Path(path).open(encoding="utf-8") as transcript:
			for line_number, line in enumerate(transcript, 1):
				line = line.strip()
				if not line:
					continue
				try:
					entry = json.loads(line)
				except json.JSONDecodeError:
					warn(f"ignored invalid JSON at {path}:{line_number}")
					continue
				if not isinstance(entry, dict) or entry.get("type") != "assistant":
					continue
				if bool(entry.get("isSidechain")) != sidechain:
					continue
				if since is not None:
					stamp = parse_timestamp(entry.get("timestamp"))
					if stamp is not None and stamp < since:
						continue
				message = entry.get("message")
				if not isinstance(message, dict):
					continue
				usage = message.get("usage")
				if not isinstance(usage, dict):
					continue
				request_id = entry.get("requestId")
				key = request_id if isinstance(request_id, str) and request_id else entry.get("uuid")
				if isinstance(key, str):
					if key in seen_requests:
						continue	# another content block of the same API request
					seen_requests.add(key)
				model = message.get("model")
				model = model if isinstance(model, str) and model else "unknown"
				bucket = by_model.setdefault(model, empty_usage())
				if not add_usage(bucket, usage):
					warn(f"assistant entry at {path}:{line_number} has an unusable usage block; skipped")
					continue
				result["requests"] += 1
				if model not in order:
					order.append(model)
	except OSError as error:
		warn(f"cannot read transcript {path}: {error}; token and cost fields are null")
		return result

	if result["requests"] == 0:
		warn(f"no assistant usage found in {path} for this turn; token and cost fields are null")
		return result
	result["by_model"] = by_model
	# Dominant model = most output tokens; ties resolve to the last model seen.
	result["model"] = max(reversed(order), key=lambda m: by_model[m]["output_tokens"])
	return result


def total_usage(by_model: dict[str, dict[str, int]]) -> dict[str, int]:
	total = empty_usage()
	for usage in by_model.values():
		for key in total:
			total[key] += usage[key]
	return total


def price_by_model(repo_root: Path, by_model: dict[str, dict[str, int]]) -> float | None:
	cost = 0.0
	for model, usage in by_model.items():
		part = price_usage(repo_root, model, usage)
		if part is None:
			return None
		cost += part
	return round(cost, 12)


def make_record(event: dict[str, Any], delegated: bool) -> tuple[Path, dict[str, Any], str] | None:
	session_id = require_string(event, "session_id")
	now = time.time()

	if delegated:
		agent_id = event.get("agent_id")
		agent_id = agent_id if isinstance(agent_id, str) and agent_id else "subagent"
		turn_id = agent_id
		transcript = event.get("agent_transcript_path") or event.get("transcript_path")
		parsed = parse_transcript(transcript if isinstance(transcript, str) else None, None, sidechain=True)
		repo_root = main_worktree(event.get("cwd"))
		prompt = f"[subagent {agent_id}]"
		agent_type = event.get("agent_type")
		if isinstance(agent_type, str) and agent_type:
			prompt = f"[subagent {agent_id} ({agent_type})]"
		duration = None
		state = None
	else:
		state = read_state(session_id, ACTIVE)
		if state is None:
			warn(f"no active turn recorded for session {session_id}; nothing to log")
			return None
		turn_id = str(state.get("turn_id") or uuid.uuid4())
		started = state.get("started_at")
		since = float(started) if isinstance(started, (int, float)) and not isinstance(started, bool) else None
		transcript = event.get("transcript_path")
		parsed = parse_transcript(transcript if isinstance(transcript, str) else None, since, sidechain=False)
		repo_root = Path(state["repo_root"]) if isinstance(state.get("repo_root"), str) else main_worktree(event.get("cwd"))
		prompt = state.get("prompt")
		if not isinstance(prompt, str):
			prompt = ""
			warn(f"prompt text is unavailable for turn {turn_id}")
		duration = max(now - since, 0.0) if since is not None else None

	by_model = parsed["by_model"]
	usage = total_usage(by_model) if by_model else None
	model = parsed["model"] or ""
	if not model:
		warn(f"model is unavailable for turn {turn_id}")
	cost = price_by_model(repo_root, by_model) if by_model else None

	record: dict[str, Any] = {
		"timestamp": datetime.now(timezone.utc).isoformat(),
		"provider": "anthropic",
		"harness": "claude",
		"session_id": session_id,
		"turn_id": turn_id,
		"prompt": prompt,
		"model": model,
		"input_tokens": usage["input_tokens"] if usage else None,
		"output_tokens": usage["output_tokens"] if usage else None,
		"reasoning_output_tokens": usage["reasoning_output_tokens"] if usage else None,
		"cache_creation_tokens": usage["cache_creation_tokens"] if usage else None,
		"cache_read_tokens": usage["cache_read_tokens"] if usage else None,
		"cost_usd": cost,
		"cost_basis": auth_cost_basis() if cost is not None else None,
		"duration_seconds": round(duration, 3) if duration is not None else None,
	}
	if by_model and len(by_model) > 1:
		record["models"] = {m: u["output_tokens"] for m, u in by_model.items()}
	if delegated:
		record["subagent"] = True
	if not delegated and event.get("hook_event_name") == "Interrupt":
		record["interrupted"] = True
	record_key = stable_key("claude", session_id, turn_id, "subagent" if delegated else "main")
	return repo_root, record, record_key


def finish(event: dict[str, Any], delegated: bool) -> None:
	made = make_record(event, delegated)
	if made is None:
		return
	repo_root, record, record_key = made
	append_record(repo_root, record, record_key)
	if not delegated:
		remove_state(record["session_id"], ACTIVE)


def main() -> int:
	if len(sys.argv) != 2 or sys.argv[1] not in SUPPORTED_MODES:
		print("usage: claude.py <prompt|stop|interrupt|subagent-stop>", file=sys.stderr)
		return 2
	try:
		event = read_event()
		mode = sys.argv[1]
		if mode == "prompt":
			save_prompt(event)
		else:
			if mode == "interrupt":
				event.setdefault("hook_event_name", "Interrupt")
			finish(event, delegated=mode == "subagent-stop")
	except (OSError, ValueError) as error:
		warn(str(error))
		return 1
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
