# Security policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately by email to **dave@cerebralgardens.com** with `SECURITY` in the subject
line. Include enough for us to reproduce it: the plugin and version, the harness (Claude Code
or Codex), the backend involved, and the steps or proof-of-concept.

You can expect an acknowledgement within a few days. We will confirm the issue, agree a fix
and a disclosure timeline with you, and credit you in the changelog unless you would rather
stay anonymous.

**Never include a real API token, `.flightdirector/secrets.json`, or any other live
credential in a report.** If you believe a token has been exposed, revoke it on your forge
first, then tell us.

## Supported versions

This project is pre-1.0 and moves fast: fixes land on the latest released version of the
affected plugin. There are no long-term support branches.

## Scope

These plugins run inside an agent session on your own machine and talk to *your* forge. The
things worth reporting:

- **Credential handling** — anything that could write a token from
  `.flightdirector/secrets.json` into a log, a commit, an issue body, a PR, or a request to
  a host other than your configured backend.
- **Command or argument injection** — issue titles, branch names, labels, or API responses
  that escape into a shell command run by the dispatcher or a skill.
- **Unintended writes** — a path by which a skill pushes, merges, or force-updates a branch
  without the explicit human gate the workflow requires.

Out of scope: vulnerabilities in Claude Code, Codex, or your forge itself (report those to
their maintainers), and anything that requires an attacker to already control your machine or
your agent's instructions.
