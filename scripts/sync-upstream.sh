#!/usr/bin/env bash
# Replays Skyward's commits on top of the latest upstream main.
#
# `main` mirrors upstream/main and never carries our commits. `skyward` is `main`
# plus our patch stack, which is always exactly `git log main..skyward`. A sync
# fast-forwards `main` to upstream, rebases `skyward` onto it, and pushes both.
#
# Usage:
#   scripts/sync-upstream.sh status      # what upstream added, and our patch stack
#   scripts/sync-upstream.sh [sync]      # fetch, replay our commits, push
#   scripts/sync-upstream.sh sync --no-push
#   scripts/sync-upstream.sh push        # push after resolving rebase conflicts
#   scripts/sync-upstream.sh abort       # undo an unfinished sync

# OLD_MIRROR, OLD_WORK, ORIGIN_WORK and BACKUP_TAG come from read_state.
# shellcheck disable=SC2153
set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/ColeMurray/background-agents.git"
ORIGIN_REMOTE="origin"
MIRROR_BRANCH="main"
WORK_BRANCH="skyward"

GIT_DIR="$(git rev-parse --absolute-git-dir)"
STATE_FILE="$GIT_DIR/skyward-sync.env"

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

ensure_setup() {
  if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    info "Adding $UPSTREAM_REMOTE remote ($UPSTREAM_URL)"
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  fi
  git remote set-url --push "$UPSTREAM_REMOTE" NO_PUSH_TO_UPSTREAM
  # rerere replays conflict resolutions we already made in earlier syncs.
  git config rerere.enabled true
  git config rerere.autoupdate true
}

rebase_in_progress() {
  [[ -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]
}

require_clean_tree() {
  rebase_in_progress && die "a rebase is in progress; finish it ('git rebase --continue') and run '$0 push', or run '$0 abort'"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "working tree has uncommitted changes; commit or stash them first"
  fi
}

fetch_all() {
  info "Fetching $UPSTREAM_REMOTE and $ORIGIN_REMOTE"
  git fetch --quiet "$UPSTREAM_REMOTE" "$MIRROR_BRANCH"
  git fetch --quiet "$ORIGIN_REMOTE" "$MIRROR_BRANCH" "$WORK_BRANCH"
}

print_patch_stack() {
  local base="$1" tip="$2"
  echo "Our patch stack ($(git rev-list --count --no-merges "$base..$tip") commits, $base..$tip):"
  git log --no-merges --reverse --format='  %h %s' "$base..$tip"
}

cmd_status() {
  ensure_setup
  fetch_all
  local upstream="$UPSTREAM_REMOTE/$MIRROR_BRANCH"
  local origin_work="$ORIGIN_REMOTE/$WORK_BRANCH"
  local base
  base="$(git rev-parse --short "$(git merge-base "$origin_work" "$upstream")")"
  local behind
  behind="$(git rev-list --count --no-merges "$base..$upstream")"
  echo
  echo "Upstream commits not yet in $WORK_BRANCH: $behind"
  if [[ "$behind" -gt 0 ]]; then
    git log --no-merges --reverse --format='  %h %ad %s' --date=short "$base..$upstream"
  fi
  echo
  print_patch_stack "$base" "$origin_work"
}

# Records what the sync started from, so `push` and `abort` work after a
# conflicted rebase.
write_state() {
  cat >"$STATE_FILE" <<EOF
OLD_MIRROR=$1
OLD_WORK=$2
ORIGIN_WORK=$3
BACKUP_TAG=$4
EOF
}

read_state() {
  [[ -f "$STATE_FILE" ]] || die "no sync in progress (missing $STATE_FILE)"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

cmd_sync() {
  local push=true
  for arg in "$@"; do
    case "$arg" in
      --no-push) push=false ;;
      *) die "unknown option: $arg" ;;
    esac
  done

  ensure_setup
  require_clean_tree
  fetch_all

  local upstream="$UPSTREAM_REMOTE/$MIRROR_BRANCH"
  local origin_work="$ORIGIN_REMOTE/$WORK_BRANCH"
  local origin_work_sha
  origin_work_sha="$(git rev-parse "$origin_work")"

  git merge-base --is-ancestor "$MIRROR_BRANCH" "$upstream" ||
    die "local $MIRROR_BRANCH has commits that are not in $upstream; it must only mirror upstream"
  git merge-base --is-ancestor "$ORIGIN_REMOTE/$MIRROR_BRANCH" "$upstream" ||
    die "$ORIGIN_REMOTE/$MIRROR_BRANCH has commits that are not in $upstream; it must only mirror upstream"

  # Start from the published skyward. Unpushed local commits would be force-pushed
  # without review, so they must go through a pull request first.
  git checkout --quiet "$WORK_BRANCH"
  if ! git merge-base --is-ancestor "$WORK_BRANCH" "$origin_work"; then
    die "local $WORK_BRANCH has commits that are not on $origin_work; open a pull request for them first"
  fi
  git merge --quiet --ff-only "$origin_work"

  local old_mirror old_work
  old_mirror="$(git merge-base "$WORK_BRANCH" "$upstream")"
  old_work="$(git rev-parse "$WORK_BRANCH")"

  if [[ "$old_mirror" == "$(git rev-parse "$upstream")" ]]; then
    info "$WORK_BRANCH already contains everything in $upstream"
    git branch --quiet --force "$MIRROR_BRANCH" "$upstream"
    if $push; then
      git push --quiet "$ORIGIN_REMOTE" "$MIRROR_BRANCH"
    fi
    print_patch_stack "$MIRROR_BRANCH" "$WORK_BRANCH"
    return
  fi

  local incoming
  incoming="$(git rev-list --count --no-merges "$old_mirror..$upstream")"
  info "Upstream added $incoming commits; replaying our commits on top"

  local backup_tag
  backup_tag="sync-backup/$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short "$old_work")"
  git tag "$backup_tag" "$old_work"
  info "Saved the previous $WORK_BRANCH as tag $backup_tag"
  write_state "$old_mirror" "$old_work" "$origin_work_sha" "$backup_tag"

  git branch --quiet --force "$MIRROR_BRANCH" "$upstream"

  if ! git rebase "$MIRROR_BRANCH"; then
    cat >&2 <<EOF

Rebase stopped on a conflict. To finish:
  1. Resolve the conflicted files and 'git add' them.
  2. Run 'git rebase --continue' (repeat until the rebase completes).
  3. Run '$0 push'.
To undo the whole sync instead, run '$0 abort'.
EOF
    exit 1
  fi

  finish "$push"
}

# Shows how each of our commits changed in the replay, then pushes.
finish() {
  local push="$1"
  read_state
  echo
  info "Patch stack before -> after (=: unchanged, !: changed while replaying, <: dropped, >: new)"
  git range-diff --no-color --no-patch "$OLD_MIRROR..$OLD_WORK" "$MIRROR_BRANCH..$WORK_BRANCH" || true
  echo
  print_patch_stack "$MIRROR_BRANCH" "$WORK_BRANCH"

  if ! $push; then
    echo
    info "Not pushed. Review, then run '$0 push'."
    return
  fi

  info "Pushing $MIRROR_BRANCH and $WORK_BRANCH to $ORIGIN_REMOTE"
  git push --quiet "$ORIGIN_REMOTE" "$MIRROR_BRANCH"
  # The lease fails if someone pushed to skyward after this sync started.
  git push --quiet --force-with-lease="refs/heads/$WORK_BRANCH:$ORIGIN_WORK" "$ORIGIN_REMOTE" "$WORK_BRANCH"
  rm -f "$STATE_FILE"
  info "Done. The previous $WORK_BRANCH is kept locally as tag $BACKUP_TAG"
}

cmd_push() {
  rebase_in_progress && die "the rebase is not finished; run 'git rebase --continue' first"
  read_state
  [[ "$(git branch --show-current)" == "$WORK_BRANCH" ]] || die "check out $WORK_BRANCH first"
  git merge-base --is-ancestor "$MIRROR_BRANCH" "$WORK_BRANCH" ||
    die "$WORK_BRANCH is not based on $MIRROR_BRANCH; the rebase did not complete"
  finish true
}

cmd_abort() {
  read_state
  if rebase_in_progress; then
    git rebase --abort
  fi
  git checkout --quiet "$WORK_BRANCH"
  git reset --quiet --hard "$OLD_WORK"
  git branch --quiet --force "$MIRROR_BRANCH" "$ORIGIN_REMOTE/$MIRROR_BRANCH"
  git tag --delete "$BACKUP_TAG" >/dev/null
  rm -f "$STATE_FILE"
  info "Restored $WORK_BRANCH to $OLD_WORK; nothing was pushed"
}

case "${1:-sync}" in
  status) cmd_status ;;
  sync) shift || true; cmd_sync "$@" ;;
  --no-push) cmd_sync "$@" ;;
  push) cmd_push ;;
  abort) cmd_abort ;;
  -h | --help | help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (try '$0 help')" ;;
esac
