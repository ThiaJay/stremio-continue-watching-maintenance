#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="4fd9fed12e3590cf2f26b655f00c46cf2ad8c216"
DEPLOYMENT_PREFIX="23ad2f4e6135"
VERSION="1.7.0"
TAG="v1.7.0"

test -f release-acceptance-v1.7.0.json
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("release-acceptance-v1.7.0.json","utf8"));
if(x.result!=="accepted") process.exit(2);
if(x.sourceCommit!=="4fd9fed12e3590cf2f26b655f00c46cf2ad8c216") process.exit(3);
if(x.deploymentPrefix!=="23ad2f4e6135") process.exit(4);
if(x.breakingBadAccepted!==true) process.exit(5);
if(x.theNextStepClear!==true) process.exit(6);
if(x.northernIrelandClear!==true) process.exit(7);
NODE

git cat-file -e "$SOURCE_COMMIT^{commit}"
git show "$SOURCE_COMMIT:package.json" > release-package.json
test "$(node -p "require('./release-package.json').version")" = "$VERSION"

git show "$SOURCE_COMMIT:CHANGELOG.md" > release-changelog.md
awk '
  /^## 1\.7\.0 / {capture=1; next}
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
