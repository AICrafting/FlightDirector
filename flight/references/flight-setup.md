# Flight setup

Shared by all flight skills. Every backend operation goes through the **dispatcher** —
`flight <group> <verb> …` — which calls the backend's REST
API with `curl`. There is no MCP server, and no token handling in the skills themselves. See
[ADR 0001](../../docs/adr/0001-curl-over-mcp-and-adapter-architecture.md) for why, and
[adapter-contract.md](adapter-contract.md) for the full verb set.

## Prerequisites

- `curl` and `jq` on `PATH`.
- `python3` (standard library only) — **only** if you turn on the prompt ledger
  (`code.promptLog.enabled`); nothing else in flight needs it.
- A per-repo API token (least privilege — see below). Nothing to install or run.

## Platforms

Linux, macOS and Windows are all supported and CI-tested on every change (bash 5, bash 3.2.57,
macOS/BSD userland, Windows/MSYS legs on the `tests` workflow).

- **macOS** — stock bash 3.2 and BSD tools are enough; nothing to install (#127).
- **Windows** — Git Bash / MSYS. `flight/scripts/_portable.sh`, sourced by every entrypoint and
  adapter, is a no-op elsewhere and on Windows wraps `jq` to strip the `\r` a native `jq.exe`
  emits and normalises path form with `cygpath` so `branches prune` matches `.worktrees/` entries.
  Keep `/usr/bin` ahead of `System32` on `PATH` (interactive Git Bash already does) or
  `sort -u` in `branches` hits Windows' own `sort.exe`. The prompt ledger's lock uses `msvcrt`
  where `fcntl` is absent (#130).

## The config files in the `.flightdirector/` folder

> **Renamed folder.** Before the plugin was renamed from `lightspeed` to `flight` this folder was
> `.lightspeed/`. The dispatcher still reads a legacy `.lightspeed/config.json` when
> `.flightdirector/config.json` is absent (printing a one-line deprecation notice on stderr), and
> resolves `secrets.json` independently so a half-migrated repo keeps working. Migrate with
> `git mv .lightspeed .flightdirector` plus a manual `mv` of the gitignored `secrets*` files, or
> re-run `setting-up-a-repo`. `.flightdirector/` is shared by every Flight Director plugin.

### `.flightdirector/config.json` — committable

**Present means answered.** The setup skills treat every key they own as the recorded answer
to one setup question: on a re-run they ask only the questions whose key is *absent*, and write
every answer back — including a "no" (e.g. `"promptLog": { "enabled": false }`). So a key set to
`false` is not the same as a missing key: the first is a decision, the second is a question the
repo has never been asked, and the next re-run will ask it. `setting-up-a-repo` owns the
repo-wide keys (`code.*`); `add-an-issue-tracker` owns each tracker entry's keys, including its
starting status `labels.status.new` (string = configured, `false` = declined, absent = never
asked — per tracker).

Two parts, with one owner each:

- **`code`** — the required base: where code, change-requests (PRs), CI and the stage pipeline
  live, plus the repo-wide preferences.
- **`issueTrackers`** — one or more named issue trackers (this repo, another repo or backend, a
  Jira project), each with its own coordinates, credential and label map; exactly one is the
  default. See [Named issue trackers](#named-issue-trackers-config-schema-3).

A config as `setting-up-a-repo` writes it on a fresh repo (the stamp is added by the first
`flight reconcile`):

```jsonc
{
  "schemaVersion": 3,
  "harnesses": {
    "claude": { "plugins": { "flight": { "reconciledWith": "<installed version>" } } },
    "codex":  { "plugins": { "flight": { "reconciledWith": "<installed version>" } } }
  },
  "code": {
    "backend": "forgejo", "owner": "acme", "repo": "widget",
    "api": "https://git.example.com/api/v1",
    "stages": [
      { "name": "develop", "merge": "direct", "gate": "pre-merge", "issueStatus": "to-test" },
      { "name": "qa",      "merge": "pr",     "gate": "post-merge-qa", "issueStatus": "qa" },
      { "name": "main",    "merge": "pr",     "strategy": "merge", "issueStatus": "done" }
    ]
  },
  "issues": { "backend": "requires-newer-flight", "note": "…" },  // stops older Flight versions
  "issueTrackers": [
    { "ref": "FJ", "name": "Working backlog", "default": true, "aliases": [],
      "backend": "forgejo", "owner": "acme", "repo": "widget",
      "api": "https://git.example.com/api/v1", "credentialRef": "code",
      "labels": {
        "status": {
          "new":         "status/new",
          "in-progress": "status/in progress",
          "to-test":     "status/to test",
          "blocked":     "status/blocked",
          "deferred":    "status/deferred"
        },
        "model": { "opus": "model/opus", "sonnet": "model/sonnet",
                   "haiku": "model/haiku", "fable": "model/fable",
                   "sol": "model/sol", "terra": "model/terra",
                   "luna": "model/luna", "astra": "model/astra" }
      } }
  ]
}
```

> **Older configs.** Schema 1 and 2 had a single `issues` object (inheriting `code` when
> omitted) and a top-level `labels` map. `flight reconcile` — which every skill runs first —
> migrates them to this form; see **Migration** below. Never convert one by hand.

- **`schemaVersion`** — version of the committable Flight config schema. Schema 3 replaced the
  single `issues` object and top-level `labels` with `issueTrackers`; schema 2 nested the
  reconcile stamp under `plugins` (see below). Older configs migrate themselves on the next
  reconcile, so there is no manual step.
- **`harnesses.<harness>.plugins.<plugin>.reconciledWith`** — installed version of that Flight
  Director plugin that last reconciled this config from that harness (`claude` or `codex`). The
  stamp is scoped per harness **and** per plugin because `.flightdirector/` is shared by the whole
  family: without the `plugins.<name>` level, two plugins would overwrite one key and each would
  compare its version against the other's. A schema 1 config's bare
  `harnesses.<harness>.reconciledWith` is flight's stamp by definition — `flight reconcile` moves
  it to `plugins.flight.reconciledWith` and drops the old key. Unknown keys are preserved and an
  older plugin never downgrades a newer stamp *of the same plugin*. Model discovery is not a
  migration: missing `model/*` labels are created lazily when work-ledger entries are finalized.

- **`api`** — the backend's API base, *not* repo-scoped; the adapter appends the repo path. Its
  shape is per backend: Forgejo/Gitea `https://<host>/api/v1`, GitHub `https://api.github.com`,
  GitLab `https://<host>/api/v4`, Jira the site base. The example above is a Forgejo repo; the
  same file pointed at GitHub or GitLab differs **only** in `backend` and `api` — see the
  per-backend sections below and [backends.md](backends.md).
- **`issueTrackers[].labels`** — maps each **role** to the **actual label name that tracker
  uses** (two trackers may call the same role differently). Skills and adapters speak roles and
  names; turning a name into its numeric id happens *inside* the
  adapter, so nothing above the adapter ever deals in label ids.
- **`stages`** — ordered promotion pipeline. `stages[0]` is the first integration branch;
  feature branches fork from it. Each hop carries its own `merge` (`direct`|`pr`), optional
  `strategy` (see below) and optional `gate` (`pre-merge`|`post-merge-qa`, default
  `pre-merge`). Consumed by `working-an-issue` (uses `stages[0]`) and `promoting-a-branch`
  (one hop at a time).
- **`strategy`** (per stage, optional) — the merge strategy used when a `pr` hop's PR is merged
  into this stage: `merge` | `squash` | `rebase`. **Defaults to `merge`.** A true merge is the
  default because Flight's model is one branch per issue promoted through a chain of stages:
  the same commits travel `feature → develop → qa → main`, and preserving them keeps each
  stage's history comparable, keeps `git log <target>..HEAD` (how `promoting-a-branch` finds an
  issue's commits) meaningful at every hop, and avoids the duplicate-commit churn that squashing
  or rebasing at one hop causes at the next. Set `"strategy": "squash"` on a stage whose repo
  convention is a linear one-commit-per-PR history. Read it with:
  ```
  flight config '.code.stages[<i>].strategy // "merge"'
  ```
  It applies to `pr` hops only — a `direct` hop always merges with `--no-ff`.
- **`issueStatus`** (per stage, optional) — a **status role name** (a key in `labels.status` of
  the tracker the issue belongs to, so each tracker applies its own label name).
  On *entering* this stage, `promoting-a-branch` runs the atomic `issues set-status --status
  <role>` (adds the new status, drops the others in one call — the board can never show two
  states). Omit to leave the issue's status untouched on entry to this stage. Setting it on the
  **terminal** stage (e.g. `issueStatus: "done"`) relabels the issue as it closes, so a shipped
  issue shows `status/done` rather than keeping its last in-flight label (e.g. `status/qa`).
- **`closesIssues`** (per stage, optional, boolean) — **defaults to "true iff this is the
  terminal (last) stage."** Set explicitly to override: `false` on the terminal stage keeps
  issues open after the final stage; `true` on a non-terminal stage closes issues early at that
  stage (e.g. close at `develop`, treat `main` as a pure release cut). The `gate` field is
  orthogonal — it governs merge policy, not issue lifecycle.
- **`syncDown`** (per stage, optional) — how this stage **receives a back-merge** after a
  promotion lands on a stage above it: `direct` | `pr` | `none`. **Defaults to the stage's own
  `merge` value**, so a stage written by PR is synced by PR and a direct-merge stage by direct
  push — most repos need no config change. After `stages[i-1] → stages[i]` lands,
  `promoting-a-branch` runs `flight branches sync-down --from <stages[i]>`, which merges each
  stage back into the one below it and cascades to `stages[0]`, so every lower stage stays level
  ([ADR 0002](../../docs/adr/0002-sync-down-after-promotion.md)). The back-merge is always a true
  merge (fast-forward when possible, one merge commit otherwise; a `pr` sync merges with the
  `merge` method regardless of the stage's promotion `strategy`). `none` opts the stage out and
  stops the cascade there. A stage whose branch protection rejects direct pushes needs
  `syncDown: "pr"` or `"none"`. Read it with:
  ```
  flight config '.code.stages[<j>].syncDown // .code.stages[<j>].merge // "direct"'
  ```
- Note: `trunkBranch`, `mergeStrategy`, and `gate` (single-value top-level fields) are
  superseded by `stages` — the per-stage `strategy` field replaces a top-level `mergeStrategy`.
  For backwards compatibility a legacy `trunkBranch` is still read
  **first** if present; otherwise `stages[0].name` is used.

### Named issue trackers (config schema 3)

Schema 3 replaces the singular `issues` object and the top-level `labels` map with an
**`issueTrackers` array**: any number of named trackers, exactly one of them the default. `code`
keeps owning code, PRs, CI and the stage pipeline. `flight reconcile` migrates an older config
for you (see **Migration** below) — nobody needs to hand-convert one.

```jsonc
{
  "schemaVersion": 3,
  "code": { "backend": "forgejo", "api": "https://git.example.com/api/v1", "owner": "acme", "repo": "widget", "stages": [ … ] },
  "issues": { "backend": "requires-newer-flight", "note": "…" },  // written by migration; see below
  "legacyIssueTracker": "FJ",                                        // written by migration; see below
  "issueTrackers": [
    { "ref": "FJ", "name": "Working backlog", "default": true,
      "backend": "forgejo", "api": "https://git.example.com/api/v1", "owner": "acme", "repo": "widget",
      "credentialRef": "code",
      "labels": { "status": { "in-progress": "status/in progress", "new": false }, "model": { "sol": "model/sol" } } },
    { "ref": "GH", "aliases": ["Public"], "name": "Public intake",
      "backend": "github", "api": "https://api.github.com", "owner": "acme", "repo": "widget",
      "labels": { "status": { "in-progress": "status/in-progress" } } }
  ]
}
```

Per tracker entry:

- **`ref`** (required) — the stable identity used in qualified issue ids (`FJ-12`) and in branch
  names (once the repo has more than one tracker — see *Issue names with one tracker* below). A letter followed by letters and digits only — no `-`, `_` or `#`, so `GH1`, `GH-1` and
  `GH#1` split without guessing. Unique across every `ref` **and** alias, compared
  case-insensitively; `code` is reserved. Prefer the Jira project key for a Jira tracker,
  otherwise the backend shorthand (`GH`, `FJ`, `GL`). Never rename a ref once branches use it.
- **`name`** (required) — display name only; changing it is harmless.
- **`default`** — `true` on exactly one tracker; `false` or absent on the rest.
- **`aliases`** (optional) — more refs that select this tracker (exact, case-insensitive).
- **`backend`**, **`api`**, **`owner`**, **`repo`**, **`project`**, **`email`** — this tracker's
  own coordinates, exactly as the `code` block spells them for the same backend. Several trackers
  may share a backend (two Forgejo repos, two Jira projects on one site).
- **`credentialRef`** (optional) — which credential the tracker uses:
  - omitted, or the tracker's own `ref`: **its own credential**, `secrets.issueTrackers.<REF>`
    and nothing else. Environment tokens are code credentials and never shadow it.
  - `"code"`: **share the code credential**, resolved exactly as the code axis resolves it
    (`LS_TOKEN`/`FLIGHT_TOKEN`/`FORGEJO_TOKEN`, then `secrets.code`). Allowed only when the
    tracker's `backend` and `api` host equal `code`'s — a token is never sent to another system.
    Owner and repo may differ (a sibling repository on the code host). When a
    `config.local.json` moves `code` to another route on one machine (a tunnel, a LAN address),
    a tracker on the committed code host stays valid; it keeps using the committed host unless
    that machine adds a complete local `issueTrackers` array.
- **`labels`** — this tracker's role → label-name map (the old top-level `labels`, now per
  tracker): status roles including `new` (a string = configured, `false` = declined, absent =
  never asked — #193), model labels, and any role of your own. An adapter only ever sees the
  selected tracker's map.
- Unknown keys are preserved.

**Setting trackers up.** `setting-up-a-repo` hands the first tracker to the
`add-an-issue-tracker` skill, which you can also run on its own to add more. The first tracker
becomes the default; adding another never moves it unless you ask. The skill proposes the Jira
project key as a Jira tracker's ref and `FJ`/`GH`/`GL` otherwise, and asks for another name
when that one is already a ref or alias. A tracker on the code repository normally shares the
code credential; any other gets its own token under `secrets.issueTrackers.<REF>`. It verifies
the credential with `flight auth check --tracker <REF>` and reconciles that tracker's labels on
their own.

**Copied issues.** `flight issues copy` (and the `copying-an-issue` skill) records each copy in
`.flightdirector/copies.jsonl`: one JSON line per step, `{source, target, at, components,
comments}`, with the latest line for a source and target tracker winning. It belongs to this
clone and must be git-ignored (`setting-up-a-repo` adds `.flightdirector/copies.jsonl` to
`.gitignore`; `copy` warns while it isn't), since it maps private issues to public copies. `copy` uses it to refuse
a second copy, and `resync` uses it to know which comments are already across. Deleting it
forgets the links; it never affects the issues themselves.

Two top-level keys should be left alone once present:

- **`issues: { "backend": "requires-newer-flight", … }`** — written by migration and by
  `setting-up-a-repo` on a fresh config: a stub for **older Flight versions**, which route issue verbs through `issues.backend`: they now stop with *no 'issues'
  adapter for backend 'requires-newer-flight'* instead of silently acting on the code repository.
  Schema-3 Flight ignores it (any other `issues` object beside `issueTrackers` is an error).
- **`legacyIssueTracker`** — written by migration only (a fresh config never has one): the
  tracker that was the default when the repo migrated. Branches
  and batch manifests created before schema 3 carry bare issue numbers; they belong to this
  tracker however the default changes later (see **Legacy work** below).

Validation runs before every tracker-routed operation (issue and label verbs, `auth check
--tracker`/`--axis issues`) and before reconcile writes anything, and reports every problem at
once. Plain `flight config` reads are not blocked by an invalid tracker list, so it can still
be inspected and repaired.

**Selecting a tracker.** A bare number (`12`, `#12`) means the default tracker. `FJ12`, `FJ-12`
and `FJ#12` — ref or alias, any case — mean that tracker; a Jira key (`PROJ-7`) selects the Jira
tracker whose `project` it names and stays the native id the adapter receives. `--tracker REF`
selects explicitly; it may pick between ambiguous splits (`A12` with refs `A` and `A1`) but a
qualified id naming a different tracker is an error. An unknown or near-miss ref fails with
suggestions and the configured list — flight never guesses a target. See
[adapter-contract.md](adapter-contract.md) for `issues resolve`, `issues tracker` and
`issues list --all-trackers`.

**Issue names with one tracker.** While `issueTrackers` holds a single entry that is Jira or the
code repository's own issue tracker, the prefix says nothing, so flight leaves it out (#258):
issues are `#12` (`PROJ-7` on Jira) in commits, reports and list rows, and branches are
`feature/12-<slug>`. The qualified id (`FJ-12`) still works everywhere as input and stays the
`qualified` field of `issues resolve` and the `--json` output. Adding a second tracker switches
new work to qualified names; branches started before that keep resolving to their tracker
through the bindings in `batches/work-items/identities.json`, and an unbound `feature/12-…`
branch is then asked about rather than guessed.

**Migration.** `flight reconcile` converts a schema-1/2 repo once, file by file:

1. **`config.json`** (tracked): the old effective issue axis — `issues` fields over the code
   coordinates they inherited — becomes one default tracker; the whole `labels` map moves into
   it (unknown roles, `new` as string/`false`/absent, explicit `false`/`null` values all kept);
   code settings stay on `code`. It gets `credentialRef: "code"` when it is on the code host
   (same `backend` and `api`; owner/repo may differ) and there was no separate issue token (none,
   or one equal to the code token) — exactly what the old issues axis used, so env-token and CI
   setups keep working. A separate issue token, or another host, gives it its own credential.
   `schemaVersion` becomes 3, `legacyIssueTracker` records the tracker's ref, and only the
   running harness's stamp changes. Commit it — together with a Flight update for every clone
   and harness.
2. **`config.local.json`** (per machine): a legacy local `issues`/`labels` override becomes a
   complete local `issueTrackers` array (arrays replace wholesale, so a partial entry would
   erase the tracked trackers), with the override applied to the **`legacyIssueTracker`**
   tracker — the one those settings belonged to, even if the default has changed since. A local
   file that only overrides `code` coordinates is left byte-identical; trackers no longer follow
   it, and reconcile says so once (add a complete local `issueTrackers` array if a tracker should
   use the local route). Local values never reach the tracked file.
3. **`secrets.json`** (per machine): the legacy `issues` credential **moves** (never copies) to
   `issueTrackers.<REF>` of the `legacyIssueTracker` tracker — only if that tracker is on the
   backend and api host the credential was used with; otherwise reconcile refuses, naming both
   hosts. An issue token equal to the code token is dropped (the tracker shares the code
   credential). The code token is never copied into `issueTrackers`; a tracker with its own
   credential and no token yet gets a notice, also when there is no secrets file at all. `code`
   is never touched and no token is ever printed.
4. **Legacy work**: see below.

Every check that can fail — validation of every result, the legacy-tracker checks, a bindings
file bound to another tracker, the bindings lock — runs before the first write; then secrets,
the local override, the bindings and, last, the tracked config are written. A refusal leaves
every file untouched, and a repeat run changes nothing. A clone that later pulls the migrated
config converts its own `config.local.json`, `secrets.json` and bindings on its next reconcile;
if its legacy state cannot be attached — the config has no `legacyIssueTracker`, or it names no
configured tracker — reconcile refuses with a repairable error instead of guessing. A file
holding both the legacy and the named form is refused untouched, and a config from a newer
schema is refused by every command (except the silent prompt-log hooks).

**Legacy work.** Reconcile records every pre-schema-3 unqualified issue branch (local and
remote-tracking, e.g. `feature/12-x`) and batch manifest in
`.flightdirector/batches/work-items/identities.json`, bound to `legacyIssueTracker`. It lives
under `.flightdirector/batches/`, which setup already gitignores; it is local, merged (never
re-pointed) on repeat runs, and a file bound to a different tracker stops the migration with a
repairable error.

### Repo preflight gate (optional)

The repo's own check command, run before work is merged or pushed. Nothing changes for a repo
that leaves it out — this is the one key whose absence is the whole of its unset behaviour.
`setting-up-a-repo` offers it; a declined offer is recorded as `"preflight": false`, which every
reader treats exactly like an absent key.

```jsonc
"code": {
  // …existing keys (backend, owner, repo, api, stages)…
  "preflight": "./scripts/run-checks.sh"
}
```

- `code.preflight` — a **shell command string**, run with `sh -c`. Read it with:
  ```
  PREFLIGHT="$(flight config '.code.preflight // empty')"
  [ -n "$PREFLIGHT" ] || echo "no preflight configured"   # absent and null both land here
  ```
  **Working directory:** always the checkout that holds the code being gated, passed explicitly
  (`sh -c "$PREFLIGHT"` run from that path, never from whatever directory the shell has wandered
  into). That is the feature worktree `$WT` in `working-an-issue` and `promoting-a-branch`, each feature worktree in
  `promoting-branches`, the integration worktree on a `pr` group, and each issue worktree
  (`.worktrees/<ref>-<N>-<slug>`) in `queue-batches`. Write the command so it works from a repo
  root that is not the main checkout — a hard-coded absolute path defeats the point.
  **Exit code is the verdict:** zero passes, non-zero halts the operation and the failing output
  is shown. Nothing parses stdout.
  **A pass belongs to the commit it judged.** `promoting-a-branch` records the verdict against
  the commit the gate ran on and never reuses it: every promotion runs the gate again, and the
  merge (or `pr open`) goes ahead only on a pass for the exact commit being promoted. So if the
  branch moves between the gate and the merge, or a promotion tries to lean on an earlier run,
  it stops with *"preflight gate is not green"* even though the last run you saw was green.
  That is not a false red: the gate has not seen that commit. Promote again and it will.
  **Where it runs:** `working-an-issue` before moving the issue to `to-test` (a failure leaves
  it `in-progress`); `promoting-a-branch` before the merge on a `direct` hop and before
  `pr open` on a `pr` hop (that hop never pushes the source branch — it expects it on origin
  already); `promoting-branches` before each branch's merge on a `direct` hop (a failure skips
  that branch and the group continues), and on a `pr` hop once on the group's assembled
  integration branch before it is pushed (a failure skips the **whole group**: nothing pushed, no
  PR, other groups continue);
  `queue-batches` from the **orchestrator** once a zone finishes, per issue worktree.
  The command is the repo's problem, so a repo on Windows writes one that works there. It is a
  local gate, not a CI replacement — a `pr` hop still watches CI afterwards.

> Not to be confused with the **runtime preflight** every skill performs before its first
> dispatcher call ([runtime.md](runtime.md)) — that resolves the dispatcher path and reconciles
> plugin metadata. `code.preflight` is the *repo's* check command and is unrelated to it.

### Branch cleanup config (optional)

Consumed by the `cleaning-up-branches` skill and the `branches` dispatcher group.

```jsonc
"code": {
  // …existing keys (backend, owner, repo, api, stages)…
  "branches": { "patterns": ["feature/*", "bugfix/*", "release/*", "batch/*"] }
}
```

- `code.branches.patterns` — globs naming which branches are cleanup *candidates* at all.
  Defaults to `["feature/*", "bugfix/*", "release/*", "batch/*"]` when absent, which matches
  flight's own `feature/<ref>-<N>-<slug>` convention (and the older `feature/<N>-<slug>`), the
  `batch/<group>-<short>` integration branches `promoting-branches` opens on a `pr` hop, plus
  the usual bugfix and release-fold names. Set it when your repo spells them differently
  (`feat/*`, `fix/*`) so you don't pass `--pattern` every time — your list **replaces** the
  defaults outright rather than adding to them, so repeat any built-in prefix you still want
  covered.
  Widening it is safe: stage branches, `archived/*`, and any branch checked out in the main
  checkout or in a worktree outside `.worktrees/` are protected regardless of what the patterns
  say. Read it with:
  ```
  flight config '.code.branches.patterns // ["feature/*","bugfix/*","release/*","batch/*"]'
  ```
  There is deliberately **no** "delete on the remote by default" knob: remote deletion is the one
  irreversible step, so it stays an explicit `--remote` on each run.

### queue-batches config (all optional)

Consumed only by the `queue-batches` skill; absent keys fall back safely.

```jsonc
"code": {
  // …existing keys (backend, owner, repo, api, stages)…
  "zones": [ { "name": "auth", "paths": ["src/auth/**"] } ],
  "queueBatches": { "defaultModel": ["sonnet", "luna"], "agentRulesFile": ".flightdirector/agent-rules.md" }
}
```

- `code.zones` — `[{ "name": "...", "paths": ["glob", ...] }]`. Disjoint file zones used to
  schedule parallel work so concurrently-running issues never touch the same paths. If omitted,
  `queue-batches` infers pseudo-zones from issue bodies at triage time and warns that the
  inferred zones are approximate.
- `code.queueBatches.defaultModel` — worker-agent model when the user gives no per-run override:
  a model name, or an **ordered preference list** of them. `queue-batches` uses the first entry
  the running harness can dispatch — Claude Code skips Codex models and vice versa — and if a
  dispatch fails because the model is unavailable (no access, not on the plan, retired), it
  falls through to the next entry. If no entry is usable it asks rather than picking one. The
  plan names the model chosen and the entries skipped. A plain string is a one-item list, so
  existing configs need no change. `flight config worker-model --harness claude|codex` prints
  the resolution (`<model>⇥use|skip⇥<reason>` per entry). Seeded by `setting-up-a-repo`; falls
  back to `["sonnet", "luna"]` if unset, so each harness has a default. To prefer a different
  model on one machine, set the list in `config.local.json` — arrays replace wholesale there.
- `code.queueBatches.agentRulesFile` — path (repo-relative) to a markdown file of repo-specific
  agent hard-rules / CI gotchas, injected verbatim into each worker prompt. Defaults to
  `.flightdirector/agent-rules.md`; if that file is absent, workers run with the skill's built-in
  safety rules only (no project-specific rules).

### Body signature (on by default)

```jsonc
"code": { "signature": { "enabled": true } }
```

- `code.signature.enabled` — when `true` (the default, and absent counts as `true`) the
  dispatcher ends every issue body, comment and PR body it writes with a `---` rule and
  `🤖 via FlightDirector:flight@<version> with <Model/ver>` (the model clause only when the skill passed
  `--model`). Set `false` to write bare bodies; `--no-signature` does the same for one call.
  Details: [adapter-contract.md](adapter-contract.md) → **Body signature**.

### CI watch timeouts (optional)

```jsonc
"code": {
  "ciWatchTimeout": 900,
  "ciQueueTimeout": 3600
}
```

`ci watch` keeps two clocks, because "still queued" and "hung" are not the same failure and a
repo with one runner per platform hits the first constantly.

- `code.ciWatchTimeout` — seconds a run may spend **executing**. Default `900`; `0` disables the
  cap. Precedence: `--timeout` → `LS_CI_WATCH_TIMEOUT` → this → default. Time in which every job
  of every non-terminal run is waiting for a runner does **not** count against it.
- `code.ciQueueTimeout` — seconds every run for the SHA may spend **waiting for a runner**, in
  total. Default `3600`; `0` disables the cap. Precedence: `--queue-timeout` →
  `LS_CI_QUEUE_TIMEOUT` → this → default. When it fires the message says the run never started
  executing, so a queue is never reported as a hang.

Raise `ciQueueTimeout` on a repo where several PRs land at once and serialize on a scarce
runner; raise `ciWatchTimeout` only when the tests themselves got slower. The one case still
bounded by `ciWatchTimeout` alone is "no run exists at all" — that is a trigger or push problem,
not a queue, and is still reported within `ciWatchTimeout`.

### Prompt ledger (optional, off by default)

```jsonc
"code": {
  "promptLog": { "enabled": true }
}
```

- `code.promptLog.enabled` — turns on the bundled prompt/cost logger for this repo. The plugin
  ships hooks for both harnesses; they run `flight prompt-log <mode>`, which exits silently unless
  this is `true`, so the switch is the only producer control. When on, every turn appends one
  record to `.flightdirector/prompt-log.jsonl` under the main worktree root (gitignore it — records contain prompt
  text) and `working-an-issue` sums them per session for the work-ledger comment via
  `flight prompt-log summary`. Schema, pricing, and semantics: [prompt-log.md](prompt-log.md).
  Write `false` to decline explicitly — a missing key makes `setting-up-a-repo` offer the ledger
  again on its next re-run (see "Present means answered" above).
- `.flightdirector/pricing.json` — optional per-repo pricing override/extension, merged on top of
  the bundled `flight/scripts/prompt-logger/pricing.json` (same shape).

### GitHub backend

Point `code` or a tracker entry at GitHub by setting its `backend` + `api` in
`.flightdirector/config.json`:

```jsonc
"code": {
  "backend": "github",
  "owner": "your-org-or-user",
  "repo": "your-repo",
  "api": "https://api.github.com",          // the API host itself — no version path
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

The code token goes in the gitignored `.flightdirector/secrets.json` (`code.token`; a tracker
with its own credential uses `issueTrackers.<REF>.token`): a fine-grained PAT
scoped to the repo with Contents, Issues, and Pull requests read/write (plus Actions read if you
use `ci`), or a classic PAT with **repo** (+ **workflow**). `setting-up-a-repo` detects a
`github.com` remote and proposes this config for you. Full permission table in
[backends.md](backends.md#github-full-parity).

### GitLab backend

Point `code` or a tracker entry at GitLab by setting its `backend` + `api`. `owner`/`repo` together form the
project path GitLab addresses by (subgroups belong in `owner`, e.g. `"group/sub"`):

```jsonc
"code": {
  "backend": "gitlab",
  "owner": "your-group",                    // subgroups allowed: "group/subgroup"
  "repo": "your-project",
  "api": "https://gitlab.com/api/v4",       // self-managed: https://gitlab.example.com/api/v4
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

The code token goes in the gitignored `.flightdirector/secrets.json` (`code.token`; a tracker with
its own credential uses `issueTrackers.<REF>.token`), a GitLab personal or project access token
with the **api** scope. `pr` is a merge request and `ci` is pipelines (see the
[adapter contract](adapter-contract.md) → GitLab specifics for the `--strategy` and pipeline
nuances). `setting-up-a-repo` detects a GitLab remote (corroborating a custom host before
asserting it) and proposes this config.

### Jira tracker (issue tracker only)

Jira is an issue tracker, not a git host, so it appears **only as an `issueTrackers` entry** —
pair it with a git `code` backend (`pr`/`ci` keep resolving to `code`). Its ref is normally the
project key, so a Jira key (`KAN-12`) names its tracker directly:

```jsonc
{
  "code": { "backend": "github", "owner": "acme", "repo": "widget",
            "api": "https://api.github.com", "stages": [ { "name": "main", "merge": "pr" } ] },
  "issues": { "backend": "requires-newer-flight", "note": "…" },
  "issueTrackers": [
    { "ref": "KAN", "name": "Product planning", "default": true,
      "backend": "jira",
      "api": "https://your-site.atlassian.net",  // the site base, no /rest/api/3
      "project": "KAN",                            // the Jira project key
      "email": "you@example.com",                  // for email:token Basic auth (or in secrets)
      "labels": { "status": { "in-progress": "status/in-progress", "new": false } } }
  ]
}
```

Auth is HTTP **Basic** `email:api_token` (a classic Atlassian API token — not OAuth). The token
goes in `.flightdirector/secrets.json` under `issueTrackers.<REF>.token` (Jira never shares the
code credential — different host); the account email is the tracker's `email`, else
`issueTrackers.<REF>.email` in the secrets file. The dispatcher exports `LS_PROJECT` + `LS_EMAIL`
alongside the usual `LS_*`. See `adapter-contract.md` → **Jira backend specifics** for the
identifier (key-as-id), status-as-labels (label names must be space-free), close-as-transition,
ADF, and thin-labels behaviours. `add-an-issue-tracker` offers Jira, and `setting-up-a-repo`
suggests it when commit subjects or branch names carry Jira keys.

### `.flightdirector/secrets.json` — gitignored

Just the token(s). Schema 3 keys tracker credentials by tracker `ref`:

```jsonc
{ "code": { "token": "…" }, "issueTrackers": { "GH": { "token": "…" }, "PROJ": { "token": "…", "email": "…" } } }
```

`code` is the code credential (also used by any tracker with `"credentialRef": "code"`);
`issueTrackers.<REF>` belongs to the tracker with that exact `ref` and to nothing else. A
schema-2 file (`{ "code": …, "issues": … }`, with `issues` inheriting `code`) is migrated by
`flight reconcile` — see [Named issue trackers](#named-issue-trackers-config-schema-3).

**This file must be gitignored** — it holds a credential. If flight finds it tracked by
git, it warns loudly on every run (it does not refuse). Add the `.flightdirector/secrets*` glob to
your `.gitignore` — ignoring the whole family (`secrets.local.json`, `secrets.json.bak`,
`secrets-github.json`, editor swap copies) rather than the one exact filename.

Token precedence: `LS_TOKEN` or `FLIGHT_TOKEN` in the environment override the code credential
(`FORGEJO_TOKEN` is still honoured as the legacy name) — for `code` and for any tracker with
`"credentialRef": "code"`; otherwise the secrets file's `code.token`. **Exception (schema 3):** a tracker with its own credential reads
only `issueTrackers.<REF>` — environment tokens are code credentials and never reach it.

**Not sure which token is in play? Run `flight auth check`** — it names the source it used
beside the masked token, either the env var (`(from $FLIGHT_TOKEN)`) or the secrets file's full
path (`(from /path/to/repo/.flightdirector/secrets.json)`). The path is absolute on purpose: the
secrets file is gitignored, so it exists only in the main checkout and a repo-relative name
would not resolve from a linked worktree. Reach for this before assuming a 401 is about the
file — an old export is the likelier culprit, and the check says so outright.

One shadowing case is loud enough not to wait for `auth check`: when the legacy `FORGEJO_TOKEN`
is set *and* the secrets file holds a different token, every verb prints a note on stderr saying
the environment variable won. The backend-neutral `LS_TOKEN` / `FLIGHT_TOKEN` stay silent there
— overriding with those is deliberate, and a two-forge setup should not be nagged on every call.

### `.flightdirector/config.local.json` — optional, gitignored

A per-machine / per-person override of `config.json`, on the same footing as Claude Code's
`settings.local.json`: the committed file is the shared baseline, the local file holds what
differs on *this* machine — a different `owner` for a fork, a self-hosted `api` host,
`code.promptLog.enabled`, a `ciWatchTimeout`, a machine-specific tracker list. Absent → nothing
changes.

The dispatcher merges it over `config.json` with jq's recursive `*` for every **read**
(`cfg_get`, `flight config`, and the merged view handed to `branches`, `sync-down`, and the
adapters). The rules are jq's:

- **Nested objects merge key by key**, so the local file only needs the keys it changes:
  `{ "code": { "owner": "me" } }` overrides `code.owner` and leaves `code.repo`, `code.stages`
  and everything else alone.
- **Scalars and arrays replace wholesale.** A local `code.stages` replaces the *whole* pipeline;
  it does not patch one entry. Likewise a local `issueTrackers` must be the **complete** tracker
  array — a single-entry local array would hide every tracked tracker on this machine.
- A `null` in the local file overrides too; there is no "delete this key" spelling.

**Issue trackers (schema 3).** `issueTrackers` is an array, so a local one replaces the tracked
list wholesale: it must be the **complete** array — every tracker, exactly one default — or the
trackers it leaves out disappear on this machine (every tracker-routed command warns, naming the
missing refs). Trackers do not follow a local `code` override; to point a tracker at a local
route, copy the whole `issueTrackers` array into the local file and edit it there.

`flight reconcile` is the one writer and always writes the **tracked** `config.json` — local
values are never baked into the committed file. An invalid local file is a hard error (not a
silent fallback), and one that git tracks earns a warning on every run, like a tracked
`secrets.json`. Add `.flightdirector/config.local.json` to `.gitignore` next to `secrets*`.

## Least-privilege tokens

The point of a per-repo token is blast radius: one scoped to a single repo can't touch another,
so a misfire fails with `403` instead of writing to the wrong place. Scope the token to the one
repository or project wherever the backend allows it, and grant only what the skills call:

| Backend | Minimum |
|---|---|
| Forgejo/Gitea | `write:repository` (PRs, CI) + `write:issue` (issues **and** labels), restricted to the repo; no `write:misc` |
| GitHub | fine-grained PAT: Contents, Issues, Pull requests read/write; Actions read for `ci` |
| GitLab | project access token with the `api` scope (or a fine-grained per-project token) |
| Jira | unscoped API token — least privilege comes from the account's project role |

Where to create each token and the reasoning behind each minimum is in
[backends.md](backends.md).

## How resolution works

The dispatcher picks the target from the group — `pr`/`ci`/`branches` → `code`, `issues`/`labels`
→ **one** issue tracker (the default, `--tracker REF`, or the tracker a qualified id names) —
resolves that target's backend, coordinates, and credential, exports them as `LS_*`, and execs
`adapters/<backend>/<group>`; an issue adapter receives only the selected tracker's coordinates,
credential and labels. Skills therefore never pass owner/repo/token; they name the verb, and the
tracker when an issue belongs to one other than the default. `setting-up-a-repo` autodetects and
writes the code coordinates from the git remote on first run, and `add-an-issue-tracker` proposes
the code repository as the first tracker, so in the normal case you set nothing by hand. (A
schema-1/2 config, until reconcile converts it, still routes issues through its `issues` object
inheriting `code`.)

## Context note

List verbs project with `jq` to minimal TSV before anything reaches the conversation, so listing
issues is cheap on context. Still pass a sane `--limit` rather than pulling hundreds at once: the
adapter pages underneath the limit, so a big number really does fetch that many rows.

When a limit hides rows, the adapter says so on **stderr** (`warning: showing 50 of 109 rows …`)
and leaves stdout clean. Read that line: it is the only reliable signal that a list is partial,
since a full page on its own proves nothing.
