# Changelog

All notable changes to the **flight** plugin (formerly **lightspeed**) are recorded
here. Entries are written for *consumers* of the plugin — what a repo using flight
would notice — not every internal commit.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the plugin aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Heads-up for consumers:** the Claude Code plugin CLI has no version pinning —
> `marketplace update` pulls whatever the marketplace currently advertises. This
> changelog is the record of *what moved* when that happens.

## [Unreleased]

### Added

- **A repo can have several named issue trackers** (#197; ships together with #198's
  tracker-aware work lifecycle and #199's tracker setup). Config schema 3 replaces the single
  `issues` object and top-level `labels` map with an `issueTrackers` array: each tracker has a
  stable `ref` (`GH`, `FJ`, or a Jira project key), optional aliases, its own coordinates, its
  own credential and its own label map, and exactly one is the default. `code` still owns code,
  PRs, CI and the stage pipeline. Several trackers may share a backend. The dispatcher routes
  every issue and label verb to one tracker: a bare number means the default; `GH-12`, `GH12`,
  `GH#12` or a Jira key such as `PROJ-7` name their tracker; `--tracker REF` selects explicitly.
  Ambiguous or unknown refs fail with suggestions — flight never guesses where to write. New
  dispatcher verbs: `issues resolve` (the canonical `{tracker, number, qualified, branchPrefix}`
  identity), `issues tracker` (the selected entry), `issues list --all-trackers` (every tracker,
  each row prefixed with its qualified id; a tracker that cannot be reached is reported and fails
  the listing instead of looking empty), and `auth check --tracker REF`.

  **Migration is automatic.** The next `flight reconcile` (every skill runs it first) converts
  the repo: the old issue settings, inherited code coordinates and the complete label map
  (including a `new` starting status as a string, `false`, or absent) become one default
  tracker; a legacy `config.local.json` override and the gitignored `secrets.json` are converted
  on each machine — onto the tracker the repo migrated from (`legacyIssueTracker`), even if the
  default has changed since — without local values reaching the committed file and without
  printing a token; pre-schema-3 `feature/<N>-…` branches and batch manifests are recorded in
  `.flightdirector/batches/work-items/identities.json` (already gitignored by setup) as belonging
  to the tracker that was the default at migration, so changing the default later never
  re-points old work. The migration runs every check before its first write (a refusal leaves
  every file untouched), writes the committed config last, and is safe to re-run; a repeat run
  changes nothing.

  **Compatibility:**
  - **Update every clone and harness together.** Commit the migrated `config.json` only once
    everyone uses a Flight with schema-3 support. Older Flight versions do not know schema 3;
    migration leaves an `issues.backend: "requires-newer-flight"` stub so they stop with a
    "no 'issues' adapter" error instead of acting on the code repository, but they cannot use
    the trackers. This Flight in turn refuses any config newer than schema 3.
  - **Issues on the code host keep sharing the code token** — the code repository or a sibling
    repository on the same backend and api host — including `LS_TOKEN` / `FLIGHT_TOKEN` /
    `FORGEJO_TOKEN` environment overrides, so CI and env-token setups work unchanged (the
    tracker gets `credentialRef: "code"`). A tracker that had its own issue token, or one on
    another host, gets its own credential under `secrets.issueTrackers.<REF>`, which environment
    tokens never override; the issue token is moved there, and the code token is never copied.
    On another host with no issue token, reconcile says the tracker needs one.
  - **A `config.local.json` that only overrides `code` coordinates no longer steers the issue
    tracker.** Before, the issues axis followed a local code `api`/`owner` override; now the
    tracker keeps its committed coordinates and reconcile says so once. To point a tracker at a
    local route, put a complete `issueTrackers` array in `config.local.json` (arrays replace
    wholesale — a local array missing a tracker hides it, and every tracker-routed command warns).
  - A clone whose legacy local override or issue credential cannot be attached safely — the
    config has no `legacyIssueTracker`, it names no configured tracker, or the credential was
    used with another host — is refused with a repairable error, nothing changed.
  - `issues list` without `--all-trackers`, and every existing unqualified command, keep their
    exact output and act on the default tracker. `auth check --axis issues` checks the default
    tracker.
  - Anything that read `.labels` or `.issues` through `flight config` must read the tracker
    instead, e.g. `flight issues tracker | jq -r '.labels.status["to-test"]'`; the bundled
    skills are updated by #198/#199.

- **Issue work stays attached to the tracker it started on** (#198; ships with #197 and #199).
  Every workflow skill resolves the issue you name **once** — `12` means the default tracker,
  `GH-12` / `PROJ-7` name theirs — and then passes that tracker and native id on every later
  write: comments, the work ledger, model labels, status changes, assignment and close. Changing
  the default tracker mid-work therefore redirects nothing, and two trackers' issue 12 never
  collide:
  - **New branches and worktrees always carry the tracker**, the default's included:
    `feature/fj-12-<slug>` in `.worktrees/fj-12-<slug>`, and `feature/proj-7-<slug>` for Jira.
    Commits are written `feat(FJ-12): …`. Existing `feature/12-…` branches keep working: they
    belong to the tracker the repo migrated from (the bindings #197's migration records), and a
    legacy branch whose tracker cannot be recovered makes the skill **ask** instead of assuming
    the current default.
  - **Promotion only writes `Closes #N` / `Ready #N` for an issue in the code repository
    itself** (same backend, host and owner/repo) — a PR can no longer close the code repo's
    unrelated issue 12 because a different tracker's issue 12 was worked. Other trackers' issues
    get a non-linking `Tracks GH-12` line and are updated on their own tracker by the promotion.
    Issue bodies, comments, ledgers and tracker URLs are not copied into PRs.
  - Triage, filing's duplicate scan and queue planning list **every** tracker (`FJ-12`, `JIR-7`)
    and filter each by its own status labels; a tracker that cannot be reached is reported as
    unavailable, not shown as an empty backlog.
  - `flight branches list` reports the qualified issue (`FJ-12`, `unbound`, or `error` with the
    reason on stderr when the lookup fails) in its issue column, and batch manifests record full identities (`batch-manifest groups` prints
    `zone⇥FJ-7,GH-12`); manifests written before the upgrade keep working through the same
    bindings. Both behave exactly as before on a config that has not migrated yet.
  - New helper `scripts/issue-identity.sh` (the one place branch names, manifest entries and
    history references become an identity), used by the scripts and skills alike. A bare `#12`
    found in history maps to the tracker the repo migrated from only while that is also the
    code repo's own tracker (or there is none); otherwise it is ambiguous and the promotion asks
    which tracker it means.

- **New `add-an-issue-tracker` skill, and setup writes named trackers** (#199; ships with #197
  and #198). Say "add an issue tracker", "connect Jira" or "track issues on GitHub too" to add a
  second (or tenth) tracker beside the first: it collects the coordinates, proposes a stable
  ref — the Jira project key for a Jira project, otherwise `FJ` / `GH` / `GL` — and asks for
  another when that ref or an alias is already taken, instead of suffixing one silently. A
  tracker on the code repository shares the code token (`credentialRef: "code"`, so env tokens
  and CI keep working); any other gets its own token under `secrets.issueTrackers.<REF>`,
  checked with `flight auth check --tracker <REF>`. It then reconciles **that tracker's** labels
  on their own — adopting the names it already uses, creating only what is missing after one
  preview, never renaming or deleting a label — and records the full role map in the tracker's
  entry. Adding a tracker never moves the default; changing it is an explicit request.
  `setting-up-a-repo` keeps the code coordinates, stage pipeline and repo preferences (worker
  model, prompt ledger, preflight gate) and hands the first tracker to the new skill, which
  makes it the default. A fresh setup now writes a schema-3 config (with the
  `requires-newer-flight` stub, so an older Flight stops loudly rather than acting on the wrong
  repository); an existing repo is converted by `flight reconcile`, never by hand.
  - **The starting-status question moved into tracker setup and is asked per tracker** — one
    tracker can use `status/new` while another declines. An existing answer carries over
    unchanged through migration: a label name stays configured, `false` stays declined, and a
    tracker that was never asked is asked on the next setup re-run.
  - **Re-running setup preserves everything already answered** — trackers, refs, credentials,
    label names and the default — and asks each tracker only the questions it has no answer for
    yet (a migrated tracker is typically offered aliases).
  - The breadcrumb setup writes into `AGENTS.md` now names the trackers and the
    tracker-qualified branch form (`feature/fj-12-…`); re-run setup to refresh an existing one.

- **A repo can name its own check command, and promotion runs it** (#209). New optional
  `code.preflight`: a shell command string that flight runs, from the checkout holding the code
  being gated, before work is merged or pushed. A non-zero exit halts the operation and the
  failing output is shown. It closes a specific hole — a `direct` hop has no CI behind it, so
  until now the only gate on `feature → develop` was a human saying "promote", and batch agents
  were told to "run the repo's test command if one exists", leaving the command to each agent's
  judgment every time. `promoting-a-branch` runs it after the freshness check and before the
  merge (or before `pr open` on a `pr` hop); `promoting-branches` runs it per
  branch before that branch's merge, so a red gate is a skip and the clean branches still ship;
  `queue-batches` runs it from the **orchestrator** once a zone finishes, once per issue
  worktree, because a returned agent's shell is gone and cannot report a backgrounded result.
  **Absent by default**: with no `code.preflight` in the config every one of those steps is
  skipped and behaviour is exactly what it was, which is every repo configured before this.
  `setting-up-a-repo` offers it (#229): it suggests the check command the repo already uses and
  records a declined offer as `"preflight": false`, which behaves exactly like leaving it out, so
  an existing repo picks the question up on its next setup re-run.

- **A repo can nominate a starting status for newly filed issues** (#193). Setup offers it — per
  tracker, from `add-an-issue-tracker` (#199), which `setting-up-a-repo` runs for the first one: a
  freshly filed issue gets a `status/*` label so a board can tell "nobody has
  looked at this yet" apart from "someone forgot the label", and "what is untriaged?" becomes a
  label query. The suggested name is `status/new`, but like every other status role it is
  **mappable** — point the role at whatever you already call that state (`status/triage`,
  `status/open`, `status/backlog`), and an equivalent label you already have is adopted rather
  than duplicated. **Opt-in and off unless asked for**: with no `labels.status.new` on a tracker
  nothing changes for it, which is every repo configured before this. When it is on, `flight issues
  create` applies the label; passing a `status/*` label of your own leaves it alone, and
  `--no-status` skips it for one issue. It is an ordinary status, so the first `set-status` —
  normally when `working-an-issue` starts — removes it, and `triaging-issues` deliberately does
  **not** treat it as "already in the workflow". Issues filed outside flight do not get it.

### Changed

- **`pr get` and `pr list` report one state vocabulary on every backend** (#206). Both verbs now
  emit `open` | `closed` | `merged` whatever the backend calls it, so
  `[ "$(flight pr get --number N | cut -f3)" = open ]` is a correct open check anywhere.
  Previously `pr get` passed `.state` through raw: GitLab spells an open MR `opened`, so that
  comparison was false for every open GitLab MR, and `pr list` leaked the same raw value even
  though its documented shape already promised the normalized one. Nothing in the skills compared
  the field, so this was a latent trap rather than an active break - but #205 had just normalized
  `issues get` to `open` | `closed`, which made the asymmetry a reasonable thing to trip over.

  **Compatibility:** on Forgejo and GitHub, `pr get` on a **merged** PR now reports `merged`
  where it used to report `closed`. Those backends have no merged state on the wire (a merged PR
  is a closed one with `merged_at` set), and `pr list` has always derived `merged` from it; `pr
  get` simply was not. GitLab's transient `locked` still passes through unchanged - it has no
  equivalent on the other backends, and folding it into `open` or `closed` would invent a fact.
  The contract row now names the possible values, and the rig smokes assert the live post-merge
  value, which is the case a fake curl can only approximate.

- **The repo's own test suite runs in parallel** (#212). `scripts/run-tests.sh` ran its
  `scripts/tests/*.test.sh` one at a time, which made the Windows CI leg ~78% of the test
  workflow's wall clock: a median 488s against 112s for macOS and ~72s for the two Linux legs,
  and the slowest leg in 38 of 46 runs. The cause was not the setup (checkout, `setup-python`
  and the `jq` download together came to 7s of a 618s run) and not slow hardware: 28 unrelated
  test files were each 19-29x their Linux time, which is per-process cost. MSYS has no `fork()`,
  so every spawn is a `CreateProcess` plus an address-space copy, and these tests spawn
  constantly. Width is the one lever that helps every leg at once, so files now run concurrently,
  each output buffered and flushed whole on completion. Locally the suite went from 171s to 51s.
  `ci-watch.test.sh` is additionally split into one job per backend, because its timeout cases
  wait on a real clock and it would otherwise set the floor for the whole run; running that file
  directly still covers all three backends. `TEST_JOBS=1` restores the serial path for debugging,
  and `TEST_JOBS=N` picks a width (default: cores, capped at 8). Nothing a consumer of the plugin
  calls changes; this is the repo's own CI.

- **Documented that the terminal stage doesn't have to close the issue** (#154, user-submitted).
  Plenty of pipelines ship *past* their last branch: merging `main` deploys to dev, while preprod
  and prod are deployment approvals on the same workflow run, days later, with no branch of their
  own — so the issue closed when the last branch merged, before it had really shipped. Setting
  `"closesIssues": false` on the terminal stage has always supported this and the config reference
  always said so, but nothing showed it: `example-flows.md` demonstrated only the opposite move
  (closing *early*), and the guide's narrative implied closing at the last branch was inevitable.
  Both now cover it, with the honest caveat that flight cannot see a deployment, so the final
  close is yours to make — precisely, if you want, by asking for the issues referenced between the
  previously released commit and the one just deployed.

- **`issues get` now reports the issue's state** (#205). The first line becomes
  `number⇥title⇥state`, with `state` normalized to exactly `open` or `closed` on every backend.
  Previously it emitted `number⇥title` and exited 0 whether the issue was open or closed, so
  "is #N open?" had no single-issue answer and callers had to scan a paged `issues list --state
  open`. That scan was also silently coupled to the limit: trim it below the repo's open-issue
  count and an open issue past the cap reads as closed. `pr get` already returned
  `number⇥title⇥state⇥url`, so the omission looks to have been accidental rather than designed.
  The deferral guard in `promoting-a-branch` (#195) and its `promoting-branches` mirror now use
  the one-call form and the paging caveat is gone.

  Normalization is the substance, not the field: GitLab reports an open issue as `opened`, and
  Jira has no open/closed field at all, so its status **category** decides (`done` → `closed`,
  otherwise `open`) - the same rule `issues list`, `close` and `reopen` already use, which means
  a project with custom workflow status names needs no extra config. **Compatibility:** `state`
  is appended as field 3, so existing `cut -f1` / `cut -f2` readers are unaffected, but it is a
  documented-shape change and anything splitting the whole first line should be checked.

- **`promoting-a-branch` Step 3 gates deferrals and guards the no-user-surface hatch** (#195). The
  step gated on a test plan *existing*; nothing read the PR body for what it said it deliberately
  did **not** do, so a PR could ship a "known gaps" list, merge, close its issue, and leave the
  remainder tracked nowhere but a merged body. Step 3 now scans the assembled body for deferral
  shapes - semantically, so a bare `TODO:` counts as much as an `## Out of scope` heading - and
  halts unless each one names an `#N` verified open — and states plainly that an issue
  this PR resolves does not count, since it closes when the work reaches a closing stage and takes
  the note with it. The `- no user surface` escape hatch is likewise narrowed to an *inherently* absent surface
  (infra, migration, refactor); a surface that exists but could not be reached from the default
  seed is **obstructed**, and calls for the real plan, the precondition driven as a step in it, and
  a successor issue for the durable fixture. `promoting-branches` carries the same two guards in
  its batch `pr` path.

- **The repo's three floating CI images are pinned** (#167). `alpine:latest` → `alpine:3.22.6`
  (so the two Linux legs differ only in the interpreter), `cytopia/yamllint:latest` →
  `cytopia/yamllint:1`, and `koalaman/shellcheck-alpine:latest` → the same image by digest. A run
  of an unchanged commit could previously get a different toolchain than the run before it, which
  already cost a day when shellcheck's `latest` dev build gained SC2337 (#152). The dev build is
  pinned rather than the newest release, because release 0.11.0 predates SC2337 and pinning to it
  would drop CI's guard against the SIGPIPE pattern #152 fixed; the consequence — a contributor's
  distro shellcheck will not flag SC2337 locally — is recorded beside the pin. Dev-facing only;
  nothing a consuming repo sees.

- **The signature flight appends to issue, comment and PR bodies now starts with 🤖** (#183):
  `🤖 via FlightDirector:flight@<version> with <Model/ver>`, so agent-written text is recognisable
  at a glance. Re-signing still replaces rather than stacks: an `issues update` / `pr update` over
  a body signed in any earlier shape (bare, `via …`, or `🤖 via …`) ends with exactly one
  signature. `--no-signature` and `code.signature.enabled: false` are unchanged. Anything of yours
  that matches the signature text should allow for the prefix.

### Fixed

- **`queue-batches` no longer reads a parked zone as finished** (#207). The skill gave the
  orchestrator two triggers for "this zone is done": Section 4 waited for every zone to emit its
  terminal line, Section 5 started "when all agents return". An agent that returned *without* a
  terminal line fell between them, and the convenient reading summarized the batch and handed it
  to `promoting-branches` with work still owed. Section 5 now opens on the Section 4 condition,
  and Section 4 says what to do when an agent returns early: look for the zone's `ticket=all`
  line, treat its absence as unfinished regardless of what the agent reported, and check what is
  really running (the orchestrator's own log watcher shows up in that `ps` listing, so a match is
  not proof). The Claude Code mechanism (a job the worker backgrounded dies with the worker's
  shell, so the worker comes back "waiting" on nothing) is in `references/dispatch-claude.md`.
  Every one of these tests is keyed on the `ticket=all` marker rather than on the line being
  last, including the two that predate #207: with a `code.preflight` gate configured (#209) the
  orchestrator appends its own `preflight-pass` lines *after* the terminal line, so a positional
  reading would have called every finished zone unfinished and stalled the batch. The status-log
  contract now labels that line "the agent's last" and says to match on the marker.
- **`ci log` can now show why a PR's CI is red** (#138). Two faults meant the documented failure
  path of every `pr` hop — `ci log --failed "$BRANCH"` — found nothing on a repo whose workflows run
  on pull requests. (1) The branch lookup asked for runs under `refs/heads/<branch>`, but a run
  triggered by a pull-request event carries the PR ref, so it died with "no CI run found" straight
  after `ci watch --pr` had reported `status=failure`. It now falls back to the branch's head commit
  (Forgejo, and GitLab for merge-request pipelines; GitHub's branch filter already matched). (2)
  `ci log --sha` took the *latest* run on the commit; with one run per workflow started in the same
  second that was as often the green lint as the red tests, and it answered "(no failed jobs)" for
  a commit whose CI was red. `--sha` now dumps every failed run on the commit. New: **`ci log --pr
  N`**, resolving the head commit the way `ci watch --pr` does — the promotion skills now use it.
  All three code backends.

- **The prompt ledger no longer fills with unmeasurable subagent rows, and subagent output tokens
  are no longer undercounted** (#155, user-submitted). Two separate faults in the Claude Code
  producer. (1) Claude Code fires `SubagentStop` about every 30 seconds per running background
  agent for an internal helper that has no `agent_type` and never gets a transcript on disk; the
  hook wrote a null row for each, so a batch run showed "997 of 1,007 rows had no usage" while its
  ten real workers were in fact measured. Such a stop now writes no row, and `prompt-log summary`
  sets the rows older versions already logged aside as `helper_stop_rows` rather than counting
  them as unmeasured. (2) The per-request de-duplication kept the *first* content block of each
  request, but in a subagent transcript that block carries the streaming-start placeholder
  (`output_tokens: 8`) and only the last carries the real count — one worker's 33,686 output
  tokens were logged as 8,427. The producer now keeps the block with the most output tokens.
  Costs logged for subagents before this fix are therefore low on the output side. Also: a
  null-usage row now records why (`usage_missing`: `no-path` / `unreadable` / `no-usage`, both
  harnesses) and the summary names the causes instead of always saying "hook could not read the
  transcript"; and the parent-transcript fallback only counts the stopping agent's own entries.
  (3) Claude Code fires `SubagentStop` for a real agent several times — each time it parks on a
  background command or a child agent, and again after it hands its report back — and the ledger
  kept only the first, so a subagent's cost stopped counting at its first pause: 13–28% low in a
  measured capture, and far more for a worker that backgrounds a long CI watch early. Each stop
  now logs the usage beyond that agent's earlier rows (`part: 2`, `3`, … from the second row), so
  an agent's rows always sum to its transcript. Agents launched by other agents were already
  logged on their own; their rows now carry `parent_agent_id` and `spawn_depth`, and the summary
  note reads "N subagent row(s) from M agent(s)". Anything that sums ledger rows stays correct;
  anything that assumed one row per agent should count distinct `turn_id`s instead.

- **`ci watch` no longer reports a run where nothing executed as green** (#150). `skipped` used to
  be folded into the success side of the aggregate, so a workflow whose runs were all skipped (a
  path filter that matched nothing, a `needs:` whose dependency was skipped, a conditional that
  evaluated false) reported `status=success` and was indistinguishable, at the merge gate, from a
  run that verified everything. Skipped is now counted on its own axis in all three code backends
  (Forgejo, GitHub, GitLab): the line gained a `skipped=<s>` field, an all-skipped SHA verdicts as
  the new `status=skipped` rather than `success`, and a partial skip still passes but names how many
  runs did not run. `promoting-a-branch` and `promoting-branches` now handle that third verdict
  instead of treating not-failed as passed. This is the false-green counterpart to #43's false red.
  **Note for anything parsing the output line:** `status=` can now be `skipped`, and `skipped=<s>`
  sits between `failed=` and `status=`.

- **The Windows CI leg fails at the download when its `jq` fetch goes wrong** (#166). The job
  fetched `jq.exe` with `curl -sSL`; with no `-f`, an HTTP error page was saved as `jq.exe` and
  curl exited 0, so the leg died a line later on `jq.exe: line 1: <!DOCTYPE html>` — naming neither
  the download nor the reason. That is what failed the 0.15.1 release PR while the other three legs
  passed. Now `curl -fsSL` with `--retry 3 --retry-delay 5` (a transient 5xx no longer fails the
  leg at all; a genuine 404 still fails immediately), and the download is verified against the
  sha256 jq publishes for the pinned 1.7.1 asset before it is executed. Dev-facing only; nothing a
  consuming repo sees.

- **`cleaning-up-branches` now finds the `batch/*` branches `promoting-branches` leaves behind**
  (#168). A `pr`-hop batch promote opens a `batch/<group>-<short>` integration branch per group and
  nothing removes it afterwards, but `flight branches` only considered `feature/*`, `bugfix/*` and
  `release/*` — so the documented cleanup pass never saw them and they accumulated on origin.
  `batch/*` is now one of the built-in default patterns, and the places that state that list
  (`flight-setup.md`, `cleaning-up-branches`) agree again. A `batch/*` branch carries no issue
  number, so it is reported as "no cross-check was possible" rather than silently trusted.
  `promoting-branches` still does not delete the branch itself, and now says so. Also documented
  explicitly: a configured `code.branches.patterns` **replaces** the defaults outright rather than
  adding to them.

- **Every interpolated value in the `pr`, `ci` and `labels` adapters is URL-encoded** (#169).
  Branch names, label names, usernames and states are caller input that ends up in a query string.
  Unencoded, a space made curl refuse the whole request ("Malformed input to a URL function"), and
  a `#` was worse: the request succeeded with everything after it cut off as a fragment, so a PR or
  CI-log lookup silently matched nothing. Now encoded: `pr list --head/--base` (GitHub, GitLab),
  `ci log --failed` (all three), and `issues assign --user` (GitLab). Delimiters are assembled
  around the encoded value rather than through it — Forgejo's `refs/heads/` prefix and GitHub's
  `owner:ref` colon stay literal — so a branch with no special character sends exactly the URL it
  always did. The encoder now lives once in `_portable.sh`.

- **`lint.sh` rejects an unknown filter instead of silently linting nothing** (#170). The filter was
  matched against `all`, `yaml` and `shell`, and when it matched none the script simply ran no
  check — so `lint.sh yml`, or any typo, printed `Passed: 0  Failed: 0` and exited 0, green having
  linted nothing. That is the trap #135 closed for a missing linter, arriving by a different door.
  The filter is now validated before any linter runs: an unrecognised value names itself and the
  accepted values on stderr and exits 2. The `Passed: N  Failed: N` summary contract (#123, #135)
  is untouched for every accepted filter. Dev-facing only; nothing a consuming repo sees.

- **`ci watch` no longer reports a healthy run as a hang just because it sat in a queue** (#171).
  The watcher counted every second since it started against `code.ciWatchTimeout` (default 900),
  which on a repo with one runner per platform is mostly queue time: a run that took 19m29s wall
  clock with almost all of it waiting for a runner had its watcher die at 900s calling it a hang.
  There are now two clocks. **`--timeout` / `code.ciWatchTimeout` changed meaning**: it bounds how
  long a run may *execute*, not how long the watch may last. Time in which every job of every
  non-terminal run is waiting for a runner is bounded separately by the new **`--queue-timeout` /
  `LS_CI_QUEUE_TIMEOUT` / `code.ciQueueTimeout`** (default 3600; `0` disables either cap, as
  before). Each message names which cap fired and the key that raises it. Because every backend
  marks a run running as soon as *any* job starts, a run that looks like it is executing is
  confirmed against its own job list first; anything unreadable counts as executing, so a blip can
  only ever leave the shorter cap in charge. "No run found at all" is a trigger or push problem,
  not a queue, and stays bounded by `--timeout` as it was.

- **`auth check` now says which source the token came from** (#177, #196). Token resolution is
  env-first (`LS_TOKEN` → `FLIGHT_TOKEN` → the legacy `FORGEJO_TOKEN`, then the secrets file) and
  never said so, so a token exported for a *different* forge — the classic stale `FORGEJO_TOKEN`
  in a shell profile — produced a flat `HTTP 401` with `.flightdirector/secrets.json` as the
  obvious, and wrong, suspect. The resolution order is unchanged; the silence is what was fixed.
  The `authenticates` line now reads `token 024ffe8f… (from $FORGEJO_TOKEN)` or
  `(from /path/to/repo/.flightdirector/secrets.json)` on every backend, and the *failing* branch
  carries the same detail as a hint where it previously printed no token at all. Separately, the
  legacy `FORGEJO_TOKEN` shadowing a present secrets file that holds a different token now gets a
  one-line note on stderr; `LS_TOKEN` and `FLIGHT_TOKEN` are deliberate backend-neutral
  overrides and stay quiet. Adapters get the source as `LS_TOKEN_SOURCE` in the environment.
  The secrets file is named by its **full path**, not the repo-relative form (#196): it is
  gitignored, so it lives only in the main checkout, and a repo-relative name printed in a linked
  worktree — where most work happens — points at nothing you can open. The shadow note on stderr
  uses the same full path. The tracked-by-git warning keeps the repo-relative form on purpose: a
  tracked file *is* checked out in every worktree, and that is the form you would add to
  `.gitignore`, which is what the warning asks you to do. `flight-setup.md`'s token-precedence
  section now points at `auth check` as the way to see which source won, and documents the
  legacy-shadow note.

## [0.15.1] - 2026-09-19

### Fixed

- **`list` verbs no longer truncate silently at the server's cap** (#149). Every backend clamps a
  list request to its own maximum and says so only in a header, so a single request per verb was
  silently cut short: `issues list --limit 200` against a 109-issue tracker returned 50 rows and
  looked complete. All four adapters now page underneath `--limit`, stopping only when a page
  comes back **empty** (or, on Jira, when `nextPageToken`/`startAt` says the collection is
  exhausted) rather than when a page looks short, since a short page and a clamped one are
  indistinguishable. `--limit N` remains a true ceiling of N rows, and when the ceiling hid
  something the adapter now warns on **stderr** naming the count where the backend reports one
  (`warning: showing 50 of 109 rows for /issues; raise --limit to see the rest`). stdout stays
  clean TSV. This makes the mitigation the skills already described real: "raise `--limit` if a
  full page came back" could never work, because at the cap a full page always comes back.

  Affected verbs: `issues list`, `pr list`, `labels list` (now through the same paged cache label
  resolution uses, so the two can no longer disagree about which labels exist), and `issues
  comments` on GitHub, GitLab and Jira — those render oldest-first, so an unpaged fetch dropped
  the **newest** comments, which is precisely what "the later comment wins" depends on. Forgejo's
  comment endpoint ignores paging and returns the whole thread, so it is unchanged.

- **`issues list --label` works for label names with a space** (#140). The Forgejo and GitLab
  adapters put the `--label` value into the query string raw, so any label with a space, which
  is every default status label (`status/to test`, `status/in progress`), made curl refuse the
  URL (`Malformed input to a URL function`) and the list fail. That broke the board cross-check
  `cleaning-up-branches` documents. Every value interpolated into an `issues list` URL is now
  percent-encoded on Forgejo, GitLab and GitHub (GitHub already encoded labels; its `--state`
  now is too). Several labels are encoded one by one and then comma-joined, so the separator
  survives. Jira is unchanged: its JQL travels in the request body and was already quoted.

## [0.15.0] - 2026-09-17

### Added

- **Every body flight writes is signed** (#132). Issue bodies, comments (so every work-ledger
  entry) and PR bodies (promotions and sync-down PRs alike) now end with a `---` rule and
  `via FlightDirector:flight@<version> with <Model/ver>` — the model clause when the skill passed
  the new dispatcher-owned `--model <id>` flag (or `FLIGHT_MODEL` is set), omitted otherwise.
  Done once in the dispatcher for all four backends; adapters are unchanged, except that the
  Jira ADF shim now renders a `---` line as a rule. An update replaces an existing signature
  rather than stacking one. Opt out per repo with `code.signature.enabled: false`, or per call
  with `--no-signature`.

- **Windows is a supported platform** (#130, via Git Bash / MSYS). A new `flight/scripts/_portable.sh`
  shim, sourced by the dispatcher, `branches`, `sync-down`, `batch-manifest` and every adapter, is a
  no-op off Windows and on it (a) wraps `jq` so a native `jq.exe` (what winget, scoop and choco
  install) no longer leaks `\r` into every comparison, and (b) normalises path form with `cygpath`
  so `branches prune` recognises `.worktrees/` entries whether git says `C:/…` or bash says
  `/c/…` (case-insensitively). The prompt ledger's append lock falls back to `msvcrt` where
  `fcntl` does not exist. Extensionless scripts (the dispatcher, adapters, `bin/*`, hooks) are
  pinned to LF in `.gitattributes` so a Windows checkout no longer dies at `env: bash\r`. If
  `sort -u` fails oddly in Git Bash, put `/usr/bin` ahead of `System32` on `PATH`.

- **Every PR is now tested on four platforms.** The `tests` workflow runs bash 5 (Alpine), bash
  3.2.57 (the interpreter macOS ships), macOS itself (BSD userland) and Windows (MSYS); all four
  block. So "works on my Linux box" no longer ships a plugin that dies on a stock Mac or a
  Windows checkout (#127, #130).

- **Per-machine config override** (#129). An optional, gitignored
  `.flightdirector/config.local.json` is now merged over `config.json` for every read, with
  jq's recursive-merge rules: nested objects merge key by key, scalars and arrays replace
  wholesale. Use it for a fork's `owner`, a self-hosted `api`, `promptLog.enabled`, or a
  `ciWatchTimeout` without touching the committed file. `flight reconcile` keeps writing the
  tracked `config.json` only. An invalid local file is an error; a git-tracked one warns on
  every run. `setting-up-a-repo` now lists it among the paths to gitignore.

### Changed

- **Summary lines in the repo's own tests and checks are consistent** (#123). Every counter-based
  `scripts/tests/*.test.sh` and `scripts/checks/lint.sh` ends with the same `Passed: N  Failed: N`
  line — plain when nothing failed, red otherwise — and every per-check ✓/✗ is green/red.
  Dev-facing only; nothing a consuming repo sees.

### Fixed

- **`flight branches` and `flight branches sync-down` now run on macOS** (#127). Both used
  `mapfile` and `declare -A`, which are bash 4 builtins; macOS ships bash 3.2 and nothing newer,
  so on a stock Mac each died before doing any work. That took `cleaning-up-branches` and
  `promoting-a-branch`'s sync-down step (0.14.0) with it, and made the README's "Nothing to
  install or run" untrue for every macOS user. Both scripts now use `while IFS= read -r` and
  newline-delimited branch-keyed containers, which behave identically on bash 3.2 and bash 5.

- **`flight branches prune` no longer skips every worktree on a symlinked repo path** (#127).
  The `.worktrees/` check compared `git worktree list`'s resolved path against an unresolved
  repo root, so under macOS's `/var` and `/tmp` (both symlinks into `/private`) no worktree ever
  matched and `prune` reported each one as "checked out elsewhere". The root is now resolved
  with `pwd -P` before the comparison.

## [0.14.0] - 2026-09-15

### Added

- **Sync-down after a promotion** (#120, [ADR 0002](../docs/adr/0002-sync-down-after-promotion.md)).
  After a stage-to-stage hop lands (`develop → qa`, `qa → main`), `promoting-a-branch` now runs
  the new `flight branches sync-down --from <stage>` verb, which merges the target back into the
  source and cascades to `stages[0]` so every lower stage stays level — fast-forward when
  possible, one true merge commit otherwise, never a squash or a reset. A new optional per-stage
  `syncDown` field (`direct` | `pr` | `none`) says how a stage receives that back-merge and
  **defaults to the stage's own `merge`**, so existing configs need no change; `none` opts a
  stage out and stops the cascade. `pr` mode opens a `<upper> → <lower>` PR, watches CI, and
  auto-merges on green with the `merge` method. Ahead/diverged lower stages, conflicts, and red
  CI stop the cascade with a `stopped` row and a non-zero exit. Feature hops and
  `promoting-branches` are unaffected.

### Fixed

- **`flight auth check` no longer fails on the recommended Forgejo token** (#117). A token
  restricted to one repository cannot carry `read:user` (Forgejo won't mint that combination), so
  the identity probe always answered 403 and the verb exited non-zero on a fully capable token.
  A scope-limited 403 alongside a passing repository probe is now an informational line; a 401,
  or a 403 with the repository probe failing too, still fails.

### Changed

- **`flight prompt-log summary`** (#121) — the rendered work-ledger table no longer lists
  `unknown`-model rows that cost nothing (hook-only / synthetic turns with no model recorded);
  their turn count stays in the **Total** line and a note says how many were omitted. An
  `unknown` row that carries tokens but no price is still shown with its `(+N unpriced)`
  marker, and `--json` output is unchanged.

## [0.13.0] - 2026-09-08

### Added

- **`flight labels delete --name NAME [--force]`** (#111) — remove a label from the repo
  through the dispatcher, the repo-level counterpart of `issues label-remove`. Safe by default:
  it refuses while the label is still on any issue or PR/MR, open or closed, and says how many;
  `--force` deletes it anyway. Unknown names error. Forgejo, GitHub, GitLab; Jira has no
  repo-level label object and says so.
- **`flight issues label-remove --number N --label NAME`** (#63) — the exact mirror of
  `label-add`, for taking a label back off an issue (repeatable `--label`). Implemented for
  every backend (Forgejo, GitHub, GitLab, Jira). An unknown label name is an error, the same
  as `label-add`, but removing a label the issue isn't carrying succeeds silently, so the verb
  is safe to run unconditionally.
- **`flight pr update` and `flight pr get`** (#104). `pr update --number N [--title T]
  [--body B | --body-file PATH]` patches an already-open PR — only the fields you pass, so a
  title fix leaves the body alone — and `pr get --number N` reads one back as
  `number⇥title⇥state⇥url`. A typo or a late test-plan edit in a PR body no longer has to be
  fixed by hand in the web UI. Forgejo, GitHub and GitLab; `promoting-a-branch` Step 4 points
  at it.
- **`flight auth check` — verify a token before you rely on it** (#81). A read-only verb that
  reports, one `✓`/`✗` line per check: the identity the backend sees, whether the repo/project
  in `config.json` is reachable, one probe per capability the skills need (issues, labels,
  PRs/MRs, CI), and the token's expiry where the backend exposes it — exiting non-zero if
  anything fails. Failures carry the backend's own wording, so GitLab names the missing
  fine-grained permission and Jira names the project permission the account lacks. Write access
  is reported "not tested" (probing it would have side effects) and the token is never printed
  beyond its first 8 characters. `--axis code|issues` picks the axis; `--secrets <file>` checks
  a **candidate** token file, so rotation is: create token → check → move into place. All four
  backends; `setting-up-a-repo` Step 2 now runs it right after writing the secrets file.
- **A `cleaning-up-branches` skill, plus `flight branches list|prune`** (#90). Nothing in flight
  ever deleted a branch — `working-an-issue` and `promoting-branches` remove the *worktree*, so
  every worked issue left its `feature/<N>-<slug>` on origin and usually a local ref too, until
  the branch list stopped describing what was in flight. The new skill finds the branches whose
  work has already landed in a stage (tip is an ancestor of the stage, **or** the backend reports
  a merged PR whose head was that branch — which is the only way to see a squash/rebase merge),
  cross-checks each against its issue's status so a half-run promotion is flagged rather than
  swept away, and deletes the local ref, the remote ref, and the leftover `.worktrees/` entry
  behind a preview and an explicit go-ahead. Deleting is `git branch -d` (never `-D`) and
  `git worktree remove` (never `--force`); `prune` writes nothing unless one of `--local`,
  `--remote`, `--worktrees` says so, and remote deletion is a separate yes every time. Stage
  branches, `archived/*`, and anything checked out outside `.worktrees/` are protected regardless
  of configuration. Candidate patterns come from the new optional `code.branches.patterns`
  (default `["feature/*","bugfix/*","release/*"]`). Adds the `pr list --state
  open|closed|merged|all [--head] [--base] [--limit]` verb on forgejo/github/gitlab that the
  squash-merge detection needs.

### Changed

- **The prompt ledger moved to `.flightdirector/prompt-log.jsonl`** (#107). The root-level
  `prompt_log.jsonl` name was generic enough for another tool to pick independently, and two
  producers appending to one file corrupts both ledgers. Producers, `flight prompt-log summary`,
  and the docs now use the namespaced path; `setting-up-a-repo` gitignores the new path and no
  longer adds the old one. **No migration:** an existing root `prompt_log.jsonl` is neither read
  nor moved — delete it by hand, and drop its `.gitignore` line if you want leftovers to show.
- **`setting-up-a-repo` no longer advises removing a user's own prompt-logger hook** when the
  ledger is enabled. Flight's hooks are plugin-bundled and write only their own file, so other
  prompt hooks coexist; the skill must never edit, disable, or advise deleting hooks in the
  user's settings files (`references/prompt-log.md`).
- **`setting-up-a-repo` re-runs ask only the unanswered questions** (#108). Reusing an existing
  config used to jump straight to the label reconcile, so a repo set up before an option existed
  (the prompt ledger, for one) was never offered it. Now each setup question maps to a config
  key: present — any value, `false` included — means answered and skipped; absent means asked.
  Every answer is written back, including "no" (`"promptLog": { "enabled": false }`), so a
  declined option is remembered rather than re-asked (`references/flight-setup.md`).
- **The `git -C` rule is now one of the workflow red lines** `setting-up-a-repo` writes into
  a repo's `AGENTS.md` (#93, follow-up to #65). The skills already modelled `git -C <path>`;
  spelling it out in the committed instructions means it holds for any agent session in the
  repo, not just one that has a flight skill loaded. Existing repos: add the bullet by hand,
  or re-run the skill.

## [0.12.0] - 2026-09-07

### Added

- **A bundled, harness-neutral prompt ledger** (#46; Codex producer in #83). Opt in with
  `code.promptLog.enabled: true` and the plugin's bundled hooks append one record per agent turn
  — prompt, model, tokens, estimated cost, cost basis — to a gitignored `prompt_log.jsonl` at
  the main worktree root, from **Claude Code and Codex alike, into the same file with the same
  schema** (`references/prompt-log.md`). The Claude producer sums a turn's requests once each
  (Claude Code writes one transcript entry per content block), logs subagent turns under the
  parent session, and prices per model from one shared `pricing.json` that a repo can extend
  with `.flightdirector/pricing.json`. New dispatcher route `flight prompt-log
  <prompt|stop|interrupt|subagent-stop|summary>`; `summary --session <id>` renders the
  per-harness × model totals the work-ledger comment pastes in, saying "estimate only" only
  when a session has no rows. Missing usage or an unknown model is `null` plus a stderr warning,
  never a silent zero. `working-an-issue`, the `queue-batches` worker prompt, and
  `setting-up-a-repo` (which now offers the switch) are updated. Absorbs #60 and #61.

- **Codex can now write measured per-turn and delegated usage to the shared prompt ledger**
  (#83). Plugin-bundled hooks capture prompts, completed or interrupted turn usage, and
  subagent usage through the shared `flight prompt-log` route. Records are scoped to the exact
  Codex turn and distinguish API-key cost from ChatGPT subscription API-equivalent cost. The
  shared table includes official Standard short-context prices for current Codex model families;
  missing pricing remains explicit as null fields with a visible warning.

### Changed

- **Fresh configs spell out each `pr` hop's merge strategy** (#96). `setting-up-a-repo` now writes
  `"strategy": "merge"` on every `pr` stage in the pipeline presets it offers (and explains the
  field alongside `merge` and `gate`), so a new repo's `.flightdirector/config.json` is
  self-describing instead of relying on the documented default. Behaviour is unchanged — `merge`
  was already the default, and the field applies to `pr` hops only.
- **The AGENTS.md breadcrumb no longer names the backend host** (#101). `setting-up-a-repo` Step 9
  writes the backend *name* and points at `.flightdirector/config.json` for the host and
  coordinates, so a repo with a public mirror doesn't publish a private forge's hostname; the host
  is spelled out only if the user asks. Setup also offers a gitignored **`AGENTS.local.md`** for
  private notes, pulled in by a nested `@AGENTS.local.md` import for Claude Code and a one-line
  read-this-file instruction for Codex, so both harnesses see it and public clones lose nothing.

- **Model provenance labels are now derived deterministically by the dispatcher** (#85).
  `flight labels model-family --id <id>` recognizes GPT/Claude codenames and vendor prefixes,
  while `labels ensure --model <id>` creates the standard `model/<family>` label metadata.
  Common OpenAI families (Sol, Terra, Luna, Astra) are seeded during setup, finishing skills call
  the helper instead of interpreting model ids in prose, and `labels edit` provides an
  association-preserving rename path on Forgejo, GitHub, and GitLab (Jira labels remain free text).

- **The docs no longer frame flight as a tool for a self-hosted Forgejo instance** (#99). The
  User Guide, both READMEs, and the config reference now lead with the backend contract —
  Forgejo/Gitea, GitHub, and GitLab at full parity, Jira for the issues axis — with per-backend
  prerequisites and least-privilege token tables that link to `references/backends.md` as the
  single maintained list. The config reference's GitHub section no longer claims
  `setting-up-a-repo` can't offer GitHub (it detects a `github.com` remote). The dispatcher also
  accepts a backend-neutral **`FLIGHT_TOKEN`** environment override alongside `LS_TOKEN`;
  `FORGEJO_TOKEN` keeps working as the legacy name.

- **The reconcile stamp is now scoped per plugin, not just per harness** (#88): schema version 2
  records `harnesses.<harness>.plugins.<plugin>.reconciledWith` instead of a bare
  `harnesses.<harness>.reconciledWith`. `.flightdirector/` is shared by every Flight Director
  plugin, so the old single key would have had future plugins overwriting each other's stamp and
  comparing their version against another plugin's in the downgrade guard. Existing configs
  migrate themselves on the next `flight reconcile` (the old key moves to `plugins.flight` and is
  removed) — no manual step.

- **Reading an issue's comments on pickup is now an explicit requirement** (#82): a red flag in
  `working-an-issue` ("the later comment wins"), a required first step in the `queue-batches`
  worker prompt (workers previously never fetched comments), and `promoting-a-branch` /
  `promoting-branches` read comments before drafting test plans.
- **`git -C <path>` is now the modelled form for every git command in the skills** (#65):
  `working-an-issue`, `promoting-a-branch`, `promoting-branches` and the `queue-batches` worker
  prompt bind the relevant checkout path once (`$WT` / `$ROOT` / `$MAIN`) and anchor every git
  invocation to it, with a compaction-proof red flag — a bare `git` command is a bug — so an
  agent that has `cd`'d elsewhere can no longer commit to the wrong repo or branch. The
  guidance also notes that `git -C "$WT" add <path>` resolves `<path>` relative to `$WT`.
- **Feature worktrees now start from an up-to-date `stages[0]`** (#84): `working-an-issue`
  Step 1, the `queue-batches` worker prompt, and `promoting-branches`' integration worktree all
  fetch `origin/<stages[0]>` and compare before `worktree add` — level → proceed, behind →
  fast-forward or fork from the origin tip (and say so), ahead/diverged → **STOP** rather than
  `git pull`. Offline or with no remote, work continues from the local ref but the base is
  reported as **unverified**, and the pickup line states the base's freshness either way.
- **Promotions now check upstream freshness before merging or pushing** (#66):
  `promoting-a-branch` gained a Step 4a that fetches `origin/<target>` (and re-affirms the
  source branch on a `direct` hop) and classifies the target as up-to-date / behind / ahead /
  diverged — behind fast-forwards and says so, ahead or diverged **stops and reports** rather
  than reconciling. Its Case 2 throwaway worktree now forks from `origin/<target>` so a stale
  local ref can't be the merge base. `promoting-branches` runs the same check before its first
  merge and again immediately before the single end-of-run push. Both skills say explicitly:
  do not reflexively `git pull` a diverged stage branch.
- **The per-stage `strategy` knob is now documented in the config reference and read, not
  hard-coded, by `promoting-a-branch`** (#64). `code.stages[i].strategy` is `merge` | `squash` |
  `rebase` and **defaults to `merge`** — a true merge keeps the same commits travelling
  `feature → develop → qa → main`, which is what Flight's one-branch-per-issue pipeline expects.
  `promoting-a-branch` Step 1 now resolves `$STRATEGY` from the target stage and Step 4 merges
  with it; its worked example changed from `--strategy squash` to the resolved value. The knob
  applies to `pr` hops only — a `direct` hop always merges `--no-ff`.

### Fixed

- **`flight prompt-log summary` now names models it couldn't price and says how to fix it** (#60).
  Rows for a model missing from the pricing table were already kept (tokens recorded, cost
  `null`) and marked `(+N unpriced)`, but the note that lands in the work-ledger comment now
  names the model(s) and points at `.flightdirector/pricing.json`; the JSON aggregate gains
  `unpriced_models`. Hook-time stderr warnings aren't reliably visible in a session, so the
  summary is where the user actually learns about the gap.

- **Batch manifests now drain after a promote** (#98). `promoting-branches` consumed the run
  manifest with `batch-manifest heal --live "<issues still at to-test>"`, but in a pipeline whose
  `stages[0].issueStatus` is itself `to-test` (the default multi-stage preset) a promoted issue
  is *still* labelled to-test, so nothing was ever removed and "promote each zone" kept offering
  finished runs. New `batch-manifest consume --issues "<promoted>"` removes exactly the promoted
  issues; `heal --live` stays for the self-heal case (branches/worktrees that vanished). The
  `queue-batches` preflight now treats a manifest whose issues have no worktrees as stale rather
  than in-flight.

### Security

- **`setting-up-a-repo` now gitignores the whole `.flightdirector/secrets*` family** (#80), not just
  `secrets.json`, so a second token file or a backup made while rotating a token (`secrets.local.json`,
  `secrets.json.bak`, `secrets-github.json`, editor swap copies) can't be committed either.

## [0.11.0] - 2026-09-06

### Changed

- **Renamed the plugin from `lightspeed` to `flight`**, the first member of the **Flight Director**
  plugin family (#67). In NASA comms the flight director's callsign is "Flight", so the family
  is the title and this plugin is the callsign. The rename covers both harness manifests
  (Claude Code and Codex), so install `flight@flightdirector` (Claude Code) or install *Flight*
  from `/plugins` (Codex). Skills are now namespaced `flight:<skill>`.
- **Marketplace and publisher renamed** (#68): the marketplace is now **`flightdirector`** (was
  `cerebralgardens`) and the publisher is **AI Crafting** (was Cerebral Gardens). A marketplace's
  name comes from its manifest, so existing consumers must `claude plugin marketplace remove
  cerebralgardens`, re-add the repo, and reinstall as `flight@flightdirector`.
- The dispatcher is now **`flight <group> <verb>`**. The plugin ships `bin/flight`.
- Manifests now declare `"license": "MIT"` (#71), mirroring the repo's `LICENSE`.
- Install docs (README, GUIDE) now use the public marketplace URL
  `https://github.com/AICrafting/FlightDirector.git` and give Codex the same step-by-step
  install as Claude Code (`codex plugin marketplace add …`, `codex plugin add flight@flightdirector`) (#74).
- The per-repo config folder is now **`.flightdirector/`** (`config.json` + gitignored
  `secrets.json`, plus `batches/`), shared by every Flight Director plugin.
- `setting-up-a-repo` writes the `.flightdirector/` layout, offers to migrate a legacy
  `.lightspeed/` folder, and writes an "Issue tracking — flight" breadcrumb (replacing an older
  "— lightspeed" one in place).
- **The breadcrumb now targets `AGENTS.md`** (#70): `setting-up-a-repo` Step 9 puts the block in
  `AGENTS.md` — which Codex discovers natively — and has `CLAUDE.md` import it with `@AGENTS.md`,
  so both harnesses read one source. Repos with only a `CLAUDE.md` are offered the split (or can
  keep a single file). Symlinking `CLAUDE.md` to `AGENTS.md` is deliberately not suggested.
- `references/lightspeed-setup.md` is now `references/flight-setup.md`.
- Test-rig environment variables are `FLIGHT_*` (the `LIGHTSPEED_*` names still work).

### Deprecated

- The **`lightspeed`** PATH entrypoint still delegates to `flight` but prints a deprecation
  notice; it will be removed in a future release.
- A legacy **`.lightspeed/`** config folder is still read (with a one-line notice on stderr) when
  `.flightdirector/config.json` is absent; config and secrets resolve independently so a
  half-migrated repo keeps working. Migrate with `git mv .lightspeed .flightdirector` (and move the
  gitignored `secrets.json`), or re-run `setting-up-a-repo`.

### Migration

1. Reinstall: `/plugin uninstall lightspeed@cerebralgardens` then `/plugin install flight@cerebralgardens`
   (Codex: reinstall from `/plugins`).
2. In each configured repo: `git mv .lightspeed .flightdirector` (secrets.json is untracked —
   `mv` it by hand), add `.flightdirector/secrets.json` and `.flightdirector/batches/` to
   `.gitignore`, and update the CLAUDE.md breadcrumb (`lightspeed` → `flight`) — or just re-run
   `setting-up-a-repo`, which does all of this.

## [0.10.0] - 2026-09-04

### Added

- Codex plugin packaging and runtime guidance, sharing the existing skills, dispatcher, adapters,
  configuration, and references with Claude Code.
- Per-harness config reconciliation metadata through `lightspeed reconcile --harness …`.
- Idempotent `labels ensure`, used to create new `model/*` provenance labels lazily when a ledger
  is finalized, so newly released model families do not require a Lightspeed release.

### Changed

- `queue-batches` now keeps shared workflow policy separate from Claude Code and Codex dispatch
  primitives.

## [0.9.0] - 2026-08-05

### Fixed

- `working-an-issue` no longer creates an issue's worktree nested inside the
  *previous* issue's worktree (#57). The worktree path was relative and guarded
  only by a "run this from the repo root" comment, so a shell whose working
  directory had persisted from an earlier `cd` resolved `.worktrees/<N>-<slug>`
  against the worktree it was already in — and git permits nested worktrees
  without warning, so it failed silently. Worktree `add`/`remove` are now
  anchored to the main repo root (`git -C "$ROOT"`, resolved from the common git
  dir), matching what `queue-batches` and the dispatcher already did.
- `promoting-a-branch` anchors its throwaway promote worktree's `add`/`remove` to
  `$MAIN` (#57) — already resolved a few lines above, but unused there. Latent
  rather than user-visible, since the worktree path itself was absolute.

### Added

- `test-rig/smoke-worktree-anchor.sh` — a backend-free regression test (no
  container, no token, runs anywhere). It reproduces the nesting failure, then
  greps the anchoring idiom out of `working-an-issue/SKILL.md` and proves it
  defeats the failure — so the test fails if the shipped snippet drifts.

## [0.8.0] - 2026-08-02

### Added

- `issues assign --number N --user LOGIN` (repeatable) and `issues unassign --number N`
  verbs on all four backends (#52). Assign **replaces** the assignee set. Forgejo/GitHub
  take logins as-is; GitLab resolves login → id via the instance `/users` lookup; Jira
  resolves email/display name → accountId and enforces its single-assignee model.
- `ci log` on Forgejo now fetches real logs (#54): the run is resolved via Forgejo 16's
  `/actions/runs` API and each failed job's plaintext log is dumped from
  `/actions/jobs/{id}/logs` — no more "open the web UI" pointer, no host access needed.
- `setting-up-a-repo` finishes by writing an "Issue tracking — lightspeed" breadcrumb
  into the repo's `CLAUDE.md` (#50) — backend + host + dispatcher pointers, plus workflow
  red lines that survive model switches and context compaction (#51). Existing repos can
  retrofit it with "add the lightspeed breadcrumb" (jumps straight to that step).

### Fixed

- `ci watch` on Forgejo sees runs still in `waiting` state (#53): it now polls
  `/actions/runs` (runs exist the moment they're created) instead of `/actions/tasks`
  (entries only appear once a runner picks the job up). Short `--sha` prefixes keep
  working on both `watch` and `log`.
- `ci watch` no longer counts superseded runs as failures (#43): only the latest
  attempt per (workflow, trigger event) is scored, and a newest manual re-dispatch
  (GitLab: `web` pipeline) supersedes that workflow's earlier runs — a retried-to-green
  flake now watches green, matching the providers' own UIs.

## [0.7.1] - 2026-07-09

### Fixed

- Skills now invoke the dispatcher as a bare `lightspeed` (and `batch-manifest`)
  command instead of `"$CLAUDE_PLUGIN_ROOT/scripts/lightspeed"`. `CLAUDE_PLUGIN_ROOT`
  is **not** exported to the Bash tool (only to hook/MCP/LSP/monitor subprocesses),
  so in real projects every dispatcher call failed with `exit 127`
  (`/scripts/lightspeed: no such file`). The plugin now ships `bin/lightspeed` and
  `bin/batch-manifest` entrypoints; Claude Code adds a plugin's `bin/` to the Bash
  tool `PATH`, so the bare command resolves reliably in any project. No config or
  setup change is required.

## [0.7.0] - 2026-07-03

### Added
- **Supported-backends reference** ([`references/backends.md`](references/backends.md)) covering all
  four backends — forgejo, github, gitlab, jira — each with a worked `.lightspeed/config.json`
  fragment, the provider's token-creation URL, and the **minimum** scopes/permissions the adapter
  actually needs (Forgejo `write:repository`+`write:issue`; GitHub fine-grained Contents/Issues/Pull
  requests + Actions-read for CI; GitLab `api`; Jira via the account's project role, since classic
  API tokens are unscoped). Linked from the guide.
- **`setting-up-a-repo` now detects existing backends and offers a confirm-and-go setup.** Before
  the manual prompts, the skill infers the `code` backend from the git remote host
  (github.com→github, GitLab→gitlab, Forgejo/Gitea→forgejo), reuses an existing
  `.lightspeed/config.json`, and reads Jira project keys (`ABC-123`) in commits/branches as a
  signal to pair a `jira` issues-axis backend — presenting the detected config for one-shot
  confirmation, and falling back to the existing manual flow when detection is inconclusive.
- **GitLab backend adapter** (`backend: "gitlab"`) at full parity with forgejo/github —
  `issues`, `labels`, `pr` (merge requests), and `ci` (pipelines). Point an axis at GitLab with
  `backend`/`owner`/`repo`/`api` (`https://gitlab.com/api/v4`) and a `PRIVATE-TOKEN`-scoped token
  in secrets. `pr merge --strategy squash` maps to GitLab's squash merge; `ci watch` aggregates
  all pipelines for a SHA and `ci log` pulls the failed job traces. See the adapter contract's
  "GitLab backend specifics" and the setup reference's "GitLab backend" section for the details
  (project-path addressing, issue `iid`s, scoped-status labels, async MR mergeability).
- **Jira backend adapter (issues-axis-only).** You can now point the `issues`
  axis at Jira Cloud (`issues.backend = "jira"`) while a git `code` backend keeps
  handling `pr`/`ci`. Implements `issues` + `labels` against Jira Cloud REST v3
  with HTTP Basic `email:api_token` auth. Config takes `issues.project` (the
  project key) and `issues.email`; the token goes in `issues.token`. Notable
  behaviours: the `--number` is a Jira **key** (`KAN-123`); `set-status` maps to
  `status/*` **labels** (which on Jira must be space-free single tokens);
  `close`/`reopen` drive real workflow **transitions** (Done ⇄ To-Do); issue
  bodies and comments round-trip through a minimal markdown⇄ADF shim; Jira labels
  are thin (no colour/description, name is its own id). See the setup reference
  and `adapter-contract.md` → *Jira backend specifics*.

## [0.6.0] - 2026-07-02

### Fixed
- **`ci watch` no longer hangs on an unpushed commit.** Promotions now watch CI
  by `--pr <n>` (the adapter resolves the PR's head SHA — the exact commit the
  run reports) instead of the local `git rev-parse HEAD`. Previously, if your
  local branch tip was ahead of what was pushed, the watcher polled forever for
  a SHA that had no CI run. As a backstop, `ci watch` now takes a `--timeout`
  and exits non-zero with a clear message rather than polling indefinitely.
  `promoting-a-branch` also now stops before opening a PR if local `$BRANCH` is
  ahead of `origin/$BRANCH`, so a promotion can't silently ship a PR that omits
  your latest commit.

### Changed
- **`ci watch` now aggregates *all* CI runs for a commit**, not just one. If a
  PR triggers several workflows, it stays watching until none are pending and
  reports `failure` if any run failed (previously it latched onto a single run
  and could announce success while another was still running or had failed). The
  output line is now `ci runs=<n> pending=<p> failed=<f> status=<…>`.
- **`setting-up-a-repo`** now also gitignores `.lightspeed/batches/` (the per-run
  batch manifests `queue-batches` writes) alongside `.lightspeed/secrets.json`
  and `.worktrees/`, so batch state isn't accidentally committed.
- **`setting-up-a-repo`** notes the optional Forgejo label-exclusivity guard
  (set `status/*` exclusive, `model/*` non-exclusive) — lightspeed doesn't need
  it (`set-status` already enforces one status), so it's left to preference.

### Added
- **`code.ciWatchTimeout`** config field sets the `ci watch` hang-guard timeout
  in seconds (default `900`; `0` disables). Precedence: `--timeout` flag →
  `LS_CI_WATCH_TIMEOUT` env → `code.ciWatchTimeout` → default.
- **`references/example-flows.md`** — worked promotion pipelines at 1/2/3/4 hops
  with contrasting `direct`/`pr`, merge-strategy, and issue-status setups, plus
  how batch-promote differs by first-hop strategy. Linked from `GUIDE.md`.

## [0.5.0] - 2026-07-02

### Added
- **`promoting-branches` skill** — batch-promote several first-hop feature
  branches at once ("promote each zone", "promote the first zone", "promote
  issues 18, 93, 12", "promote all to-test"), honoring the first hop's merge
  strategy (direct → N merges; pr → one PR per group). Complements
  `queue-batches`, which now hands the batch off to it instead of prompting for
  serial `promoting-a-branch` runs.

### Changed
- **`queue-batches`** writes a per-run issue→zone manifest at dispatch (under a
  gitignored `.lightspeed/batches/`) so `promoting-branches` can honor "promote
  each zone", and its completion hand-off now points at `promoting-branches`.

## [0.4.0] - 2026-06-30

### Added
- `issues comments --number N` read verb on the dispatcher (Forgejo + GitHub) —
  fetches an issue's comments (`author⇥timestamp` header + body per comment), so
  discussion and decisions are no longer invisible to the normal issue lookup.
- `CHANGELOG.md` (this file).
- A **Credits** section in the README.
- `docs/plugin-marketplace-dogfooding.md` — how to publish vs. dogfood the plugin
  via a two-marketplace split.

### Changed
- `working-an-issue` now reads an issue **and its comments** when picking up work,
  so later clarifications/corrections in comments aren't missed ("later comment
  wins").

## [0.3.0] - 2026-06-28

### Changed
- **Config moved to a `.lightspeed/` folder** (hard cut): `config.json` and
  `secrets.json` now live under `.lightspeed/` instead of loose files. Consuming
  repos must move their config accordingly.

### Fixed
- Forgejo setup requests the correct token scopes (dropped the unneeded
  `write:misc`).

## [0.2.0]

### Added
- **GitHub backend adapter** — lightspeed now drives either Forgejo or GitHub
  through the same dispatcher/skill surface (full parity, including CI watch).

### Changed
- `bootstrapping-labels` renamed to **`setting-up-a-repo`** and broadened from
  label-seeding to full first-run repo setup (backend coordinates, stage
  pipeline, worker model, then labels).

## [0.1.0]

### Added
- Initial release. The curl/dispatcher architecture (no MCP server required) and
  the core workflow skills: `filing-issues`, `triaging-issues`,
  `working-an-issue`, `promoting-a-branch`, and `queue-batches` (parallel,
  zone-gated issue work). Forgejo backend.
