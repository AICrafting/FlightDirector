# Claude Code dispatch

- Launch one background `Agent` per zone with `run_in_background: true` and the approved model.
- Create one task per issue with `TaskCreate`, plus a per-zone shipping task.
- Run `tail -f "$LOG"` in the background and attach `Monitor`; reflect changes with `TaskUpdate`.
- Route a user's answer to a blocked worker with `SendMessage`.
