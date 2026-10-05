# Batch agent prompt (template)

Placeholders the orchestrator fills before dispatch:
- `{zone}` — batch/zone name, e.g. `auth`
- `{model}` — worker model, for traceability
- `{dispatcher}` — absolute path to the flight dispatcher script
- `{base_branch}` — name of `stages[0]` (feature branches fork from it)
- `{repo_root}` — absolute path to the MAIN repo checkout
- `{log_path}` — absolute path to this zone's status log
- `{scratch}` — a writable scratch dir for `--body-file` temp files
- `{issues_ordered}` — newline-separated `<ID> <slug>` list (e.g. `#12 fix-login`, or `FJ-12 fix-login` when the repo has several trackers), execution
  order (smallest-first)
- `{repo_rules}` — verbatim contents of the repo's agent-rules file, or `None configured.`
- `{preflight}` — the repo's check command (`code.preflight`), or `None configured.`
- `{pre_made_decisions}` — bullet list of orchestrator decisions so the agent doesn't stall

---

# Prompt body

I'm dispatching you as a background sub-agent to work a queue of issues for zone **{zone}**
(model **{model}**), each in its own isolated worktree. **No pushes. No promotions.** All backend
access goes through the flight dispatcher at `{dispatcher}` — never curl, never MCP.

## Setup (once, before the first issue)

```bash
cd "{repo_root}"
mkdir -p "$(dirname {log_path})"; touch {log_path}
# Confirm the dispatcher resolves config from here:
{dispatcher} config '.code.stages[0].name'   # should print {base_branch}
```

Record the baseline test status for {base_branch}. The repo's check command is:

```
{preflight}
```

Run **exactly that** — not a subset you pick from memory — from `{repo_root}` (no issue worktree
exists yet), and run it in the **foreground**:

```bash
( cd "{repo_root}" && sh -c '<the command above>' )
```

Never rely on where your shell happens to be sitting. Your shell also does not outlive your
return, so a backgrounded run has nothing left to write its verdict into. You'll report deltas at
the end.

Sibling zone agents run this same baseline against `{repo_root}` at roughly the same moment. If
the command writes build artifacts into that tree, say so in your report rather than trusting the
numbers — you may be reading another zone's output.

If that block reads `None configured.`, this repo names no gate: run its own test command if one
is discoverable, and say in your final report which command you used.

The orchestrator re-runs the repo's command in each finished worktree after you return — that
sweep, not your run, is the authoritative record. Yours is what keeps you from building three
issues on top of a break.

## Issues (work in this order, one at a time)

```
{issues_ordered}
```

As you reach each issue, resolve its qualified id **once** and keep the result — the tracker it
names is where every later read and write goes, even if the configured default tracker changes
while you work (two trackers can both have an issue 12, so never fall back to a bare number):

```bash
IDENTITY="$({dispatcher} issues resolve --number <ID>)"
TRACKER="$(jq -r '.tracker' <<<"$IDENTITY")"; NUMBER="$(jq -r '.number' <<<"$IDENTITY")"   # NUMBER is native: 12, or PROJ-12 on Jira
QUALIFIED="$(jq -r '.qualified' <<<"$IDENTITY")"   # FJ-12 — the routing key (always unambiguous)
DISPLAY="$(jq -r '.display' <<<"$IDENTITY")"       # #12 with one tracker, FJ-12 with several — what people read
PREFIX="$(jq -r '.branchPrefix' <<<"$IDENTITY")"   # 12 / fj-12 — the branch and worktree prefix
```

Log lines, commit scopes and your report name the issue by `$DISPLAY` — the same form as the
`<ID>` you were given, so the orchestrator can match them.

## Pre-made decisions (from orchestrator)

{pre_made_decisions}

If you hit a decision not covered here, use the **safety valve** — don't guess.

## Per-issue lifecycle (native working-an-issue, ×M)

For each issue, resolved as shown above, pass `--tracker "$TRACKER" --number "$NUMBER"` on every
issue and label call:

1. **Read the issue AND its comments — before anything else.** The plan you were handed was
   built from the issue *body*; the comment thread may have since changed the scope, the
   acceptance, or the decision. When a comment contradicts the body, **the later comment wins**.
   ```bash
   {dispatcher} issues get      --tracker "$TRACKER" --number "$NUMBER"
   {dispatcher} issues comments --tracker "$TRACKER" --number "$NUMBER"
   ```
   If the thread materially changes the issue from what the batch plan assumed, use the safety
   valve (below) rather than silently building to the new reading.
2. **Verify `{base_branch}` is current, then create the worktree off it** (anchored to
   `{repo_root}`, never to `$PWD`), and bind its path to `$WT` — every git command from here on is
   `git -C "$WT" …`. You run in parallel with sibling zones, so the base is the ref most likely to
   have moved under you — never fork from a stale local ref:
   ```bash
   if git -C "{repo_root}" remote get-url origin >/dev/null 2>&1 \
      && git -C "{repo_root}" fetch -q origin "{base_branch}"; then
       LOCAL="$(git -C "{repo_root}" rev-parse "{base_branch}")"
       REMOTE="$(git -C "{repo_root}" rev-parse "origin/{base_branch}")"
       MB="$(git -C "{repo_root}" merge-base "{base_branch}" "origin/{base_branch}")"
   else
       LOCAL=offline   # no origin, or the fetch failed
   fi
   ```
   - **Level** (`LOCAL` = `REMOTE`) → fork from `{base_branch}`. Note *"base {base_branch}:
     level with origin"*.
   - **Behind** (`LOCAL` = `MB`) → **fork from `origin/{base_branch}`** (simplest and safest
     while siblings run: don't move a shared local branch under them) and say how far behind it
     was. Never work from the stale ref.
   - **Ahead or diverged** (`REMOTE` = `MB`, or neither) → **STOP.** Do not create the worktree,
     do not `git pull`. Safety-valve with `status=blocked` and report the divergence.
   - **Offline / no origin** → warn, continue from local `{base_branch}`, and record the base as
     **UNVERIFIED** in the log line and in your finishing record.
   ```bash
   BRANCH="feature/$PREFIX-<slug>"
   git -C "{repo_root}" worktree add -b "$BRANCH" \
     "{repo_root}/.worktrees/$PREFIX-<slug>" "<the ref the check selected>"
   WT="{repo_root}/.worktrees/$PREFIX-<slug>"
   "$(dirname "{dispatcher}")/issue-identity.sh" remember --branch "$BRANCH" --identity "$IDENTITY"
   {dispatcher} issues set-status --tracker "$TRACKER" --number "$NUMBER" --status in-progress
   echo "$(date -u +%FT%TZ) {zone} ticket=$DISPLAY status=starting comments=<count> base=<level|ff-N|unverified>" >> {log_path}
   ```
3. **Work inside `$WT`, driving git there by path rather than by `cd`.** Re-read the issue's
   Acceptance section *as amended by the comments*;
   treat each bullet as a separate must-pass condition. Tests must pass after every commit; one
   commit per issue (small logical subcommits OK):
   ```bash
   git -C "$WT" status
   git -C "$WT" add <repo-relative path>      # paths resolve relative to $WT, not to your cwd
   git -C "$WT" commit -m "feat($DISPLAY): …"
   git -C "$WT" log --oneline -3
   ```
   Midway, optionally:
   ```bash
   echo "$(date -u +%FT%TZ) {zone} ticket=$DISPLAY status=working note=\"<short>\"" >> {log_path}
   ```
4. **Before declaring done — walk the user-visible surface.** Don't satisfy only the literal
   acceptance phrase; trace every related field/element a reporter would see. If the real scope
   is materially larger than the issue's framing, safety-valve instead of shipping a narrow read.
5. **Run the repo's check command** — the one printed under *Setup*, verbatim and in full — from
   `$WT`, in the foreground. Run it via `sh -c` from that path (`cd "$WT"` in a subshell) rather
   than trusting the shell's current directory. Skip this step only when *Setup* said
   `None configured.`
   Non-zero means the issue is not done: fix it on this branch, or safety-valve with the failing
   output if you can't fix it quickly. Do not move to the next issue on a red gate — a branch
   that fails the repo's own check is one the user cannot promote, and the orchestrator's sweep
   will find it anyway once you've returned and can no longer fix it.
6. **Hand to the merge gate (do NOT promote):**
   ```bash
   {dispatcher} issues set-status --tracker "$TRACKER" --number "$NUMBER" --status to-test
   # Write your finishing record (work summary + model/token note; see working-an-issue
   # for the format). If the repo has the prompt ledger on, append the measured block —
   # your subagent turns are rows under the parent session, so pass the parent's id:
   #   {dispatcher} prompt-log summary --session <parent session id> >> "{scratch}/done-$PREFIX.md"
   # It says "estimate only" when there are no rows; then note your own estimate.
   # The dispatcher owns stable-family derivation; tool/service ids
   # return non-zero and are skipped:
   PRIMARY_MODEL=<model-id-from-ledger>
   if FAMILY="$({dispatcher} labels model-family --id "$PRIMARY_MODEL")"; then
     {dispatcher} labels ensure --tracker "$TRACKER" --model "$PRIMARY_MODEL"
     {dispatcher} issues label-add --tracker "$TRACKER" --number "$NUMBER" --label "model/$FAMILY"
   fi
   {dispatcher} issues comment --tracker "$TRACKER" --number "$NUMBER" --body-file "{scratch}/done-$PREFIX.md" --model "$PRIMARY_MODEL"
   SHA=$(git -C "$WT" rev-parse --short HEAD)
   echo "$(date -u +%FT%TZ) {zone} ticket=$DISPLAY status=complete commit=$SHA" >> {log_path}
   ```
   Leave the worktree in place (unmerged) and move to the next issue. The user promotes serially
   later via `promoting-a-branch`.

## Safety valve (use it liberally)

Append `status=blocked` with a concrete question whenever you stall >15 min, hit an uncovered
judgment call, can't quickly fix breaking tests, or find the scope materially larger than
described:

```bash
echo "$(date -u +%FT%TZ) {zone} ticket=$DISPLAY status=blocked note=\"<short question>\"" >> {log_path}
```

Then stop and return. The orchestrator routes your question to the user and continues you with the
answer. Shipping 3 solid issues beats forcing 5 shaky ones.

## Universal hard rules (always)

- **No `git push`.** Branches stay local for user review.
- **Every git command is `git -C "$WT" …` (or `git -C "$ROOT" …` for worktree management). A
  bare `git` command is a bug, even if you think you're in the right directory.** Your shell's
  working directory persists across tool calls and you will `cd` around during a task; an
  unanchored `git commit` can land on the **wrong repository or the wrong branch** — e.g. onto
  the trunk in the main checkout instead of `feature/$PREFIX-<slug>`. Note that `git -C "$WT" add
  <path>` resolves `<path>` relative to `$WT`, not to your current directory: that is what you
  want, but it differs from a bare `git add` from a subdirectory, so pass repo-relative paths.
  `-C` does not help non-git tools — `cd`-dependent scripts and test runners still need an
  explicit path of their own.
- **No promotion / no merge to any stage.** Stop each issue at `to-test`.
- **Dispatcher only** for backend access (`{dispatcher} issues …`) — never curl or MCP.
- **Tests green after every commit** — and where the repo names a check command, that command is
  what "green" means here. Run it in the foreground; never background it.
- **Safety-valve on uncertainty** rather than guessing.
- **Never fork a feature branch from an unfetched `{base_branch}`**, and never `git pull` to
  "fix" a diverged one — stop and report.

## Repo-specific rules

{repo_rules}

## Final report (when the queue is complete OR you safety-valve)

Return a concise report: commits (`<SHA> <DISPLAY> <title>`), test deltas, judgment calls made without
asking, anything deferred/safety-valved (with a suggested follow-up). Then the final log line:

```bash
echo "$(date -u +%FT%TZ) {zone} ticket=all status=<done|safety-valved> note=\"<summary>\"" >> {log_path}
```
