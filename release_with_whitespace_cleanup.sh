#!/bin/zsh

set -euo pipefail

cd "${0:A:h}"

print -n "Version (for example 2.5.0): "
read -r version

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Error: enter a version in the form 2.5.0."
    exit 1
fi

tag="v${version}"

if [[ "$(git branch --show-current)" != "main" ]]; then
    print -u2 "Error: switch to the main branch before releasing."
    exit 1
fi

print "Checking GitHub..."
git fetch origin --tags

if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    print -u2 "Error: local main and origin/main differ. Sync them before releasing."
    exit 1
fi

if git show-ref --verify --quiet "refs/tags/${tag}"; then
    print -u2 "Error: ${tag} already exists locally."
    exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
    print -u2 "Error: ${tag} already exists on GitHub."
    exit 1
fi

print "Updating the app version to ${version}..."
NEW_VERSION="$version" perl -pi -e 's/(MARKETING_VERSION = )[0-9]+\.[0-9]+\.[0-9]+(;)/$1$ENV{NEW_VERSION}$2/g' \
    Vela.xcodeproj/project.pbxproj
NEW_VERSION="$version" perl -pi -e 's/(MARKETING_VERSION: )[0-9]+\.[0-9]+\.[0-9]+/$1$ENV{NEW_VERSION}/g' \
    project.yml

pbx_version_count="$(grep -c "MARKETING_VERSION = ${version};" Vela.xcodeproj/project.pbxproj)"
yaml_version_count="$(grep -c "MARKETING_VERSION: ${version}" project.yml)"
if [[ "$pbx_version_count" -lt 1 || "$yaml_version_count" -ne 1 ]]; then
    print -u2 "Error: could not verify the version in both project files."
    exit 1
fi

print "Cleaning trailing whitespace..."
sed -i '' -E 's/[[:space:]]+$//' \
    Vela/Features/NativePlayer.swift \
    Vela/Features/Views.swift

git diff --check

if git diff --quiet && git diff --cached --quiet; then
    print -u2 "Error: there are no changes to release."
    exit 1
fi

print "Creating the ${version} release commit and tag..."
git add -A
git commit -m "Release Vela ${version}"
git tag "$tag"

print "Pushing main and ${tag} to GitHub..."
git push --atomic origin main "refs/tags/${tag}"

print
print "Release ${version} is committed, tagged, and pushed."
print "Commit: $(git rev-parse --short HEAD)"
print "Next: build the IPA and create the GitHub release using tag ${tag}."
