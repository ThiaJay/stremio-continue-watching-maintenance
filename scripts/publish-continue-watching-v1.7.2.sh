#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="ccde52d4cd4071f768eba6b365c9fb16d5e02310"
DEPLOYMENT_PREFIX="bc84b08545c9"
VERSION="1.7.2"
TAG="v1.7.2"

test -f release-acceptance-v1.7.2.json
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("release-acceptance-v1.7.2.json","utf8"));
if(x.result!=="accepted") process.exit(2);
if(x.sourceCommit!=="ccde52d4cd4071f768eba6b365c9fb16d5e02310") process.exit(3);
if(x.deploymentPrefix!=="bc84b08545c9") process.exit(4);
if(x.reportedTargetAAccepted!==true) process.exit(5);
if(x.reportedTargetBAccepted!==true) process.exit(6);
if(x.priorExampleClear!==true) process.exit(7);
NODE

git cat-file -e "$SOURCE_COMMIT^{commit}"
git show "$SOURCE_COMMIT:package.json" > release-package.json
test "$(node -p "require('./release-package.json').version")" = "$VERSION"

git show "$SOURCE_COMMIT:CHANGELOG.md" > release-changelog.md
awk '
  /^## 1\.7\.2 / {capture=1; next}
  capture && /^## / {exit}
  capture {print}
' release-changelog.md > release-notes.md
test -s release-notes.md

if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  existing="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json targetCommitish --jq .targetCommitish)"
  test "$existing" = "$SOURCE_COMMIT"
  echo "release_already_exists_exact"
  exit 0
fi

gh release create "$TAG"   --repo "$GITHUB_REPOSITORY"   --target "$SOURCE_COMMIT"   --title "Continue Watching Maintenance $TAG"   --notes-file release-notes.md

echo "release_published"
