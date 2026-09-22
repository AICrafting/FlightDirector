# Codex dispatch

- Require Codex multi-agent support; if unavailable, explain that ordinary Flight workflows
  still work and offer to process the queue sequentially.
- Spawn one subagent per zone with an explicit task name, approved model, and reasoning effort.
  Give it the rendered agent prompt and run zones concurrently within the available slot limit.
- Codex dispatches OpenAI models only; `flight config worker-model` has already dropped Claude
  entries (`opus`, `sonnet`, `claude-*`) from the list. If spawning fails on the model itself —
  not offered, not on this plan, unknown — that is the SKILL.md Section 3 fall-through: spawn
  again with the next `$MODELS` entry.
- Track agent ids by zone. Use agent mailbox updates and the status logs to render progress; do
  not busy-poll. When otherwise idle, wait in bounded five-to-ten-minute stretches.
- Route a user's answer to a blocked worker by sending or following up with that zone's agent.
- Codex has no required task-board equivalent; the status-log board is the source of truth.
- Run the Section 4a preflight sweep from the orchestrator session, one worktree at a time, and
  read the verdict off the zone log rather than busy-polling the command. A returned subagent
  cannot run it: its shell is gone.
