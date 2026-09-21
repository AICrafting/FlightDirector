# Claude Code dispatch

- Launch one background `Agent` per zone with `run_in_background: true` and the approved model.
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
