---
description: Show which flight plugin is loaded — its version, install and root — and whether the `flight` CLI on PATH matches
allowed-tools: Bash(bash:*)
disable-model-invocation: true
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/plugin-version.sh"`

Relay the report above to the user verbatim, in a code block. Do not run anything else, and do
not add a version from memory: the script read it from the loaded plugin's own manifest. If it
printed a `note:` line, keep it — that is the point of the command.
