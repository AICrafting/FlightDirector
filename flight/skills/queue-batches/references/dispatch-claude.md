# Claude Code dispatch

- Launch one background `Agent` per zone with `run_in_background: true` and the approved model.
- Create one task per issue with `TaskCreate`, plus a per-zone shipping task.
- Run `tail -f "$LOG"` in the background and attach `Monitor`; reflect changes with `TaskUpdate`.
- Route a user's answer to a blocked worker with `SendMessage`.
- **Why a worker returns without a terminal line.** A command a worker backgrounds inside its
  `Agent` (`run_in_background`, or a trailing `&`) dies with the worker's shell the moment the
  worker returns. The worker comes back believing the job is still running and reports "still
  waiting on X, I'll report when it finishes" — nothing is running and it will wait forever. Its
  report is wrong by construction, which is why SKILL.md Section 4 checks the zone log's last
  line instead.
