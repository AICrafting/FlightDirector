# 1. curl over MCP, and a per-axis adapter architecture

- **Status:** Accepted
- **Date:** 2026-06-27
- **Supersedes:** the earlier MCP-based design of the plugin

## Context

**`lightspeed`** drives an issue/code workflow from within a Claude Code session: filing,
triaging, and working issues through their lifecycle, and — newly — shipping a development
branch (open a PR, watch CI). The earlier design routed every backend operation through goern's
Forgejo MCP server
(`mcp__forgejo__*`), on the principle that the API token stays hidden in the MCP server's
config and never touches the skills.

Three forces pushed us to re-examine that:

1. **CI operations the MCP server structurally cannot do.** Watching CI requires a
   *background, streaming* process that emits one line per state change (consumed by the
   `Monitor` tool); MCP tools are one-shot request/response and cannot be backgrounded as a
   watcher. Fetching failed-run logs requires reading archived log files / the Forgejo DB on
   the host — the MCP server (and the Forgejo REST API) don't expose raw logs at all. Both
   need a shell script with a token in the environment.

2. **Context cost of MCP bulk reads.** `mcp__forgejo__list_repo_issues` returns full issue
   JSON into the conversation context. Read-heavy operations (dedup scanning, triage
   listing) pay an order-of-magnitude context tax versus `curl | jq`, which projects to just
   the fields needed (`#N title`) before anything reaches context.

3. **Least-privilege tokens.** A single MCP server uses one highly privileged token with
   access to all orgs/repos (so it can serve many projects). Moving to per-repo,
   least-privilege tokens turns a misfire ("filed in the wrong repo") into a hard `403`.
   Per-repo tokens are exactly what a server-level-env-token MCP server is bad at.

4. **Multi-backend ambitions.** The plugin should eventually support GitHub, GitLab, and
   issue trackers like Jira/Asana. There is no single MCP server that speaks all of these
   with one vocabulary — each backend is a separate server with different tool names and
   shapes. MCP abstracts *within* a backend and *fragments across* backends, requiring N
   third-party server prerequisites the user must install, register under predictable names,
   and hope expose the concepts needed.

Once a token is required in the shell environment for (1), the "token never touches the
skills" rationale — MCP's main remaining advantage here — is gone by choice. At that point
the MCP server is doing single-item mutations that `curl` does equally well, while *forcing*
either per-call tokens or per-backend registrations. Its value has gone to nearly zero.

## Decision

### 1. Transport: curl, not MCP

All backend interaction goes through `curl` (+ `jq`) against the backend's REST API. The
plugin declares no MCP server dependency. This unifies on one auth path, removes the install
prerequisite, makes per-repo least-privilege tokens natural, and keeps read operations
context-light by projecting with `jq` before results reach context.

Note: the Forgejo/Gitea REST API deliberately mirrors GitHub's API shape, so a curl-based
Forgejo adapter is ~90% of a future GitHub adapter — a portability win only available if we
own the transport.

### 2. Two backend axes: `code` and `issues`

Issues and code are independent axes. Real setups cross them (Jira issues + GitHub code;
Asana issues + GitLab code; or the same provider with different `owner/repo` for planning vs
service code). The config models both:

- `code` is the **required base** — everyone has code.
- `issues` is **optional and inherits from `code`** (backend, owner, repo, token) when
  omitted — someone who doesn't track issues simply omits the block. Inheritance flows
  `code → issues`, never the reverse.

### 3. Config and secrets files

- **`.lightspeed.json`** (committable) — backends, coordinates, trunk branch, gate
  placement, merge strategy, label-name map.
- **`.lightspeed.secrets.json`** (gitignored) — the per-axis token(s). A dedicated secrets
  file rather than `.env`, to avoid colliding with the user's existing local dev
  environment. If this file is ever found tracked by git, the plugin **warns loudly on every
  run** but does not refuse to run.

```jsonc
// .lightspeed.json
{
  "code":   { "backend": "forgejo", "owner": "...", "repo": "...",
              "api": "https://git.ex/api/v1", "trunkBranch": "develop" },
  "issues": { "backend": "forgejo", "owner": "...", "repo": "..." }, // omit to inherit code
  "gate": "pre-merge",        // pre-merge | post-merge-qa
  "mergeStrategy": "direct",  // direct | pr
  "labels": { /* role → actual label name */ }
}
```

```jsonc
// .lightspeed.secrets.json  (GITIGNORED)
{
  "code":   { "token": "..." },
  "issues": { "token": "..." }   // omit to inherit code
}
```

### 4. Adapter architecture: a per-axis, CLI/exec contract

Skills speak an **abstract vocabulary** of backend verbs and never embed a backend's
endpoints. A dispatcher routes each verb to the adapter named by the relevant axis in config
(`issues.backend` for `issues_*`, `code.backend` for `cr_*`/`code_*`/`ci_*`).

The contract is a **process/CLI interface** — an executable invoked with arguments,
returning distilled output on stdout and a meaningful exit code — **not** a sourced shell
function. This makes the implementation language invisible to skills and the dispatcher, so
any single adapter can be reimplemented in another language without touching anything above
it.

Initial vocabulary (grow as needed; this is the architectural core, not the full surface):

| Verb                | Axis   | Purpose                                            |
|---------------------|--------|----------------------------------------------------|
| `issues_list`       | issues | list/filter issues, projected to minimal fields    |
| `issues_get`        | issues | fetch one issue (title + body)                     |
| `issues_create`     | issues | create an issue                                    |
| `issues_comment`    | issues | comment on an issue                                |
| `issues_set_status` | issues | resolve role→label, apply status label by id       |
| `issues_close`      | issues | change issue state                                 |
| `labels_resolve`    | issues | map label name(s) → numeric id(s)                  |
| `cr_open`           | code   | open a change request (PR/MR)                      |
| `cr_merge`          | code   | merge a change request                             |
| `ci_watch`          | code   | background-stream CI status for a SHA (for Monitor)|
| `ci_log`            | code   | fetch logs of a failed CI run                      |

The reference doc for each adapter documents this **contract** (signatures + output shapes),
not a per-call curl cookbook.

### 5. Implementation language: shell first, Go as a sanctioned per-adapter escape hatch

Adapters are implemented in **shell (bash + curl + jq)** by default. Shell ships in the repo
and runs on clone with no build step — preserving the zero-prerequisite property that
dropping the MCP server (itself a separately-installed Go binary) just regained. Forgejo
and GitHub REST are simple enough that shell handles them comfortably.

Because the contract is a process interface (decision 4), **any single adapter may be
reimplemented as a compiled binary (e.g. Go) when its backend's complexity warrants it** —
with no change to skills or dispatcher. Reach for a compiled adapter when a backend needs:
rich body formats (e.g. Jira ADF), stateful workflow transitions, GraphQL, or cursor
pagination that makes `jq` miserable. Plain REST-CRUD-with-labels stays shell.

We do **not** adopt Go wholesale up front: that would reintroduce the exact
compiled-binary distribution friction (per-OS/arch builds, a release/fetch step, or a
required toolchain) we just eliminated, for backends that don't need it.

## Consequences

**Positive**

- One auth model; no MCP server prerequisite; runs on clone.
- Per-repo least-privilege tokens; wrong-target calls fail hard.
- Read operations are uniformly context-light (`jq` projection).
- A hard, code-enforced abstraction boundary: skills cannot leak backend endpoints because
  they only invoke contract verbs.
- Cheap second backend (Gitea≈GitHub API); clean place to absorb GitLab/Jira differences.
- CI watch/log — impossible via MCP — are first-class.

**Negative / costs**

- The token is now present in the shell environment; Claude can read it. The capability
  boundary doesn't move (the same token already authorized all MCP actions) but the exposure
  surface does. Accepted deliberately in exchange for least-privilege scoping.
- Shell is finicky (quoting, bash-vs-zsh word-splitting, jq discipline, GNU-vs-BSD utils).
  Mitigated by encapsulating the error-prone mechanics (auth header, pagination,
  `jq --rawfile` PR-body assembly, label name→id) once per adapter and by the option to
  promote a gnarly adapter to a compiled binary.
- We own and maintain the backend client surface that the MCP server previously provided.
- Mixed-language adapters (if/when Go is used) mean two dev/test stories. Bounded by the
  process-interface contract, which keeps each adapter small and isolated.

**Migration**

- Set the plugin name to `lightspeed` in `plugin.json`.
- Rewrite the four existing skills (`filing-issues`, `triaging-issues`,
  `setting-up-a-repo`, `working-an-issue`) onto the contract verbs; implement the Forgejo
  adapter in shell.
- Move config to `.lightspeed.json` + `.lightspeed.secrets.json`, with `code`/`issues` axes
  and `code → issues` inheritance.
- Then build the `ship` skill on the curl-native foundation.

## Alternatives considered

- **Keep MCP, add a parallel curl path only for CI.** Rejected: once a shell token is
  required anyway, maintaining two auth paths and two transports for the same operations adds
  surface for no benefit; MCP's residual advantage (hidden token) is forfeited by the CI
  requirement.
- **Keep MCP with per-call tokens (the Forgejo MCP server supports them).** Rejected:
  per-call tokens ride into context/logs, and per-backend registrations break the
  `mcp__forgejo__*` tool-name assumption. Still leaves the multi-backend fragmentation and
  context-cost problems unsolved.
- **Go (or another compiled language) for all adapters from the start.** Rejected as the
  default: reintroduces compiled-binary distribution friction for backends that don't need
  it. Retained as a per-adapter escape hatch (decision 5).
- **Reference-doc-only adapters (no executable contract).** Rejected: the boundary would be
  convention, not code — Claude could vary projections, drop pagination, or reconstruct auth
  per call. Non-deterministic and untestable; the error-prone mechanics get re-derived each
  invocation rather than solved once.
- **Sourced shell-function library.** Rejected in favor of a process/CLI contract: sourced
  functions lock the implementation into shell and foreclose the Go escape hatch.
