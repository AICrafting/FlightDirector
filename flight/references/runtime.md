# Runtime preflight

Every Flight skill performs this cheap preflight before its first dispatcher call:

1. Resolve the absolute plugin root from the loaded `SKILL.md` location, then set
   `DISP=<plugin-root>/scripts/flight` and `BATCH_MANIFEST=<plugin-root>/scripts/batch-manifest`.
   Do not assume the host added the plugin's `bin/` directory to `PATH`. A bare
   `flight` remains acceptable when `command -v flight` succeeds.
2. Set `HARNESS` to `codex` when running in Codex, or `claude` when running in Claude Code.
3. Run `"$DISP" reconcile --harness "$HARNESS"`. This is an idempotent local comparison on
   normal runs; it updates compatibility metadata only when the installed plugin version changed.
4. Know your own model id (e.g. `claude-fable-5-1`, `gpt-5.6-sol`) and pass it as
   `--model <id>` on every body-writing verb — `issues create|update|comment`, `pr open|update`.
   The dispatcher signs each body it writes (`---` then `via FlightDirector:flight@<version> with
   <Model/ver>`); it cannot discover the model itself, so without `--model` the signature simply
   omits the "with …" clause. `FLIGHT_MODEL=<id>` in the environment is the equivalent for a
   shell that persists it. See [adapter-contract.md](adapter-contract.md) → **Body signature**.

Examples in the skill documentation use `flight` for readability. Execute them through
`"$DISP"`. Likewise, execute `batch-manifest` through `"$BATCH_MANIFEST"`.

Reconciliation is for config/schema compatibility. Model labels are runtime provenance and are
created lazily during ledger finalization; they do not depend on a plugin release.
