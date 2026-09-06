# Runtime preflight

Every Flight skill performs this cheap preflight before its first dispatcher call:

1. Resolve the absolute plugin root from the loaded `SKILL.md` location, then set
   `DISP=<plugin-root>/scripts/flight` and `BATCH_MANIFEST=<plugin-root>/scripts/batch-manifest`.
   Do not assume the host added the plugin's `bin/` directory to `PATH`. A bare
   `flight` remains acceptable when `command -v flight` succeeds.
2. Set `HARNESS` to `codex` when running in Codex, or `claude` when running in Claude Code.
3. Run `"$DISP" reconcile --harness "$HARNESS"`. This is an idempotent local comparison on
   normal runs; it updates compatibility metadata only when the installed plugin version changed.

Examples in the skill documentation use `flight` for readability. Execute them through
`"$DISP"`. Likewise, execute `batch-manifest` through `"$BATCH_MANIFEST"`.

Reconciliation is for config/schema compatibility. Model labels are runtime provenance and are
created lazily during ledger finalization; they do not depend on a plugin release.
