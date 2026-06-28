#!/usr/bin/env bash
#
# Tear down the disposable Forgejo and remove its data volume + the workdir.
set -euo pipefail
RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
( cd "$RIG_DIR" && docker compose down -v )
rm -rf "$RIG_DIR/.work"
printf '\033[32m✓ Rig torn down (container, volume, and workdir removed).\033[0m\n'
