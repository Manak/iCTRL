#!/usr/bin/env bash
# Pull a new upstream iCTRL release into the claude-bridge branch.
#
#   ClaudeBridge/scripts/sync-upstream.sh            # merge the newest upstream tag
#   ClaudeBridge/scripts/sync-upstream.sh v1.99.0    # merge a specific tag/ref
#   ClaudeBridge/scripts/sync-upstream.sh upstream/main
#
# What it does:
#   1. fetches upstream (branches + tags)
#   2. fast-forwards local main to upstream/main and pushes it to your fork
#      (main is a pure mirror; it refuses if main has diverged)
#   3. merges the chosen ref into claude-bridge with a merge commit
#   4. on conflict, lists the conflicted files and the hook markers to look at
#
# It never pushes claude-bridge; you do that after rebuilding and testing.
set -euo pipefail

BRANCH="claude-bridge"
MIRROR="main"
MARKER="CLAUDE-BRIDGE HOOK"

cd "$(git rev-parse --show-toplevel)"

die() { echo "error: $*" >&2; exit 1; }

git remote get-url upstream >/dev/null 2>&1 \
  || die "no 'upstream' remote. Run: git remote add upstream https://github.com/OpenMinis/iCTRL.git"
# `make build` rewrites the build stamp; that is never a change worth keeping.
git checkout -- iCTRLKit/BuildStamp.swift 2>/dev/null || true
[ -z "$(git status --porcelain)" ] \
  || die "working tree is not clean. Commit or stash first."
[ ! -e .git/MERGE_HEAD ] || die "a merge is already in progress."

echo "==> Fetching upstream"
git fetch upstream --tags --prune

echo "==> Updating $MIRROR (mirror of upstream/main)"
if git merge-base --is-ancestor "$MIRROR" upstream/main; then
  if [ "$(git branch --show-current)" = "$MIRROR" ]; then
    git merge --ff-only upstream/main
  else
    git branch -f "$MIRROR" upstream/main
  fi
  git push origin "$MIRROR" --tags || echo "warning: could not push $MIRROR to origin (continuing)"
else
  die "$MIRROR has commits that are not in upstream/main. main must stay untouched; move those commits to $BRANCH."
fi

# Newest upstream tag by version order, unless a ref was given.
TARGET="${1:-$(git tag --list 'v*' --sort=-v:refname --merged upstream/main | head -n1)}"
[ -n "$TARGET" ] || die "no upstream tag found; pass a ref explicitly."
git rev-parse --verify --quiet "$TARGET^{commit}" >/dev/null || die "unknown ref: $TARGET"

if git merge-base --is-ancestor "$TARGET" "$BRANCH"; then
  echo "==> $BRANCH already contains $TARGET. Nothing to do."
  exit 0
fi

echo "==> Merging $TARGET into $BRANCH"
git switch "$BRANCH"
if git merge --no-ff -m "Merge upstream $TARGET into $BRANCH" "$TARGET"; then
  echo
  echo "Merged cleanly."
else
  echo
  echo "Conflicts in:"
  git diff --name-only --diff-filter=U | sed 's/^/  /'
  echo
  echo "Every bridge edit to an upstream file is marked '$MARKER' and listed in"
  echo "CLAUDE_BRIDGE_CHANGES.md. Keep upstream's version of the surrounding code"
  echo "and re-apply the marked line(s). Then: git add <files> && git commit"
  echo "(or back out with: git merge --abort)"
  exit 1
fi

echo
echo "Hook points still present after the merge:"
git grep -n "$MARKER" -- . ':!ClaudeBridge' ':!CLAUDE_BRIDGE_CHANGES.md' || echo "  (none yet)"
echo
echo "Next: compare the list above with CLAUDE_BRIDGE_CHANGES.md, then rebuild and test:"
echo "  make ipa"
echo "  git push origin $BRANCH"
