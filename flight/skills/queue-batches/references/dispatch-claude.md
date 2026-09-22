# Claude Code dispatch

- Launch one background `Agent` per zone with `run_in_background: true` and the approved model.
- The `Agent` model parameter takes the aliases `opus`, `sonnet`, `haiku` (and full `claude-*`
  ids). If the launch errors on the model itself — unknown model, no access on this plan — that
  is the SKILL.md Section 3 fall-through: relaunch with the next `$MODELS` entry. `flight config
  worker-model` has already dropped Codex models, so they never reach this call.
- Create one task per issue with `TaskCreate`, plus a per-zone shipping task.
- Run `tail -f "$LOG"` in the background and attach `Monitor`; reflect changes with `TaskUpdate`.
- Route a user's answer to a blocked worker with `SendMessage`.
- Run the Section 4a gate sweep as **one** backgrounded `Bash` (`run_in_background: true`) at a
  time **across all zones** — not one per zone. Zones land within minutes of each other, so a
  per-zone launch puts N suites in flight at once, which is the contention 4a exists to remove.
  If a sweep is already running when another zone lands, queue that zone and start it when the
  first exits; 4a's lock makes that enforceable rather than remembered. `Monitor` on the zone logs
  picks up each `preflight-pass` / `preflight-fail` / `preflight-skip` line; reflect `fail` and
  `skip` with `TaskUpdate` (neither is shippable). Never hand the sweep to the zone `Agent` — it
  has already returned.
- **Why a worker returns without a terminal line.** A command a worker backgrounds inside its
  `Agent` (`run_in_background`, or a trailing `&`) dies with the worker's shell the moment the
  worker returns. The worker comes back believing the job is still running and reports "still
  waiting on X, I'll report when it finishes" — nothing is running and it will wait forever. Its
  report is wrong by construction, which is why SKILL.md Section 4 checks the zone's `ticket=all`
  line instead. It is also why the sweep above runs from the orchestrator: the same mechanism that
  makes a worker's backgrounded job vanish would make a worker-run gate report nothing.
