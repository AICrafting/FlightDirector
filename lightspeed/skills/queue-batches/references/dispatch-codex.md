# Codex dispatch

- Require Codex multi-agent support; if unavailable, explain that ordinary Lightspeed workflows
  still work and offer to process the queue sequentially.
- Spawn one subagent per zone with an explicit task name, approved model, and reasoning effort.
  Give it the rendered agent prompt and run zones concurrently within the available slot limit.
- Track agent ids by zone. Use agent mailbox updates and the status logs to render progress; do
  not busy-poll. When otherwise idle, wait in bounded five-to-ten-minute stretches.
- Route a user's answer to a blocked worker by sending or following up with that zone's agent.
- Codex has no required task-board equivalent; the status-log board is the source of truth.
