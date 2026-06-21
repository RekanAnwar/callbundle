#!/usr/bin/env bash
#
# Cut a release.
#
# Reads the version from the app-facing package (callbundle/pubspec.yaml) and
# creates + pushes an annotated `v<version>` tag. Because the tag is pushed with
# YOUR git credentials (not the CI GITHUB_TOKEN), it triggers
# `.github/workflows/publish.yml`, which publishes every package whose pubspec
# version matches the tag to pub.dev via OIDC. No PAT or stored secret required.
#
# Usage:
#   tool/release.sh            # tag the current callbundle version and push
#   DRY_RUN=1 tool/release.sh  # print what would happen, push nothing
#
# Prerequisites:
#   * All package versions bumped and committed on main.
#   * Each package has automated publishing enabled on pub.dev (Admin tab) with
#     tag pattern `v{{version}}`.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(grep -E '^version:' callbundle/pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//' | tr -d '[:space:]')"
if [ -z "$VERSION" ]; then
  echo "error: could not read version from callbundle/pubspec.yaml" >&2
  exit 1
fi
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean; commit or stash changes first." >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "warning: you are on '$CURRENT_BRANCH', not 'main'." >&2
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists locally." >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin." >&2
  exit 1
fi

if [ "${DRY_RUN:-0}" != "0" ]; then
  echo "[dry run] would create and push tag $TAG"
  exit 0
fi

echo "Creating and pushing $TAG ..."
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"
echo "Done. Track publishing at:"
echo "  https://github.com/Ikolvi/callbundle/actions/workflows/publish.yml"
