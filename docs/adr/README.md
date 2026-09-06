# Architecture Decision Records

Each ADR captures one significant architectural decision — the context, the choice, and its
consequences — so the reasoning survives the decision. Format follows Michael Nygard's
template. Files are numbered sequentially and never rewritten once Accepted; a later decision
that changes course gets a new ADR that supersedes the earlier one.

> **Naming note.** ADRs and the plans/specs under `docs/superpowers/` are historical records and
> refer to the plugin by its original name, `lightspeed`. It was renamed `flight` (Flight Director
> family) in #67; read `lightspeed` as `flight` and `.lightspeed/` as `.flightdirector/`.

| #    | Title                                          | Status   |
|------|------------------------------------------------|----------|
| [0001](0001-curl-over-mcp-and-adapter-architecture.md) | curl over MCP, and a per-axis adapter architecture | Accepted |
