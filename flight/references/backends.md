# Supported backends

flight talks to a backend through an **adapter** — skills call verbs on the dispatcher, the
dispatcher resolves the axis (`issues`/`labels` → `issues.*`, `pr`/`ci` → `code.*`) and execs the
right backend's adapter (see [adapter-contract.md](adapter-contract.md)). Four backends ship today:

| Backend   | `backend` value | Axes it can serve        | Parity                                   |
|-----------|-----------------|--------------------------|------------------------------------------|
| Forgejo   | `forgejo`       | `code` + `issues`        | Full: issues, labels, PRs, CI (reference backend) |
| GitHub    | `github`        | `code` + `issues`        | Full: issues, labels, PRs, Actions CI    |
| GitLab    | `gitlab`        | `code` + `issues`        | Full: issues, labels, MRs, pipeline CI   |
| Jira      | `jira`          | `issues` **only**        | Issues + labels; pair with a git `code` backend |

Each backend below gives you: a worked `.flightdirector/config.json` fragment, where to create the
token, and the **minimum** scopes/permissions the adapter actually needs — not the provider's
broadest default. Tokens always live in the gitignored `.flightdirector/secrets.json` (`code.token`
and/or `issues.token`, with `code → issues` inheritance); see
[flight-setup.md](flight-setup.md) for the two-file layout and axis inheritance.

> **Least privilege is the point.** A per-repo token scoped to exactly what the skills call keeps
> the blast radius to one repo — a misfire returns `403` instead of writing to the wrong place.
> Scope to a single repository/project wherever the provider allows it.

`setting-up-a-repo` autodetects Forgejo and GitHub coordinates from the git remote; GitLab and Jira
are configured by hand-editing `.flightdirector/config.json` (and `secrets.json`) for now.

---

## Forgejo (reference backend)

Full parity across all four verb groups. The `api` value is the **instance** API base ending in
`/api/v1` (not repo-scoped — the dispatcher appends `/repos/<owner>/<repo>`).

```jsonc
"code": {
  "backend": "forgejo",
  "owner": "acme",
  "repo": "widget",
  "api": "https://git.example.com/api/v1",   // instance base + /api/v1
  "stages": [
    { "name": "develop", "merge": "direct", "issueStatus": "to-test" },
    { "name": "main",    "merge": "pr",     "issueStatus": "done" }
  ]
}
// "issues": { … }   // omit to inherit code's backend/owner/repo/api/token
```

**Create a token:** `https://<your-instance>/user/settings/applications` → *Generate New Token*.

**Minimum scopes:** create the token **restricted to the single repository**, with exactly two
scopes:

- `write:repository` — branches, pull requests, CI.
- `write:issue` — issues **and** labels.

Do **not** add `write:misc`: the skills don't use it, and Forgejo refuses to combine `write:misc`
with a single-repository restriction.

---

## GitHub (full parity)

Full parity. Note the `api` base is `https://api.github.com` — **no** `/api/v1` (that's a Forgejo
convention). Labels are managed by name under the Issues permission; `issues attach` is not
supported on GitHub (no REST API for issue attachments).

```jsonc
"code": {
  "backend": "github",
  "owner": "your-org-or-user",
  "repo": "your-repo",
  "api": "https://api.github.com",           // no /api/v1
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

**Create a token:** a **fine-grained** PAT at
`https://github.com/settings/personal-access-tokens/new`, scoped to the one repository (classic
tokens at `https://github.com/settings/tokens` also work — see below).

**Minimum permissions (fine-grained PAT, single repo):**

| Permission        | Access         | Why                                                             |
|-------------------|----------------|-----------------------------------------------------------------|
| **Contents**      | Read and write | Branches and PR merges (`pr merge` writes to the repo).         |
| **Issues**        | Read and write | Issues *and* labels (label endpoints live under Issues).        |
| **Pull requests** | Read and write | `pr open` / `pr merge`.                                          |
| **Actions**       | Read-only      | `ci watch` / `ci log` read workflow runs and per-job logs.       |
| **Workflows**     | Read and write | *Only if* a promoted branch changes files under `.github/workflows/` — GitHub blocks pushing/merging workflow edits without it. Omit if you never touch workflow files. |

Drop **Actions** and **Workflows** if you don't use the `ci` group.

**Classic-PAT equivalent:** the `repo` scope covers Contents + Issues + Pull requests + Actions
read; add `workflow` only if promoted branches edit workflow files. `repo` is broader than the
fine-grained set above — prefer fine-grained when you can.

---

## GitLab (full parity)

Full parity: `pr` is a **merge request**, `ci` is **pipelines**. GitLab addresses a project by its
URL-encoded `owner/repo` path — put subgroups in `owner` (e.g. `"group/subgroup"`). Issues are
addressed by their per-project `iid`. See the adapter contract's *GitLab backend specifics* for the
`--strategy` and pipeline nuances.

```jsonc
"code": {
  "backend": "gitlab",
  "owner": "your-group",                     // subgroups allowed: "group/subgroup"
  "repo": "your-project",
  "api": "https://gitlab.com/api/v4",        // self-managed: https://gitlab.example.com/api/v4
  "stages": [ { "name": "main", "merge": "pr" } ]
}
```

**Create a token:** a **personal** access token at
`https://gitlab.com/-/user_settings/personal_access_tokens`, or — narrower blast radius — a
**project** access token from the project's *Settings → Access Tokens*. Sent as the
`PRIVATE-TOKEN` header.

**Minimum scope:** **`api`** (classic personal or project access token).

The adapter creates and merges issues, labels, merge requests, and reads pipelines/job traces —
all write operations under GitLab's single `api` scope. The read-only `read_api` scope is **not**
sufficient (it can't create issues or merge MRs), and GitLab has no finer read/write split that
still covers issues *and* MRs, so `api` is the minimum. A **project** access token with `api`
confines that scope to the one project.

**Fine-grained personal access token** (gitlab.com's newer per-project tokens have no `api`
scope; you pick per-resource permissions instead). Grant, for the one project:

| Resource | Permissions | Used by |
|---|---|---|
| Project | Read | project lookup, default branch |
| Work Item | Read, Create, Update | `issues` (issues *and* their comments/notes) |
| Label | Read, Create, Update | `labels`, `issues set-status` |
| Merge Request | Read, Create, Update, Merge | `pr` |
| Pipeline | Read | `ci runs` / `ci watch` |
| Job | Read | `ci log` (per-job traces) |
| Markdown Upload | Read, Create | `issues attach` |
| Repository | Read, Write | branches / files (rig + promotion) |

Not needed: Member, Webhook, Personal Access Token, or any *User* permission — the adapter never
calls `GET /user`. If GitLab's editor names a permission differently, its 403 body says exactly
which one is missing (`insufficient_granular_scope … [Work Item: Read]`).

**Token expiry:** every GitLab token has a mandatory expiry date (gitlab.com caps it at 400
days). A token past its date fails with `401 invalid_token` on *every* call — check the date
before debugging scopes. **Project access tokens** create a bot user that must actually hold a
role on the project; a bot with no membership reports `access_level: null` and gets
`404 Project Not Found` for its own project regardless of scopes.

---

## Jira (issues-axis only)

Jira is an issue tracker, not a git host, so it backs **only the `issues` axis** — implements
`issues` + `labels`. Pair it with a git `code` backend that keeps serving `pr`/`ci`. Targets Jira
**Cloud REST v3** with HTTP **Basic** `email:api_token` auth (a classic Atlassian API token — **not
OAuth**).

```jsonc
{
  "code":   { "backend": "github", "owner": "acme", "repo": "widget",
              "api": "https://api.github.com", "stages": [ { "name": "main", "merge": "pr" } ] },
  "issues": { "backend": "jira",
              "api": "https://your-site.atlassian.net",  // the site base, no /rest/api/3
              "project": "KAN",                            // the Jira project key
              "email": "you@example.com" }                 // for email:token Basic auth
}
```

The token goes in `secrets.json` under `issues.token`; the account email is `issues.email` in config
(or `LS_EMAIL` in the env). See the adapter contract's *Jira backend specifics* for the
key-as-identifier, status-as-labels (labels must be **space-free** single tokens),
close/reopen-as-workflow-transitions, ADF body conversion, and thin-labels behaviours.

**Create a token:** a classic Atlassian API token at
`https://id.atlassian.com/manage-profile/security/api-tokens` → *Create API token*.

**Minimum permissions:** a classic Atlassian API token is **unscoped** — it inherits the full Jira
permissions of the account that created it. So achieve least privilege through the **account's
project role**, not the token. Use (or create) an account whose grants on the target project are
just what the adapter exercises:

- **Browse Projects** — `issues list`/`get`/`comments`.
- **Create Issues** — `issues create`.
- **Edit Issues** — `issues update`, and `set-status`/`label-add`/`label-remove` (Jira status is driven via
  labels, which are an edit-issue operation).
- **Add Comments** — `issues comment`.
- **Transition Issues** — `issues close`/`reopen` post real workflow transitions (Done ⇄ To-Do).

Grant those on the one project rather than making the account a site or project admin.

---

## See also

- [flight-setup.md](flight-setup.md) — the two config files, axis inheritance, `stages`, and
  least-privilege token notes.
- [adapter-contract.md](adapter-contract.md) — the full verb set and each backend's specifics.
- [example-flows.md](example-flows.md) — worked stage pipelines at 1–4 hops.
