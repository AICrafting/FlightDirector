"""Shared, harness-neutral helpers for the Flight prompt ledger."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


REQUIRED_RECORD_FIELDS = {
	"timestamp",
	"provider",
	"harness",
	"session_id",
	"turn_id",
	"prompt",
	"model",
	"input_tokens",
	"output_tokens",
	"reasoning_output_tokens",
	"cache_creation_tokens",
	"cache_read_tokens",
	"cost_usd",
	"cost_basis",
	"duration_seconds",
}


def warn(message: str) -> None:
	print(f"flight prompt-log: warning — {message}", file=sys.stderr)


def main_worktree(cwd: str | None = None) -> Path:
	explicit = os.environ.get("FLIGHT_REPO_ROOT")
	if explicit:
		return Path(explicit).resolve()

	working_dir = cwd or os.getcwd()
	try:
		result = subprocess.run(
			["git", "rev-parse", "--git-common-dir"],
			cwd=working_dir,
			check=True,
			capture_output=True,
			text=True,
		)
	except (OSError, subprocess.CalledProcessError):
		return Path(working_dir).resolve()

	common_dir = Path(result.stdout.strip())
	if not common_dir.is_absolute():
		common_dir = Path(working_dir) / common_dir
	return common_dir.resolve().parent


def state_directory() -> Path:
	configured = os.environ.get("FLIGHT_PROMPT_LOG_STATE_DIR")
	path = Path(configured) if configured else Path(tempfile.gettempdir()) / "flight-prompt-logger"
	path.mkdir(mode=0o700, parents=True, exist_ok=True)
	return path


def stable_key(*parts: object) -> str:
	value = "\0".join(str(part or "") for part in parts)
	return hashlib.sha256(value.encode("utf-8")).hexdigest()


def state_path(session_id: str, turn_id: str) -> Path:
	return state_directory() / f"state-{stable_key(session_id, turn_id)}.json"


def write_json_atomic(path: Path, value: dict[str, Any]) -> None:
	path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
	fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
	try:
		with os.fdopen(fd, "w", encoding="utf-8") as handle:
			json.dump(value, handle, separators=(",", ":"), ensure_ascii=False)
			handle.write("\n")
			handle.flush()
			os.fsync(handle.fileno())
		os.chmod(temporary, 0o600)
		os.replace(temporary, path)
	finally:
		try:
			os.unlink(temporary)
		except FileNotFoundError:
			pass


def read_state(session_id: str, turn_id: str) -> dict[str, Any] | None:
	path = state_path(session_id, turn_id)
	try:
		with path.open(encoding="utf-8") as handle:
			value = json.load(handle)
	except (OSError, json.JSONDecodeError):
		return None
	return value if isinstance(value, dict) else None


def remove_state(session_id: str, turn_id: str) -> None:
	try:
		state_path(session_id, turn_id).unlink()
	except FileNotFoundError:
		pass


LEDGER_RELPATH = Path(".flightdirector") / "prompt-log.jsonl"


def ledger_path(repo_root: Path) -> Path:
	"""Where the ledger lives: <main worktree>/.flightdirector/prompt-log.jsonl.

	Namespaced under flight's own state directory so it can never collide with
	another tool's prompt log at the repo root.
	"""
	return repo_root / LEDGER_RELPATH


def append_record(repo_root: Path, record: dict[str, Any], record_key: str) -> bool:
	missing = REQUIRED_RECORD_FIELDS.difference(record)
	if missing:
		raise ValueError(f"record is missing required fields: {', '.join(sorted(missing))}")

	log_path = ledger_path(repo_root)
	log_path.parent.mkdir(parents=True, exist_ok=True)
	lock_path = state_directory() / f"ledger-{stable_key(log_path)}.lock"
	done_path = state_directory() / f"done-{stable_key(log_path, record_key)}"

	with lock_path.open("a", encoding="utf-8") as lock:
		fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
		if done_path.exists():
			return False
		with log_path.open("a", encoding="utf-8") as output:
			json.dump(record, output, separators=(",", ":"), ensure_ascii=False)
			output.write("\n")
			output.flush()
			os.fsync(output.fileno())
		write_json_atomic(done_path, {"record_key": record_key})
	return True


def _merged_pricing(repo_root: Path) -> dict[str, Any] | None:
	base_path = Path(__file__).with_name("pricing.json")
	override_path = repo_root / ".flightdirector" / "pricing.json"
	merged: dict[str, Any] = {}
	base_missing = not base_path.is_file()

	for path in (base_path, override_path):
		if not path.is_file():
			continue
		try:
			with path.open(encoding="utf-8") as handle:
				value = json.load(handle)
		except (OSError, json.JSONDecodeError) as error:
			warn(f"cannot read pricing file {path}: {error}")
			continue
		if not isinstance(value, dict):
			warn(f"pricing file {path} is not a JSON object")
			continue
		for section, entries in value.items():
			if isinstance(entries, dict) and isinstance(merged.get(section), dict):
				merged[section].update(entries)
			else:
				merged[section] = entries

	if base_missing:
		warn(f"shared pricing.json is missing at {base_path}; cost_usd will be null unless an override supplies this model")
	return merged or None


def _rate(entry: dict[str, Any], name: str) -> float | None:
	aliases = {
		"input": ("input_per_million", "input_usd_per_million"),
		"output": ("output_per_million", "output_usd_per_million"),
		"cache_read": ("cache_read_per_million", "cached_input_per_million", "cache_read_usd_per_million"),
		"cache_creation": ("cache_creation_per_million", "cache_write_per_million", "cache_creation_usd_per_million"),
	}
	for key in aliases[name]:
		value = entry.get(key)
		if isinstance(value, (int, float)) and not isinstance(value, bool):
			return float(value)
	return None


def price_usage(repo_root: Path, model: str | None, usage: dict[str, int] | None) -> float | None:
	if usage is None or not model:
		return None
	pricing = _merged_pricing(repo_root)
	if pricing is None:
		return None

	models = pricing.get("models", pricing)
	entry = models.get(model) if isinstance(models, dict) else None
	if not isinstance(entry, dict):
		families = pricing.get("families", {})
		if isinstance(families, dict):
			matches = [key for key in families if model == key or model.startswith(f"{key}-")]
			if matches:
				candidate = families[max(matches, key=len)]
				entry = candidate if isinstance(candidate, dict) else None
	if not isinstance(entry, dict):
		warn(f"no pricing entry for model {model}; cost_usd is null")
		return None

	input_rate = _rate(entry, "input")
	output_rate = _rate(entry, "output")
	if input_rate is None or output_rate is None:
		warn(f"pricing entry for model {model} lacks input/output per-million rates; cost_usd is null")
		return None

	input_tokens = usage["input_tokens"]
	cache_read = usage["cache_read_tokens"]
	cache_creation = usage["cache_creation_tokens"]
	uncached_input = max(input_tokens - cache_read - cache_creation, 0)
	cache_read_rate = _rate(entry, "cache_read")
	cache_creation_rate = _rate(entry, "cache_creation")
	if cache_read and cache_read_rate is None:
		warn(f"pricing entry for model {model} lacks a cache-read rate; cost_usd is null")
		return None
	if cache_creation and cache_creation_rate is None:
		warn(f"pricing entry for model {model} lacks a cache-creation rate; cost_usd is null")
		return None

	cost = uncached_input * input_rate
	cost += cache_read * (cache_read_rate or 0.0)
	cost += cache_creation * (cache_creation_rate or 0.0)
	cost += usage["output_tokens"] * output_rate
	return round(cost / 1_000_000, 12)
