---
name: add-an-issue-tracker
description: Use when connecting an issue tracker to flight — "add an issue tracker", "add another tracker", "connect Jira", "track issues on GitHub too", "public issues come in on GitHub", "set up the tracker labels", "fix the tracker token" — when setting-up-a-repo needs the repo's first tracker, or when a configured tracker still has unanswered setup questions after an upgrade. Adds or completes ONE named entry in issueTrackers (coordinates, a stable ref and aliases, its credential, its label map, its starting status), verifies it with `flight auth check --tracker`, and reconciles that tracker's labels — adopting existing equivalents, creating only what's missing after a preview, never changing another tracker or the default.
---

# Add an Issue Tracker

Before the first command, follow [runtime preflight](../../references/runtime.md). One
exception: on a repo with **no** `.flightdirector/config.json` yet (a first setup handed over by
`setting-up-a-repo`), `reconcile` has nothing to read — resolve `DISP` and `HARNESS`, skip
`reconcile`, and run it once the config is written (Step 5).

The shared setup flow for **one** issue tracker — the first one on a fresh repo, a second or
tenth one later, or an existing one with setup questions it has never been asked. It produces
one valid entry in `issueTrackers`, the credential that entry uses, and that tracker's complete
label map, without touching any other tracker.

Schema: [flight-setup.md](../../references/flight-setup.md) → *Named issue trackers*. Label
defaults: [default-labels.md](../../references/default-labels.md). Tokens and scopes per backend:
[backends.md](../../references/backends.md). Tracker-aware verbs:
[adapter-contract.md](../../references/adapter-contract.md) → *Named tracker routing*.

Every tracker-scoped command in this skill carries `--tracker <REF>` — without it the dispatcher
acts on the **default** tracker, which is not necessarily the one being set up.

## Red flags — STOP

- **Exactly one default.** The first tracker becomes the default. Adding, completing or repairing
  a tracker **never** moves the default; only an explicit request to change it does (Step 7).
- **A `ref` is forever.** It names the tracker in qualified ids (`FJ-12`) and in branch and
  worktree names (`feature/fj-12-…`). While a repo has a single tracker, names leave the ref out
  (`#12`, `feature/12-…`, #258); adding a **second** tracker switches new work to qualified
  names. Say so when you add one. Branches already started keep resolving to their tracker
  through their retained bindings. Never change an existing entry's `ref` on a rerun. Renaming
  `name` is harmless; renaming `ref` strands branches and is not a setup edit.
- **Never guess past a collision.** A proposed ref or alias that another tracker already uses
  (compared case-insensitively, refs and aliases together) is shown to the user, who picks
  another. Never add a suffix silently, and never treat a *new* tracker with a taken ref as a
  rerun of the existing one.
- **Never rename, recolor, or delete an existing label.** Adopt an equivalent or create what is
  missing, after one preview. `area/*` labels always need the user's input.
- **Each tracker owns its label map.** A name adopted on one tracker says nothing about another —
  reconcile every tracker against its own labels.
- **Tokens only in the gitignored `.flightdirector/secrets.json`** — never in the config, the
  preview, a commit, shared docs or the agent instructions. Don't echo a token back.
- **Schema 3 only.** A config below schema 3 is migrated by `flight reconcile` (the runtime
  preflight does it); never hand-convert one, and never add a top-level `labels` or a real
  `issues` object beside `issueTrackers` (both are validation errors).

## Step 1: Which tracker, and is it already configured?

Read the config: `flight config '.issueTrackers // []'`. If
`.flightdirector/config.local.json` has its own `issueTrackers`, that local array **replaces**
the tracked one wholesale on this machine — edit the local array (as a complete array) when the
tracker belongs there, and never copy local-only coordinates into the tracked file.

- **The user named an existing tracker** (by ref or alias, any case) or `setting-up-a-repo`
  delegated a rerun → select that entry and go to the gap check. Do not append a duplicate.
- **A new tracker** → collect its coordinates (Step 2). An approximate name ("the github one")
  is a suggestion to confirm, never a selection.
- **Signals worth offering:** Jira-shaped keys (`ABC-123`) in recent commit subjects or branch
  names (`git log --oneline -50`, `git branch -a`) suggest a Jira tracker for project `ABC`; an
  intake repo the user mentions ("public issues arrive on GitHub") suggests a second tracker.

**The gap check.** Every question this skill owns maps to a key in the tracker entry. A key that
is **present** — with any value, `false` and `null` included — is answered: skip it. A key that
is **absent** is asked exactly as a first run would ask it, and the answer is written down even
when it is "no", so the next run doesn't ask again. Unknown keys are carried along untouched.

| Question | Entry key(s) | Asked in |
|---|---|---|
| Backend + coordinates | `backend`, `api`, `owner`/`repo` (forges) or `project`/`email` (Jira) | Step 2 |
| Display name | `name` | Step 2 |
| Stable reference | `ref` | Step 3 |
| Aliases | `aliases` (`[]` if declined) | Step 3 |
| Credential | `credentialRef`, plus `secrets.issueTrackers.<REF>` for an own credential | Step 4 |
| Starting status for new issues | `labels.status.new` (a label name, or `false` if declined) | Step 6 |
| Status / model / type labels | the rest of `labels` | Step 6 |

`labels.status.new` has three distinct states — never collapse them:

| State | Meaning | Action |
|---|---|---|
| absent | never asked | offer a starting status (Step 6) |
| `false` | declined | don't ask again; create nothing |
| a string | configured | ensure that label exists on this tracker (adopt an equivalent) |

## Step 2: Coordinates and name

| Backend | Keys | Notes |
|---|---|---|
| `forgejo` (Forgejo/Gitea) | `api` `https://<host>/api/v1`, `owner`, `repo` | |
| `github` | `api` `https://api.github.com`, `owner`, `repo` | |
| `gitlab` | `api` `https://<host>/api/v4`, `owner` (subgroups allowed), `repo` | |
| `jira` | `api` = the site base (no `/rest/api/3`), `project` = the project key | Account `email` on the entry, or `secrets.issueTrackers.<REF>.email` for a personal address you'd rather not commit |

When the issues live on the code repository, propose `code`'s backend, `api`, `owner` and `repo`
and just confirm. Several trackers may share a backend or even a host — two Forgejo repos, two
Jira projects on one site. Ask for a short display `name` ("Working backlog", "Public intake");
it is display-only and may change later.

## Step 3: A stable `ref`, and optional aliases

A ref is a letter followed by letters and digits (`^[A-Za-z][A-Za-z0-9]*$` — no `-`, `_` or `#`,
so `GH12`, `GH-12` and `GH#12` split without guessing); `code` is reserved. Propose:

- **Jira** — the project key (`KAN`, `PROJ`); a Jira key then names its tracker directly. If the
  key isn't a valid ref (it has an `_`), propose the key without it and confirm.
- **GitHub, while the code repository is also on GitHub** (`flight config '.code.backend'` prints
  `github`) — never propose `GH`. Propose a ref derived from the tracker repo's name instead
  (`acme/public-issues` → `PUB`), and tell the user why in one sentence: GitHub autolinks
  `GH-12`-shaped text to the code repository's own issue 12, so commit subjects naming `GH-12`
  would link to the wrong issue. If they still want `GH`, it is their call.
- **Otherwise** — the backend shorthand: `FJ` (Forgejo/Gitea), `GH` (GitHub), `GL` (GitLab).

Check the proposal — and every alias — against the refs and aliases already configured:

<!-- tracker-ref-check -->
```bash
# Prints the ref of the tracker that already answers to $CANDIDATE; empty means it is free.
flight config '.issueTrackers // []' | jq -r --arg r "$CANDIDATE" '
	.[] | select(([.ref] + (.aliases // [])) | map(ascii_downcase) | index($r | ascii_downcase)) | .ref'
```

**On a collision**, show which tracker holds the name and let the user choose another — e.g. a
second GitHub repo next to an existing `GH` might be `PUB` or `GH2`. Their pick is checked the
same way. Don't pick for them.

Then offer **aliases**: other names people may type for this tracker (`Public` for `PUB`).
Aliases share the ref rules and uniqueness pool. Record `[]` when they want none.

## Step 4: Credential

Two choices, per the schema's `credentialRef`:

- **Share the code credential** — `"credentialRef": "code"`. The natural choice when the issues
  live **on the code repository** itself: one token, and the `LS_TOKEN` / `FLIGHT_TOKEN` /
  `FORGEJO_TOKEN` environment overrides CI and env-token setups rely on keep working. It is only
  **valid** when the tracker's `backend` and `api` host equal `code`'s (the dispatcher rejects it
  otherwise, so a token is never sent to another system). For another repository on the same
  host, prefer an own credential — a least-privilege code token is restricted to the code repo
  and won't reach it — unless the user says their code token covers both.
- **Its own credential** — omit `credentialRef`. The token lives at
  `secrets.issueTrackers.<REF>.token` (exact ref case) and nothing else is ever used for this
  tracker: environment tokens are code credentials and never reach it. Two trackers on one
  backend can hold different tokens this way.

For an own credential, ask the user for a **least-privilege** token for that tracker — the
per-backend walkthrough and minimum scopes are in [backends.md](../../references/backends.md) —
and merge it into the secrets file, preserving `code`, every other tracker's entry and unknown
keys (`.flightdirector/secrets*` must already be gitignored — `setting-up-a-repo` Step 2):

<!-- tracker-secrets -->
```json
{
  "code": { "token": "<code token>" },
  "issueTrackers": {
    "FJ": { "token": "<FJ token>" },
    "KAN": { "token": "<Jira API token>", "email": "<account email>" }
  }
}
```

A replacement token can be tried before it goes live: write a copy of the secrets file with the
new token to `.flightdirector/secrets-new.json` and run
`flight auth check --tracker <REF> --secrets .flightdirector/secrets-new.json`.

## Step 5: Write the entry, then verify it

Build the entry from this run's answers — **never with a `default` key**; the merge decides it.
The first tracker of a Forgejo repo whose issues live on the code repository, before labels are
reconciled (the labels are the seeded defaults; Step 6 replaces each with the name this tracker
actually uses):

<!-- tracker-entry-first -->
```json
{
  "ref": "FJ",
  "name": "Working backlog",
  "aliases": [],
  "backend": "forgejo",
  "api": "https://git.example.com/api/v1",
  "owner": "acme",
  "repo": "widget",
  "credentialRef": "code",
  "labels": {
    "status": { "in-progress": "status/in progress", "to-test": "status/to test",
                "blocked": "status/blocked", "deferred": "status/deferred",
                "review": "status/review", "qa": "status/qa", "done": "status/done" },
    "model": { "opus": "model/opus", "sonnet": "model/sonnet", "haiku": "model/haiku",
               "fable": "model/fable", "sol": "model/sol", "terra": "model/terra",
               "luna": "model/luna", "astra": "model/astra" }
  }
}
```

A second tracker — a Jira project with its own token, added to that repo later (Jira labels are
single tokens, so its names are space-free):

<!-- tracker-entry-jira -->
```json
{
  "ref": "KAN",
  "name": "Product planning",
  "aliases": ["Roadmap"],
  "backend": "jira",
  "api": "https://example.atlassian.net",
  "project": "KAN",
  "labels": {
    "status": { "new": false, "in-progress": "status/in-progress", "to-test": "status/to-test",
                "blocked": "status/blocked", "deferred": "status/deferred",
                "review": "status/review", "qa": "status/qa", "done": "status/done" },
    "model": { "opus": "model/opus", "sonnet": "model/sonnet", "sol": "model/sol",
               "astra": "model/astra" }
  }
}
```

**Preview before writing** — the entry, whether it is new or completes an existing one, that the
default stays where it is (or, for the first tracker, that this one becomes it), and which
secrets key the credential uses (the key, never the token). On a yes, merge it into the config
file `CFG` with `ENTRY` holding the entry JSON:

<!-- tracker-merge -->
```bash
# New ref → appended; default only when it is the first tracker.
# Existing ref → a gap fill: every key already present wins, so a rerun adds answers and never
# overwrites one (a recorded `new: false` stays false), and the default never moves.
tmp="$(mktemp "$CFG.tmp.XXXXXX")"
jq --argjson t "$ENTRY" '
	($t | del(.default)) as $t
	| (.issueTrackers // []) as $all
	| ([$all[] | .ref | ascii_downcase] | index($t.ref | ascii_downcase)) as $i
	| if $i == null
	  then .issueTrackers = $all + [$t + {default: ($all | length == 0)}]
	  else .issueTrackers[$i] = ($t * $all[$i])
	  end
' "$CFG" >"$tmp" && mv "$tmp" "$CFG"
```

Only merge an existing ref when Step 1 selected that tracker — a new tracker whose ref is taken
went back to Step 3. On a **first setup** `CFG` is the candidate skeleton `setting-up-a-repo`
prepared (outside `.flightdirector/`); install it as `.flightdirector/config.json` only after
this merge, so the config never exists without a default tracker, then run the deferred
`flight reconcile --harness <claude|codex>` (it stamps the harness version and changes nothing
else on a fresh schema-3 config). On a rerun keep a copy of the file before the merge.

Then verify, in order:

1. `flight issues resolve --tracker <REF> --number 1` — validates the whole tracker list (one
   default, unique refs/aliases, a valid `credentialRef`) and selects this tracker. No network,
   no issue is read. On an error, restore the copy and fix the answer it names.
2. `flight auth check --tracker <REF>` — identity, repo/project reach and each capability the
   skills use, with this tracker's own credential. Read the source it names: a tracker on
   `credentialRef: "code"` reports the code token's source (possibly an env var). On a `✗`, fix
   the token or scope and re-check before going on — the label step needs a working credential.

## Step 6: Reconcile this tracker's labels

Fetch what this tracker already has: `flight labels list --tracker <REF>` (`name⇥color⇥description`
per label; Jira's labels are bare names — colour and description are empty, and `labels create`
is a no-op there because Jira labels spring into existence on first use).

For every default in [default-labels.md](../../references/default-labels.md), and every role the
entry already names, classify:

| Outcome | Condition | What to record for the role |
|---|---|---|
| **EXISTS** | the tracker has that exact name | that name |
| **ADOPT** | it has a listed equivalent or an obvious synonym (`Bug`, `🐛 bug`, `enhancement` for `feature`) | **the tracker's existing name** |
| **MISSING** | neither | the default name, once created |

When more than one existing label could fill a role, ask. A role the entry already records (a
carried-forward name) keeps its name — only verify it exists. The whole `labels` object moves as
one: status roles, `model` roles and any role of the repo's own stay in this tracker's entry.

**Offer the starting status** only when `labels.status.new` is **absent**: *"Should a freshly
filed issue on `<REF>` get a starting status label, so the board can tell 'nobody has looked at
this yet' apart from 'someone forgot the label'? Suggested: `status/new` — or whatever this
tracker already calls that state (`status/triage`, `status/open`, `backlog`, …)."* Adopt an
existing equivalent rather than creating a second one. Yes → record the name and treat it like
any other role below; `flight issues create --tracker <REF>` applies it from then on, and the
first `set-status` replaces it. **No → record `"new": false`.** Ask per tracker: one tracker's
answer is not another's.

**`area/*` labels** are project-dependent: inspect the repo (top-level layout, README, services)
and propose a set (`web/` + `api/` + `migrations/` → `area/app`, `area/server`, `area/db`); the
user confirms, edits or skips. All `area/*` labels take the one group colour from the data file.

Show one plan and ask once:

```
Label plan for tracker KAN (Jira project KAN):

  CREATE  model/sol, model/astra, feature, tech-debt, bug
  ADOPT   in-progress ← 'doing'   (tracker already has it; using yours)
  EXISTS  status/blocked
  NEW     declined → "new": false
  AREAS   area/app, area/server   (proposed from the repo layout — confirm)

Create these? [y]
```

On approval, create each missing label from the data file:

```
flight labels create --tracker KAN --name "bug" --color "#d73a4a" --description "Something is broken"
```

If a create fails because the label now exists (someone raced you), re-list and adopt it — never
create a second synonym. Then **finalize the entry's labels** with the names this tracker
actually uses; `ADOPTED` holds only the roles decided in this run, so carried-forward names and
every other tracker stay exactly as they were:

<!-- tracker-labels-finalize -->
```bash
tmp="$(mktemp "$CFG.tmp.XXXXXX")"
jq --arg r "$REF" --argjson adopted "$ADOPTED" '
	.issueTrackers |= map(
		if (.ref | ascii_downcase) == ($r | ascii_downcase)
		then .labels = ((.labels // {}) * $adopted) else . end)
' "$CFG" >"$tmp" && mv "$tmp" "$CFG"
```

Report what was created, adopted, declined and left unchanged. Re-running later is safe:
everything now present is EXISTS or ADOPT, and only absent questions are asked.

> **Forgejo — optional label exclusivity.** Forgejo (and Gitea) can mark a scoped label group
> *exclusive*, so its UI allows one label from the group per issue. flight doesn't rely on it —
> `set-status` already drops the prior `status/*` label on every backend — so it only guards
> against a human hand-adding two. If wanted, make `status/*` exclusive and leave `model/*`
> non-exclusive (an issue can be worked by more than one model).

## Step 7: Changing the default (only when asked)

A bare `12` / `#12` means the default tracker, and a new work item started after a change
follows the new default — work already started keeps its tracker (branches are qualified, and
pre-schema-3 branches stay bound to the tracker they were migrated with). Change it only on an
explicit request, as one edit, after showing the before/after:

<!-- tracker-default-switch -->
```bash
tmp="$(mktemp "$CFG.tmp.XXXXXX")"
jq --arg r "$REF" '.issueTrackers |= map(.default = ((.ref | ascii_downcase) == ($r | ascii_downcase)))' \
	"$CFG" >"$tmp" && mv "$tmp" "$CFG"
```

Then re-run `flight issues resolve --number 1` and confirm it names the new default.

## Common mistakes

- Running `auth check` or `labels list` / `labels create` without `--tracker <REF>` — that
  checks or writes the **default** tracker, not the one being set up.
- Treating an absent `new` and `new: false` as the same answer (or writing neither on a "no").
- Appending a second default, or making the tracker you just added the default because it's the
  one on your mind.
- Merging a new tracker into an existing entry because their refs collide, instead of asking for
  another ref.
- Setting `credentialRef: "code"` for a tracker on another host (rejected), or for a different
  repository when the code token is restricted to the code repo (auth check fails).
- Copying one tracker's adopted label names onto another without listing its labels.
- Replacing a tracker's whole `labels` object with just the roles touched this run.
- Writing a machine-local tracker array into the committed `config.json`.
