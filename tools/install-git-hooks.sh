#!/usr/bin/env bash
# install-git-hooks.sh: install the pre-push secret-scan hook into this repository's hooks
# directory (the git common dir, so every worktree gets it). Idempotent; only the pre-push
# hook is touched. Run it once after cloning if you want the check on every push:
#   tools/install-git-hooks.sh
set -eu
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOKS=$(git -C "$REPO_ROOT" rev-parse --git-path hooks)
case "$HOOKS" in /*) ;; *) HOOKS="$REPO_ROOT/$HOOKS" ;; esac
mkdir -p "$HOOKS"
install -m 0755 "$REPO_ROOT/tools/hooks/pre-push" "$HOOKS/pre-push"
echo "installed $HOOKS/pre-push"
