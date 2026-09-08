#!/usr/bin/env python3
"""Summarise the prompt ledger (.flightdirector/prompt-log.jsonl) for a work-ledger entry.

	flight prompt-log summary --session <id> [--session <id> …] [--since <ISO-8601>] [--json]

Reads the main worktree's .flightdirector/prompt-log.jsonl (any harness, any provider), keeps
the rows for the given session id(s) (and, with --since, at or after that
timestamp), and prints a Markdown block the ledger comment can paste as-is:
totals per provider/model, rows with null usage counted separately so an
"estimate" is only claimed when there truly is no data, and the cost basis.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import sys
from typing import Any

from common import ledger_path, main_worktree, warn


def parse_args(argv: list[str]) -> argparse.Namespace:
	parser = argparse.ArgumentParser(prog="flight prompt-log summary", add_help=True)
	parser.add_argument("--session", action="append", default=[], help="session_id to include (repeatable)")
	parser.add_argument("--since", help="ISO-8601 timestamp; keep rows at or after it")
	parser.add_argument("--json", action="store_true", help="emit the aggregate as JSON instead of Markdown")
	parser.add_argument("--log", help="path to the ledger (default: <main worktree>/.flightdirector/prompt-log.jsonl)")
	return parser.parse_args(argv)


def parse_ts(value: Any) -> datetime | None:
	if not isinstance(value, str) or not value:
		return None
	try:
		return datetime.fromisoformat(value.replace("Z", "+00:00"))
	except ValueError:
		return None


def load_rows(path: Path) -> list[dict[str, Any]]:
	rows: list[dict[str, Any]] = []
	try:
		with path.open(encoding="utf-8") as handle:
			for number, line in enumerate(handle, 1):
				line = line.strip()
				if not line:
					continue
				try:
					row = json.loads(line)
				except json.JSONDecodeError:
					warn(f"ignored invalid JSON at {path}:{number}")
					continue
				if isinstance(row, dict):
					rows.append(row)
	except OSError as error:
		warn(f"cannot read {path}: {error}")
	return rows


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
	groups: dict[tuple[str, str, str], dict[str, Any]] = {}
	unmeasured = 0
	bases: set[str] = set()
	subagent_rows = 0
	for row in rows:
		harness = str(row.get("harness") or "claude")	# legacy rows predate the field
		provider = str(row.get("provider") or ("anthropic" if harness == "claude" else "unknown"))
		model = str(row.get("model") or "unknown")
		key = (harness, provider, model)
		group = groups.setdefault(key, {
			"harness": harness, "provider": provider, "model": model,
			"rows": 0, "input_tokens": 0, "output_tokens": 0, "reasoning_output_tokens": 0,
			"cache_creation_tokens": 0, "cache_read_tokens": 0, "cost_usd": 0.0, "unpriced_rows": 0,
		})
		group["rows"] += 1
		if row.get("subagent"):
			subagent_rows += 1
		if row.get("input_tokens") is None and row.get("output_tokens") is None:
			unmeasured += 1
			continue
		for field in ("input_tokens", "output_tokens", "reasoning_output_tokens", "cache_creation_tokens", "cache_read_tokens"):
			value = row.get(field)
			if isinstance(value, (int, float)) and not isinstance(value, bool):
				group[field] += int(value)
		cost = row.get("cost_usd")
		if isinstance(cost, (int, float)) and not isinstance(cost, bool):
			group["cost_usd"] += float(cost)
			basis = row.get("cost_basis")
			if isinstance(basis, str):
				bases.add(basis)
		else:
			group["unpriced_rows"] += 1
	total_cost = sum(g["cost_usd"] for g in groups.values())
	# Models that had measured usage but no price: the one thing the user can fix
	# (add the model to .flightdirector/pricing.json), so name them explicitly.
	unpriced_models = [
		{"model": g["model"], "provider": g["provider"], "harness": g["harness"], "rows": g["unpriced_rows"]}
		for g in groups.values() if g["unpriced_rows"]
	]
	return {
		"rows": len(rows),
		"unmeasured_rows": unmeasured,
		"subagent_rows": subagent_rows,
		"cost_usd": round(total_cost, 6),
		"cost_basis": sorted(bases),
		"unpriced_models": sorted(unpriced_models, key=lambda m: (-m["rows"], m["model"])),
		"groups": sorted(groups.values(), key=lambda g: (-g["cost_usd"], -g["output_tokens"])),
	}


def fmt_tokens(value: int) -> str:
	if value >= 1_000_000:
		return f"{value / 1_000_000:.2f}M"
	if value >= 1_000:
		return f"{value / 1_000:.1f}k"
	return str(value)


def render_markdown(summary: dict[str, Any], sessions: list[str]) -> str:
	lines: list[str] = []
	if summary["rows"] == 0:
		lines.append(f"**Cost / tokens:** no `prompt-log.jsonl` rows for session(s) {', '.join(f'`{s[:8]}`' for s in sessions) or '(none given)'} — estimate only.")
		return "\n".join(lines)
	basis = summary["cost_basis"]
	basis_note = {
		("actual-api",): "actual API billing",
		("api-equivalent",): "API-equivalent estimate (subscription auth)",
	}.get(tuple(basis), "mixed cost bases: " + ", ".join(basis) if basis else "cost basis unknown")
	lines.append(f"**Cost / tokens** (from `prompt-log.jsonl`, session(s) {', '.join(f'`{s[:8]}`' for s in sessions)}; {basis_note})")
	lines.append("")
	lines.append("| Harness | Model | Turns | Input | Output | Cache write | Cache read | Cost (USD) |")
	lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
	for g in summary["groups"]:
		cost = f"{g['cost_usd']:.4f}" if g["unpriced_rows"] == 0 else f"{g['cost_usd']:.4f} (+{g['unpriced_rows']} unpriced)"
		lines.append(f"| {g['harness']} | {g['model']} | {g['rows']} | {fmt_tokens(g['input_tokens'])} | {fmt_tokens(g['output_tokens'])} | {fmt_tokens(g['cache_creation_tokens'])} | {fmt_tokens(g['cache_read_tokens'])} | {cost} |")
	lines.append(f"| **Total** | | {summary['rows']} | | | | | **{summary['cost_usd']:.4f}** |")
	notes: list[str] = []
	if summary["subagent_rows"]:
		notes.append(f"{summary['subagent_rows']} subagent row(s) included")
	if summary["unmeasured_rows"]:
		notes.append(f"{summary['unmeasured_rows']} row(s) had no usage (hook could not read the transcript) — totals are a lower bound")
	if notes:
		lines.append("")
		lines.append("_" + "; ".join(notes) + "._")
	if summary["unpriced_models"]:
		named = ", ".join(f"**{m['model']}** ({m['provider']}, {m['rows']} row{'s' if m['rows'] != 1 else ''})" for m in summary["unpriced_models"])
		lines.append("")
		lines.append(
			f"_No pricing for {named} — tokens were recorded but excluded from the cost total. "
			f"Add the model under `families` or `models` in `.flightdirector/pricing.json` "
			f"(merged over the bundled `flight/scripts/prompt-logger/pricing.json`) and rerun the summary._"
		)
	return "\n".join(lines)


def main(argv: list[str]) -> int:
	args = parse_args(argv)
	log_path = Path(args.log) if args.log else ledger_path(main_worktree())
	rows = load_rows(log_path) if log_path.is_file() else []
	if not log_path.is_file():
		warn(f"no prompt log at {log_path}")
	since = parse_ts(args.since) if args.since else None
	if args.since and since is None:
		warn(f"ignoring unparsable --since {args.since!r}")
	wanted = set(args.session)
	selected: list[dict[str, Any]] = []
	for row in rows:
		if wanted and row.get("session_id") not in wanted:
			continue
		if since is not None:
			stamp = parse_ts(row.get("timestamp"))
			if stamp is not None and stamp.tzinfo is not None and since.tzinfo is not None and stamp < since:
				continue
		selected.append(row)
	summary = aggregate(selected)
	summary["sessions"] = sorted(wanted)
	if args.json:
		print(json.dumps(summary, indent=2))
	else:
		print(render_markdown(summary, sorted(wanted)))
	return 0


if __name__ == "__main__":
	raise SystemExit(main(sys.argv[1:]))
