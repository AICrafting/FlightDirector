# Runtime preflight

Every Flight skill performs this cheap preflight before its first dispatcher call:

1. Resolve the absolute plugin root from the loaded `SKILL.md` location, then set
   `DISP=<plugin-root>/scripts/flight`, `BATCH_MANIFEST=<plugin-root>/scripts/batch-manifest` and
   `ISSUE_IDENTITY=<plugin-root>/scripts/issue-identity.sh` (the retained issue-identity helper:
   branch → `{tracker, number, qualified, branchPrefix}`; see its header).
   Do not assume the host added the plugin's `bin/` directory to `PATH`. A bare
   `flight` remains acceptable when `command -v flight` succeeds.
2. Set `HARNESS` to `codex` when running in Codex, or `claude` when running in Claude Code.
3. Run `"$DISP" reconcile --harness "$HARNESS"`. This is an idempotent local comparison on
   normal runs, and it updates compatibility metadata when the installed plugin version changed.
   On the first run after an update it may also **migrate the config**: a pre-schema-3 config
   becomes config schema 3 (named issue trackers — `issueTrackers`, the moved issue credential,
   the legacy-work bindings; see [flight-setup.md → Named issue trackers](flight-setup.md#named-issue-trackers-config-schema-3)),
   reporting each change on stderr. Migration refuses rather than guesses (mixed forms, an
   invalid result, a newer schema). **If reconcile exits non-zero, stop and report its message
   to the user — never continue with issue, label or promotion commands.** Every issue verb
   depends on the migrated config, and running them against a half-understood one is exactly
   what the refusal exists to prevent.
4. Know your own model id (e.g. `claude-fable-5-1`, `gpt-5.6-sol`) and pass it as
   `--model <id>` on every body-writing verb — `issues create|update|comment`, `pr open|update`.
   The dispatcher signs each body it writes (`---` then `🤖 via FlightDirector:flight@<version> with
   <Model/ver>`); it cannot discover the model itself, so without `--model` the signature simply
   omits the "with …" clause. `FLIGHT_MODEL=<id>` in the environment is the equivalent for a
   shell that persists it. See [adapter-contract.md](adapter-contract.md) → **Body signature**.

Examples in the skill documentation use `flight` for readability. Execute them through
`"$DISP"`. Likewise, execute `batch-manifest` through `"$BATCH_MANIFEST"`.

Reconciliation is for config/schema compatibility (including the one-time schema-3 migration). Model labels are runtime provenance and are
created lazily during ledger finalization; they do not depend on a plugin release.
