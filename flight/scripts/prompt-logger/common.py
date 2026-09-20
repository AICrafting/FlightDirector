"""Shared, harness-neutral helpers for the Flight prompt ledger."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import Any

# `fcntl` is Unix-only. On Windows the equivalent is msvcrt's byte-range lock, so
# pick whichever exists here and hide the difference in _lock_exclusive below.
try:
	import fcntl
except ModuleNotFoundError:  # Windows
	fcntl = None  # type: ignore[assignment]
	import msvcrt


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
		_lock_exclusive(lock)
		if done_path.exists():
			return False
		_write_row(log_path, record)
		write_json_atomic(done_path, {"record_key": record_key})
	return True


USAGE_FIELDS = ("input_tokens", "output_tokens", "reasoning_output_tokens", "cache_creation_tokens", "cache_read_tokens")


def append_increment(repo_root: Path, record: dict[str, Any]) -> bool:
	"""Append what `record` adds to the rows already logged for its agent.

	`record` carries a subagent's CUMULATIVE usage, and a subagent stops more than once:
	when it parks on background work, again after each wake-up, and once more after
	handing its report back. Every stop re-reads the whole transcript, so each row holds
	only the usage beyond the agent's earlier rows — the rows of one agent always sum to
	its transcript, however many stops there were, and a reader that simply adds rows
	stays right. The earlier rows are read back from the ledger itself (under the lock),
	so there is no side state to lose. A stop that adds nothing writes no row.
	"""
	missing = REQUIRED_RECORD_FIELDS.difference(record)
	if missing:
		raise ValueError(f"record is missing required fields: {', '.join(sorted(missing))}")

	log_path = ledger_path(repo_root)
	log_path.parent.mkdir(parents=True, exist_ok=True)
	lock_path = state_directory() / f"ledger-{stable_key(log_path)}.lock"

	with lock_path.open("a", encoding="utf-8") as lock:
		_lock_exclusive(lock)
		earlier = _agent_rows(log_path, record)
		if record.get("input_tokens") is None and record.get("output_tokens") is None:
			if earlier:
				return False	# already on the ledger; one unmeasured row says all there is to say
			_write_row(log_path, record)
			return True
		measured = [row for row in earlier if row.get("input_tokens") is not None or row.get("output_tokens") is not None]
		grew = False
		for field in USAGE_FIELDS:
			value = record.get(field)
			if not _is_number(value):
				continue
			record[field] = max(value - sum(row[field] for row in measured if _is_number(row.get(field))), 0)
			grew = grew or record[field] > 0
		if not grew:
			return False
		if _is_number(record.get("cost_usd")):
			logged = sum(row["cost_usd"] for row in measured if _is_number(row.get("cost_usd")))
			record["cost_usd"] = max(round(record["cost_usd"] - logged, 12), 0.0)
		if measured:
			record["part"] = len(measured) + 1
		_write_row(log_path, record)
	return True


def _is_number(value: Any) -> bool:
	return isinstance(value, (int, float)) and not isinstance(value, bool)


def _agent_rows(log_path: Path, record: dict[str, Any]) -> list[dict[str, Any]]:
	"""The subagent rows already logged for this record's harness, session and agent."""
	rows: list[dict[str, Any]] = []
	turn_id = record["turn_id"]
	try:
		with log_path.open(encoding="utf-8") as ledger:
			for line in ledger:
				if turn_id not in line:
					continue
				try:
					row = json.loads(line)
				except json.JSONDecodeError:
					continue
				if (
					isinstance(row, dict) and row.get("subagent") and row.get("turn_id") == turn_id
					and row.get("session_id") == record["session_id"] and row.get("harness") == record["harness"]
				):
					rows.append(row)
	except FileNotFoundError:
		pass
	return rows


def _write_row(log_path: Path, record: dict[str, Any]) -> None:
	with log_path.open("a", encoding="utf-8") as output:
		json.dump(record, output, separators=(",", ":"), ensure_ascii=False)
		output.write("\n")
		output.flush()
		os.fsync(output.fileno())


def _lock_exclusive(handle, timeout: float = 60.0) -> None:
	"""Block until this process holds an exclusive lock on `handle`.

	The ledger is appended to by concurrent hook invocations, so this has to be a
	real lock rather than a best effort. `fcntl.flock` waits indefinitely; msvcrt
	has no whole-file flock, only a byte-range lock that gives up after about ten
	seconds, so it is retried rather than allowed to surface as a lost row.
	"""
	if fcntl is not None:
		fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
		return

	# Windows: lock one byte at a fixed offset so every writer contends for the
	# same region. Locking past EOF is allowed, so the lock file can stay empty.
	handle.seek(0)
	deadline = time.monotonic() + timeout
	while True:
		try:
			msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
			return
		except OSError:
			if time.monotonic() >= deadline:
				raise
			time.sleep(0.05)


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
