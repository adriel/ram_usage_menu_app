#!/bin/bash
# Publishes a GitHub release that RAM Watch's auto-updater picks up.
#   1. Bump CFBundleShortVersionString (and CFBundleVersion) in Resources/Info.plist
#   2. Commit and push
#   3. ./release.sh "What changed"
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
NOTES="${1:-RAM Watch $VERSION}"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" >/dev/null 2>&1; then
  echo "$TAG already exists. Bump the version in Resources/Info.plist first." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit your changes first." >&2
  exit 1
fi

./build.sh
gh release create "$TAG" build/RAM-Watch.zip --title "RAM Watch $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)"
echo "Released $TAG"
