#!/bin/zsh
# Serializes xcodebuild across worktrees: one build/test at a time on this Mac.
# usage: scripts/xcb-locked.sh <xcodebuild args...>
# The lock lives in the main checkout's git-ignored .claude/scratch, so every
# worktree (and any older copy of this script) shares it.
ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd) || exit 2
mkdir -p "$ROOT/.claude/scratch"
LOCK="$ROOT/.claude/scratch/xcodebuild.lock"
while ! mkdir "$LOCK" 2>/dev/null; do /bin/sleep 20; done
trap 'rmdir "$LOCK"' EXIT INT TERM
echo "[xcb-locked] lock taken $(date +%T) in $PWD"
caffeinate -d -i xcodebuild "$@"
