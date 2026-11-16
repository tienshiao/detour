#!/bin/zsh
# Serializes runtime UI sessions (launching Detour, posting input, capturing) across agents.
# usage: scripts/screen-lock.sh acquire <who>   (waits)   |   release   |   status
# The lock lives in the main checkout's git-ignored .claude/scratch, shared by every worktree.
ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd) || exit 2
mkdir -p "$ROOT/.claude/scratch"
LOCK="$ROOT/.claude/scratch/screen.lock"
case "$1" in
  acquire) while ! mkdir "$LOCK" 2>/dev/null; do echo "[screen-lock] held by $(cat $LOCK/owner 2>/dev/null), waiting"; /bin/sleep 30; done
           echo "${2:-unknown} $(date +%T)" > "$LOCK/owner"; echo "[screen-lock] acquired by ${2:-unknown}";;
  release) rm -f "$LOCK/owner"; rmdir "$LOCK" && echo "[screen-lock] released";;
  status)  cat "$LOCK/owner" 2>/dev/null || echo free;;
  *)       echo "usage: screen-lock.sh acquire <who> | release | status"; exit 2;;
esac
