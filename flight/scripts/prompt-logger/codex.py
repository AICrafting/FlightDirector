#!/usr/bin/env python3
"""Codex hook producer for Flight's shared prompt_log.jsonl ledger."""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time
from typing import Any

from common import (
	append_record,
	main_worktree,
	price_usage,
	read_state,
	remove_state,
	stable_key,
	state_path,
	warn,
	write_json_atomic,
)


SUPPORTED_MODES = {"prompt", "stop", "interrupt", "subagent-stop"}


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
	if os.environ.get("CODEX_API_KEY") or os.environ.get("OPENAI_API_KEY"):
		return "actual-api"
	auth_mode = os.environ.get("FLIGHT_CODEX_AUTH_MODE")
	if not auth_mode:
		codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
		try:
			with (codex_home / "auth.json").open(encoding="utf-8") as handle:
				auth = json.load(handle)
			if isinstance(auth, dict):
				auth_mode = auth.get("auth_mode")
		except (OSError, json.JSONDecodeError):
			pass
	if auth_mode == "chatgpt":
		return "api-equivalent"
	if auth_mode in {"api", "api-key", "apikey"}:
		return "actual-api"
	warn("cannot determine Codex authentication type; cost_basis is null")
	return None


def save_prompt(event: dict[str, Any]) -> None:
	session_id = require_string(event, "session_id")
	turn_id = require_string(event, "turn_id")
	repo_root = main_worktree(event.get("cwd"))
	state = {
		"session_id": session_id,
		"turn_id": turn_id,
		"prompt": event.get("prompt"),
		"model": event.get("model"),
		"repo_root": str(repo_root),
		"started_at": time.time(),
	}
	write_json_atomic(state_path(session_id, turn_id), state)


def prompt_text(payload: dict[str, Any]) -> str | None:
	content = payload.get("content")
	if isinstance(content, str):
		return content
	if not isinstance(content, list):
		return None
	parts: list[str] = []
	for item in content:
		if isinstance(item, dict) and item.get("type") in {"input_text", "text"} and isinstance(item.get("text"), str):
			parts.append(item["text"])
	return "\n".join(parts) if parts else None


def parse_transcript(path: str | None, turn_id: str) -> dict[str, Any]:
	result: dict[str, Any] = {"model": None, "usage": None, "duration_seconds": None, "prompt": None}
	if not path:
		warn(f"no transcript path for turn {turn_id}; token and cost fields are null")
		return result

	active_turn: str | None = None
	try:
		with Path(path).open(encoding="utf-8") as transcript:
			for line_number, line in enumerate(transcript, 1):
				try:
					event = json.loads(line)
				except json.JSONDecodeError:
					warn(f"ignored invalid JSON at {path}:{line_number}")
					continue
				if not isinstance(event, dict):
					continue
				kind = event.get("type")
				payload = event.get("payload")
				if not isinstance(payload, dict):
					continue
				if kind == "event_msg" and payload.get("type") == "task_started":
					active_turn = payload.get("turn_id") if isinstance(payload.get("turn_id"), str) else None
				if kind == "turn_context" and payload.get("turn_id") == turn_id and isinstance(payload.get("model"), str):
					result["model"] = payload["model"]
				if kind == "token_usage_record" and payload.get("turn_id") == turn_id:
					usage = payload.get("turn_token_usage")
					if isinstance(usage, dict):
						result["usage"] = normalize_usage(usage)
				if kind == "event_msg" and payload.get("type") == "task_complete" and payload.get("turn_id") == turn_id:
					duration = payload.get("duration_ms")
					if isinstance(duration, (int, float)) and not isinstance(duration, bool):
						result["duration_seconds"] = max(float(duration) / 1000, 0.0)
				if kind == "response_item" and active_turn == turn_id and payload.get("type") == "message" and payload.get("role") == "user" and result["prompt"] is None:
					result["prompt"] = prompt_text(payload)
	except OSError as error:
		warn(f"cannot read transcript {path} for turn {turn_id}: {error}; token and cost fields are null")
		return result

	if result["usage"] is None:
		warn(f"no token_usage_record with exact turn_id {turn_id} in {path}; token and cost fields are null")
	return result


def normalize_usage(value: dict[str, Any]) -> dict[str, int] | None:
	mapping = {
		"input_tokens": "input_tokens",
		"output_tokens": "output_tokens",
		"reasoning_output_tokens": "reasoning_output_tokens",
		"cache_creation_tokens": "cache_write_input_tokens",
		"cache_read_tokens": "cached_input_tokens",
	}
	result: dict[str, int] = {}
	for target, source in mapping.items():
		tokens = value.get(source)
		if not isinstance(tokens, int) or isinstance(tokens, bool) or tokens < 0:
			return None
		result[target] = tokens
	return result


def make_record(event: dict[str, Any], delegated: bool, interrupted: bool) -> tuple[Path, dict[str, Any], str]:
	session_id = require_string(event, "session_id")
	transcript_turn_id = require_string(event, "turn_id")
	record_turn_id = require_string(event, "agent_id") if delegated else transcript_turn_id
	state = None if delegated else read_state(session_id, transcript_turn_id)
	transcript_field = "agent_transcript_path" if delegated else "transcript_path"
	parsed = parse_transcript(event.get(transcript_field), transcript_turn_id)

	repo_root = main_worktree(event.get("cwd"))
	if state and isinstance(state.get("repo_root"), str):
		repo_root = Path(state["repo_root"])
	model = parsed["model"] or (state or {}).get("model") or event.get("model")
	prompt = parsed["prompt"] if delegated else (state or {}).get("prompt")
	if not isinstance(prompt, str):
		prompt = parsed["prompt"] or ""
		warn(f"prompt text is unavailable for turn {transcript_turn_id}")
	if not isinstance(model, str) or not model:
		model = ""
		warn(f"model is unavailable for turn {transcript_turn_id}")

	duration = parsed["duration_seconds"]
	if duration is None and state and isinstance(state.get("started_at"), (int, float)):
		duration = max(time.time() - float(state["started_at"]), 0.0)
	usage = parsed["usage"]
	cost = price_usage(repo_root, model, usage)
	record: dict[str, Any] = {
		"timestamp": datetime.now(timezone.utc).isoformat(),
		"provider": "openai",
		"harness": "codex",
		"session_id": session_id,
		"turn_id": record_turn_id,
		"prompt": prompt,
		"model": model,
		"input_tokens": usage["input_tokens"] if usage else None,
		"output_tokens": usage["output_tokens"] if usage else None,
		"reasoning_output_tokens": usage["reasoning_output_tokens"] if usage else None,
		"cache_creation_tokens": usage["cache_creation_tokens"] if usage else None,
		"cache_read_tokens": usage["cache_read_tokens"] if usage else None,
		"cost_usd": cost,
		"cost_basis": auth_cost_basis(),
		"duration_seconds": duration,
	}
	if delegated:
		record["subagent"] = True
	if interrupted:
		record["interrupted"] = True
	record_key = stable_key("codex", session_id, record_turn_id)
	return repo_root, record, record_key


def finish(event: dict[str, Any], delegated: bool = False, interrupted: bool = False) -> None:
	repo_root, record, record_key = make_record(event, delegated, interrupted)
	append_record(repo_root, record, record_key)
	if not delegated:
		remove_state(record["session_id"], record["turn_id"])


def main() -> int:
	if len(sys.argv) != 2 or sys.argv[1] not in SUPPORTED_MODES:
		print("usage: codex.py <prompt|stop|interrupt|subagent-stop>", file=sys.stderr)
		return 2
	try:
		event = read_event()
		mode = sys.argv[1]
		if mode == "prompt":
			save_prompt(event)
		else:
			finish(event, delegated=mode == "subagent-stop", interrupted=mode == "interrupt")
	except (OSError, ValueError) as error:
		warn(str(error))
		return 1
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
