#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 O.S. Systems Software LTDA.
#
# Sync smpmgr's integration branch from upstream and validate it.
#
#   1. Mirror upstream (intercreate/smpmgr) main -> origin main (ff-only).
#   2. Rebuild the candidate: cherry-pick the OSSystems patches (the commits on
#      main-ossystems past the upstream fork point) onto the freshly-synced
#      upstream/main.
#   3. If a patch conflicts -> park the partial rebase on a single sync-broken
#      branch and abort with a clear error; main-ossystems-next is untouched.
#   4. If the rebase is clean -> run the full freedom-zephyr validation suite
#      against the candidate (scripts/freedom-zephyr-validate.sh).
#   5. Promote main-ossystems-next ONLY if the validation passes. A clean rebase
#      that fails validation does NOT advance main-ossystems-next.
#
# Pushing is gated behind PUSH=1 (set by CI). PUSH=0 (default) does a full local
# dry run: sync/rebase/validate with no remote writes.
#
# Branch model (mirrors the sibling smp repo):
#   origin    = OSSystems/smpmgr        (this fork)
#   upstream  = intercreate/smpmgr      (original)
#   main                = mirror of upstream/main (ff-only)
#   main-ossystems      = downstream patches (never rewritten; the fork point)
#   main-ossystems-next = main + OSSystems patches (rebuilt here)

set -euo pipefail

PUSH="${PUSH:-0}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/intercreate/smpmgr.git}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
err()  { printf '\n\033[1;31m::error::\033[0m %s\n' "$*" >&2; }
warn() { printf '\n\033[1;33m::warning::\033[0m %s\n' "$*" >&2; }
push() {  # echo + run a git push only when PUSH=1
  if [ "$PUSH" = "1" ]; then git push "$@"; else
    printf 'DRY-RUN (PUSH=0): would: git push %s\n' "$*"
  fi
}

cd "$REPO_ROOT"

# --- 0. Configure git + fetch refs ------------------------------------------

log "Configuring git and fetching refs"
git config user.name  "${GIT_USER_NAME:-github-actions[bot]}"
git config user.email "${GIT_USER_EMAIL:-github-actions[bot]@users.noreply.github.com}"

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi

git fetch --no-tags upstream main
git fetch --no-tags origin main main-ossystems main-ossystems-next \
  || git fetch --no-tags origin main main-ossystems

# --- 1. Sync main from upstream (fast-forward mirror) ------------------------

log "Syncing origin/main from upstream/main (ff-only)"
push origin "upstream/main:refs/heads/main"
echo "main is at $(git rev-parse --short upstream/main)"

# --- 2. Rebuild candidate (rebase OSSystems patches onto upstream/main) ------

log "Rebuilding candidate"
FORK="$(git merge-base origin/main-ossystems upstream/main)"
echo "Fork point: $FORK"

git checkout -B sync-candidate upstream/main

FAILED_SHA=""
for sha in $(git rev-list --reverse "$FORK..origin/main-ossystems"); do
  if git cherry-pick -x "$sha"; then
    continue
  fi
  # Distinguish 'already upstream' (empty) from a genuine conflict.
  if git diff --quiet && git diff --cached --quiet; then
    git cherry-pick --skip
    continue
  fi
  FAILED_SHA="$sha"
  git cherry-pick --abort
  break
done

CANDIDATE_SHA="$(git rev-parse HEAD)"

# --- 3. Conflict -> quarantine on sync-broken and abort ----------------------

if [ -n "$FAILED_SHA" ]; then
  SUBJECT="$(git log -1 --format=%s "$FAILED_SHA")"
  warn "cherry-pick conflict on ${FAILED_SHA} ${SUBJECT}"
  git commit --allow-empty \
    -m "CONFLICT: cherry-pick stopped at ${FAILED_SHA} ${SUBJECT}"
  push origin "sync-candidate:refs/heads/sync-broken" --force
  err "Rebase failed at ${FAILED_SHA} - parked on sync-broken;" \
      "main-ossystems-next untouched"
  exit 1
fi

# No-op guard: nothing to do if the candidate already matches the published
# integration branch.
if git rev-parse --verify -q origin/main-ossystems-next >/dev/null \
   && git diff --quiet sync-candidate origin/main-ossystems-next; then
  log "main-ossystems-next already up to date (${CANDIDATE_SHA}); nothing to do"
  exit 0
fi

# --- 4. Validate the candidate against freedom-zephyr ------------------------

log "Validating candidate ${CANDIDATE_SHA} against freedom-zephyr"
if ! SMPMGR_DIR="$REPO_ROOT" "$REPO_ROOT/scripts/freedom-zephyr-validate.sh"; then
  err "Validation FAILED for candidate ${CANDIDATE_SHA};" \
      "main-ossystems-next NOT advanced"
  exit 1
fi

# --- 5. Promote (only after clean rebase AND green validation) ---------------

log "Promoting main-ossystems-next -> ${CANDIDATE_SHA}"
push origin "sync-candidate:refs/heads/main-ossystems-next" --force
push origin --delete sync-broken || true
log "Done. main-ossystems-next is ${CANDIDATE_SHA}"
