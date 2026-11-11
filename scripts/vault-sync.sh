#!/bin/bash
# Two-way sync between the vault on this server and its git remote.
# Meant for cron, every 2 minutes.
#
# ORDER MATTERS:
#   wrong: pull --rebase -> commit -> push
#   right: commit -> pull --rebase -> push
# Something is always writing to the vault (the MCP server, vault-writer).
# If a file changes between two runs the working tree is dirty and
# `pull --rebase` refuses with "cannot pull with rebase: You have unstaged
# changes". Committing first means the rebase always sees a clean tree.
#
# WHY THE LOCK: 720 runs a day. Without it a slow pull lets the next run
# start on top of the previous one. `flock -n` makes the second one give up
# quietly; it gets another chance in 2 minutes.
#
# WHY CHECK FOR A REBASE: if a rebase stops on a conflict the repo stays in
# that state and every later run fails silently, so sync stops and nobody
# notices. Here it becomes a loud exit 1 in the log.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-/opt/vault}"
BRANCH="${VAULT_BRANCH:-main}"

exec 9>/run/vault-sync.lock
flock -n 9 || exit 0

cd "$VAULT_DIR" || exit 1

if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
  echo "$(date '+%F %T') ABORTED: repo is mid-rebase, resolve by hand"
  exit 1
fi

# 1. commit whatever was written since the last run
if [[ -n $(git status --porcelain) ]]; then
  git add -A
  git commit -m "sync: $(date '+%Y-%m-%d %H:%M:%S')" --quiet
fi

# 2. only then integrate the remote (clean tree, rebase will not refuse)
if ! git pull --rebase origin "$BRANCH" --quiet; then
  echo "$(date '+%F %T') FAILED: git pull --rebase"
  git rebase --abort 2>/dev/null
  exit 1
fi

# 3. push, if there is anything to push
if [ "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" -gt 0 ]; then
  if ! git push origin "$BRANCH" --quiet; then
    echo "$(date '+%F %T') FAILED: git push"
    exit 1
  fi
fi

# 4. housekeeping. Loose objects pile up fast at this cadence. `gc --auto`
# is a no-op until git's own threshold is crossed, so it is cheap here.
git gc --auto --quiet 2>/dev/null
