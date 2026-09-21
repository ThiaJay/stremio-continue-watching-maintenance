#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="168a03e62bb370620e353738a0359eba2bcf2c4c"
DEPLOYMENT_PREFIX="798d5f049c39"
VERSION="1.6.8"
TAG="v1.6.8"

test -f release-acceptance-v1.6.8.json
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("release-acceptance-v1.6.8.json","utf8"));
if(x.result!=="accepted") process.exit(2);
if(x.sourceCommit!=="168a03e62bb370620e353738a0359eba2bcf2c4c") process.exit(3);
if(x.deploymentPrefix!=="798d5f049c39") process.exit(4);
if(x.exactItemAccepted!==true) process.exit(5);
NODE

git cat-file -e "$SOURCE_COMMIT^{commit}"
git show "$SOURCE_COMMIT:package.json" > release-package.json
test "$(node -p "require('./release-package.json').version")" = "$VERSION"

git show "$SOURCE_COMMIT:CHANGELOG.md" > release-changelog.md
awk '
  /^## 1\.6\.8 / {capture=1; next}
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
