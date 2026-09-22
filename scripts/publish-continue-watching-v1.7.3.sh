#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495"
DEPLOYMENT_PREFIX="6bf183a720ec"
VERSION="1.7.3"
TAG="v1.7.3"

test -f release-acceptance-v1.7.3.json
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("release-acceptance-v1.7.3.json","utf8"));
if(x.result!=="accepted") process.exit(2);
if(x.version!=="1.7.3") process.exit(3);
if(x.sourceCommit!=="94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495") process.exit(4);
if(x.deploymentPrefix!=="6bf183a720ec") process.exit(5);
for(const key of ["reportedTargetA","reportedTargetB","priorExample"]){
  const v=x[key]||{};
  if(Number(v.offset)!==0||Number(v.encryptedBackupCount)<1) process.exit(6);
}
if(x.verifiedUnrelatedStateProtection!==true) process.exit(7);
NODE

git cat-file -e "$SOURCE_COMMIT^{commit}"
git show "$SOURCE_COMMIT:package.json" > release-package.json
test "$(node -p "require('./release-package.json').version")" = "$VERSION"

git show "$SOURCE_COMMIT:CHANGELOG.md" > release-changelog.md
awk '
  /^## 1\.7\.3 / {capture=1; next}
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
