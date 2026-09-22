#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495"
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

: "${GH_TOKEN:?}"
api="https://api.github.com/repos/$GITHUB_REPOSITORY"
auth=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

printf 'release_check\n' > release-stage.txt
release_http="$(curl -sS -o existing-release.json -w '%{http_code}' "${auth[@]}" "$api/releases/tags/$TAG")"
if [ "$release_http" = "200" ]; then
  existing_tag="$(node -e 'const x=require("./existing-release.json");process.stdout.write(String(x.tag_name||""))')"
  test "$existing_tag" = "$TAG"
  printf 'passed\n' > release-stage.txt
  echo "release_already_exists_exact"
  exit 0
fi
test "$release_http" = "404"

printf 'release_create\n' > release-stage.txt
export RELEASE_TAG="$TAG"
node - <<'NODE' > create-release.json
const fs=require("fs");
const body=fs.readFileSync("release-notes.md","utf8").trim();
process.stdout.write(JSON.stringify({
  tag_name:process.env.RELEASE_TAG,
  target_commitish:"94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495",
  name:"Continue Watching Maintenance "+process.env.RELEASE_TAG,
  body,
  draft:false,
  prerelease:false,
  generate_release_notes:false
}));
NODE
create_release_http="$(curl -sS -o create-release-response.json -w '%{http_code}' -X POST "${auth[@]}" --data @create-release.json "$api/releases")"
export CREATE_RELEASE_HTTP="$create_release_http"
node - <<'NODE'
const fs=require("fs");
const x=JSON.parse(fs.readFileSync("create-release-response.json","utf8"));
const http=String(process.env.CREATE_RELEASE_HTTP||"unknown");
if(http!=="201"){
  const raw=String(x.message||x.errors?.[0]?.message||"");
  const safe=raw
    .replace(/https?:\/\/\S+/gi,"URL")
    .replace(/[A-Fa-f0-9]{24,}/g,"HEX")
    .replace(/[^A-Za-z0-9 ]/g," ")
    .replace(/\s+/g," ")
    .trim()
    .split(" ")
    .slice(0,12)
    .join("")
    .slice(0,72)||"nomessage";
  fs.writeFileSync("release-stage.txt","release_create_http"+http+"_"+safe+"\n");
  process.exit(2);
}
NODE
created_tag="$(node -e 'const x=require("./create-release-response.json");process.stdout.write(String(x.tag_name||""))')"
test "$created_tag" = "$TAG"
printf 'passed\n' > release-stage.txt
echo "release_published"
