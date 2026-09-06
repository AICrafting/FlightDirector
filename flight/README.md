# Flight (Claude Code + Codex plugin)

> **Flight** is the first plugin of the **Flight Director** family — tools for building and
> shipping apps from inside an agent session. In NASA mission control everyone addresses the
> flight director by the callsign *"Flight"*; this plugin is the one that directs the mission
> (which issue, which branch, when it promotes), so it carries the callsign. It was previously
> called `lightspeed` during initial development/testing — see the [CHANGELOG](CHANGELOG.md)
> for the migration notes.

Seven skills for running an issue + code workflow from Claude Code or Codex using one shared package.
Everything goes through the **flight dispatcher** — `flight <group> <verb>` — which calls
the backend's REST API with `curl`. Skills resolve its installed path rather than requiring Codex
to inject the plugin's `bin/` directory into `PATH`.
Backend-agnostic by design — Forgejo/Gitea, GitHub, and GitLab at full parity, Jira for the issues
axis, all behind the same adapter contract (see [backends.md](references/backends.md)); no MCP
server to install.

> **New here?** The **[User Guide](GUIDE.md)** covers why you'd want this, how to install it,
> first-time setup, and a full worked example (file → triage → work → promote).

| Skill | Triggers on | Does |
|---|---|---|
| `filing-issues` | "file an issue", "open a ticket", "track this", "log a bug", `/issue …` | Dedupe-check → write → label → create; or confirm-then-update an existing issue |
| `triaging-issues` | "what should I work on", "what's next", "quick wins", "show open issues" | Lists and filters open issues for selection (read-only) |
| `working-an-issue` | "let's work on #N", "start issue #N", "this is ready to test", "merge #N" | Per-issue worktree → status-label → test → promote (delegated) → finish lifecycle, with a human gate before merge |
| `promoting-a-branch` | "promote this", "promote to qa", "open a PR for this branch", "this branch is ready" | Advances the current branch one stage up the pipeline (feature → develop → qa → main), with the hop's merge strategy, gate, test-plan halt, and CI watch |
| `promoting-branches` | "promote each zone", "promote the first zone", "promote issues 18, 93, 12", "batch promote" | Promotes a selected group of first-hop feature branches into `stages[0]` in one go, honoring that hop's merge strategy (direct → N merges; pr → one PR per group) |
| `queue-batches` | `/queue-batches NxM`, "work N issues in parallel", "batch these issues", "dispatch agents" | Dispatch N background agents, each working M issues sequentially through the working-an-issue lifecycle in isolated worktrees (zones), stopping at the to-test gate; batch hand-off to promoting-branches |
| `setting-up-a-repo` | "set up labels", "bootstrap labels", "add default labels", or a bare repo during filing | First-run setup: writes config + secrets, then reconciles a default taxonomy against existing labels and creates only what's missing |

## How it works

Skills never embed backend endpoints or handle tokens. They invoke verbs through the dispatcher,
which resolves the right backend for the axis from config and execs that backend's adapter:

```
flight issues list --state open --limit 50
```

- **Adapters** (`scripts/adapters/<backend>/`) are pure `curl`/`jq` over the REST API, with a
  CLI/exec contract so a backend is a drop-in swap. See
  [`references/adapter-contract.md`](references/adapter-contract.md).
- **Two config axes** — `code` (required) and `issues` (optional, inherits `code`) — so issues
  and code can live on different backends or repos. See
  [`references/flight-setup.md`](references/flight-setup.md) and
  [ADR 0001](../docs/adr/0001-curl-over-mcp-and-adapter-architecture.md) for the rationale.

## Prerequisites

- `curl` and `jq` on `PATH`.
- A per-repo, least-privilege API token. Nothing to install or run.
- In Codex, permission for the forge hostname and confirmation for network, push, and merge
  operations as required by the active sandbox profile. `queue-batches` additionally requires
  Codex multi-agent support; the other skills do not.

## Install

Both harnesses install from the same marketplace — `flightdirector`, hosted at
<https://github.com/AICrafting/FlightDirector>. The package ships a manifest for each harness
(`.claude-plugin/` and `.codex-plugin/`) over one shared set of skills and scripts.

- **Claude Code:**
  ```
  /plugin marketplace add https://github.com/AICrafting/FlightDirector.git
  /plugin install flight@flightdirector
  ```
- **Codex:**
  ```
  codex plugin marketplace add https://github.com/AICrafting/FlightDirector.git
  codex plugin add flight@flightdirector
  ```
  or install *Flight* from the `flightdirector` tab of `/plugins`. Start a new session before
  invoking a skill.

## Configuration

Run `setting-up-a-repo` once per repo — it autodetects owner/repo from the git remote, asks
which stage pipeline to use (a preset like `develop → main` or `develop → qa → main`, or a
custom one), captures a token into a gitignored `.flightdirector/secrets.json`, writes the per-repo
`.flightdirector/config.json`, and seeds labels. The other
skills then read that config, so they speak your repo's label names and follow your merge style.
Full details: [`references/flight-setup.md`](references/flight-setup.md).

## Default labels

`setting-up-a-repo` seeds a consistent taxonomy idempotently — it only adds what's missing and
**adopts your existing conventions**: if the repo already calls the awaiting-test state
`status/testing`, it records `status/testing` for that role rather than creating its own `status/to test`,
and never renames or deletes existing labels. The taxonomy is **data** in
[`references/default-labels.md`](references/default-labels.md) (flat `bug`/`feature`/`tech-debt`,
namespaced `model/*`, project-dependent `area/*` confirmed against the repo).

The skill split is along trigger boundaries: *creating/changing* an issue and *picking work* have
different vocabularies. `filing-issues` keeps create + update together because they share the
dedupe-check decision tree.
