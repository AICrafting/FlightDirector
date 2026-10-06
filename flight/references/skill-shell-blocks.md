# Shell in skill blocks

The shell in a SKILL.md fenced block is the product: an agent runs it, and when it is wrong the
failure lands on a user's integration branch. `shellcheck` never opens a `.md`, and running it on
the extracted blocks would not help much. The #209 pre-merge gate drew 17 review findings in three
rounds, and about one of them was a syntax problem. The rest were valid shell that did the wrong
thing: a slash in a file name, a `# STOP` comment that stopped nothing.

So this reference names the shapes those findings took, as rules an author and a reviewer can
both check. Each rule has a check in `scripts/tests/skill-shell-blocks.test.sh`, which runs over
every fenced shell block in `flight/` (fences with no language, `bash` or `sh`). Each check first
proves it fires on the defect it exists for, so a green run means the rule held, not that the
check missed.

## How a block runs

Read every block as its own tool call: a fresh shell that knows only what the agent types into it.
Variables from an earlier block are gone. Step 1's bindings are restated where needed, so Step 1
binds only values that can be derived again (`$MAIN`, `$BASE`), never a verdict.

Pseudo-code is fine, as long as it can't be mistaken for shell: `for each candidate … :`,
`record SKIPPED(…)`, `<placeholder>`. The checks pass it through untouched.

## The rules

### 1. Flatten a ref before it names a file (`flatten`)

A branch name has a slash in it, so `"$SCRATCH/preflight-$BRANCH.log"` names a file in a directory
that doesn't exist. In #223 that made a passing gate read as red on every feature branch. Name the
file from a flattened value instead: `SAFE_BRANCH="$(printf '%s' "$BRANCH" | tr '/' '-')"`, the
issue's `$QUALIFIED` or `$PREFIX`, the zone, or `${B#feature/}`.

*Checked:* a word that names a file (under `$SCRATCH`, a redirect target, a `.worktrees/` path, or
a `.log`/`.json`/`.md`/`.txt`) may not contain `$B`, `$BRANCH`, `$INT` or `$BASE` whole.

### 2. A refusal is a mechanism, not a sentence (`stop`)

`# STOP. Do not merge.` is a comment, and the `git merge` after the `fi` runs anyway. Echoing STOP
to stderr doesn't stop anything either. When a failure arm has to stop work, either:

- end the arm in `exit`, `return`, `continue` (inside a loop) or `break`, or
- put the guarded work inside another arm of the same `if`, so that it can't run when the guard
  fails.

A guard alone in its own block guards nothing in the next block, because the next block is a new
shell. Put the check and the work it protects in one block. The `pr` hop in promoting-a-branch
checks that the source branch is pushed, checks the gate's verdict, then runs `pr open`, all in
one `if … elif … else`.

*Checked:* an `if` arm or `||` arm that says STOP or halt, with no `exit`/`return`/`continue`/
`break`, is a finding. The exception is an `if` arm that has a sibling arm doing real work.

### 3. A guard covers every site, and the count is stated (`guard`)

When a guard is added for one operation, apply it at every place that performs that operation, and
say how many places that is. In #209 the preflight gate was honoured at the `direct`-hop merges
and missed on the `pr` hop, the more common configuration. The skill's own wording states the
count ("the two `direct`-hop sites above").

*Checked:* in the promoting skills, every `git … push` and `pr open` comes after a
`flight preflight run` or `flight preflight check` in the same block. The test also asserts how
many such sites exist (six today), so adding or removing a site is a decision someone has to make.
Behaviourally, `promote-gate.test.sh` runs every site against every gate case.

### 4. State that crosses a block lives in a file; a loop keyword needs its loop (`loop`)

A verdict a later block acts on goes in a file under `$SCRATCH`, written by the block that decides
it and read by the block that acts on it. A variable set in one block is empty in the next.
`continue` and `break` belong to a loop in the same block. In FJ-231, a `continue` with no loop
around it printed a warning, returned 0, and fell through to the push.

*Checked:* `continue` or `break` in a block with no `for`, `while` or `until`. The file-carried
verdict is pinned by running the real blocks one shell at a time: `promote-gate.test.sh`,
`promote-branches-gate.test.sh` and `to-test-gate.test.sh`.

### 5. No command hidden in a string (`string`)

Run a command as one plain line. Never write `sh -c "$GATE"` or `eval`. Claude Code's safety check
can't read inside the string and may stop to ask, which an unattended run can't answer (FJ-307).
When a configured command has to run, give it a dispatcher verb, the way `flight preflight run`
does. This is the same rule [runtime.md](runtime.md) gives agents for the commands they write
themselves.

*Checked:* `sh -c "$…`, `bash -c "$…` and `eval`.

### 6. bash 3.2 is the floor (`bash32`)

The macOS and MSYS legs run bash 3.2, so a block can't rely on bash 4: no `declare -A`, `mapfile`,
`readarray`, `${x,,}`, `${x^^}`, `&>>` or `|&`. When a glob may match more than once, use the
positional parameters (`set -- "$ROOT/.worktrees/$PREFIX"-*`; see queue-batches).

*Checked:* each of those spellings.

## Adding a rule

Every rule here has a check, and every check has a fixture showing it fires. The test fails when a
rule is stated without a check, or a check exists for a rule that isn't stated. A new rule comes
with:

- its heading here, numbered and ending in its check's name in backticks;
- a check in `skill-shell-blocks.test.sh`;
- a fixture holding the defect it exists for;
- a pass over the current skills.

Keep checks narrow: one named shape each. A general linter over every skill block mostly reports
pseudo-code, and a green badge over a broken gate is worse than no badge. When a rule protects a
gate, the strongest pin runs the real block: lift it out of the skill and run it against fakes, the
way the three `*-gate.test.sh` tests do.
