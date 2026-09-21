# Claude Code dispatch

- Launch one background `Agent` per zone with `run_in_background: true` and the approved model.
- Create one task per issue with `TaskCreate`, plus a per-zone shipping task.
- Run `tail -f "$LOG"` in the background and attach `Monitor`; reflect changes with `TaskUpdate`.
- Route a user's answer to a blocked worker with `SendMessage`.
- Run the Section 4a gate sweep as **one** backgrounded `Bash` (`run_in_background: true`) per
  zone, running that zone's loop start to finish; `Monitor` on the zone log picks up each
  `preflight-pass`/`preflight-fail` line. Never hand the sweep to the zone `Agent` — it has
  already returned.
