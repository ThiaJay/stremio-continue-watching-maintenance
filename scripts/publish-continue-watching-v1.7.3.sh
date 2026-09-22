#!/usr/bin/env bash
set -euo pipefail

PRODUCT_SOURCE_COMMIT="94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495"
DEPLOYMENT_PREFIX="ebb3a6b38626"
VERSION="1.7.3"
TAG="v1.7.3"

test -f release-acceptance-v1.7.3.json
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("release-acceptance-v1.7.3.json","utf8"));
if(x.result!=="accepted") process.exit(2);
if(x.version!=="1.7.3") process.exit(3);
if(x.sourceCommit!=="94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495") process.exit(4);
if(x.deploymentPrefix!=="ebb3a6b38626") process.exit(5);
for(const key of ["reportedTargetA","reportedTargetB","priorExample"]){
  const v=x[key]||{};
  if(Number(v.offset)!==0||Number(v.encryptedBackupCount)<1) process.exit(6);
}
if(x.verifiedUnrelatedStateProtection!==true) process.exit(7);
if(x.secretCleanupVerified!==true) process.exit(8);
NODE

git cat-file -e "$PRODUCT_SOURCE_COMMIT^{commit}"
git show "$PRODUCT_SOURCE_COMMIT:package.json" > accepted-package.json
git show "$PRODUCT_SOURCE_COMMIT:src/worker.js" > accepted-worker.js

test "$(node -p "require('./accepted-package.json').version")" = "$VERSION"
test "$(node -p "require('./package.json').version")" = "$VERSION"
cmp accepted-worker.js src/worker.js

accepted_hash="$(sha256sum accepted-worker.js | awk '{print $1}')"
current_hash="$(sha256sum src/worker.js | awk '{print $1}')"
test "$accepted_hash" = "$current_hash"

git show "$PRODUCT_SOURCE_COMMIT:CHANGELOG.md" > accepted-changelog.md
awk '
  /^## 1\.7\.3 / {capture=1; next}
  capture && /^## / {exit}
  capture {print}
' accepted-changelog.md > release-notes.md
test -s release-notes.md

: "${GH_TOKEN:?}"
printf 'release_check\n' > release-stage.txt
if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  existing="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json targetCommitish --jq .targetCommitish)"
  current="$(git rev-parse HEAD)"
  test "$existing" = "$current"
  printf 'passed\n' > release-stage.txt
  echo "release_already_exists_exact"
  exit 0
fi

printf 'release_create\n' > release-stage.txt
gh release create "$TAG" \
  --repo "$GITHUB_REPOSITORY" \
  --target "$GITHUB_SHA" \
  --title "Continue Watching Maintenance $TAG" \
  --notes-file release-notes.md

printf 'verify_release\n' > release-stage.txt
created_target="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json targetCommitish --jq .targetCommitish)"
test "$created_target" = "$GITHUB_SHA"
printf '%s\n' "$accepted_hash" > release-product-source-hash.txt
printf '%s\n' "$GITHUB_SHA" > release-packaging-commit.txt
printf 'passed\n' > release-stage.txt
echo "release_published"
