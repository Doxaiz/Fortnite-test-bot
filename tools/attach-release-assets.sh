#!/usr/bin/env bash
# Verify (and, only on explicit request, attach) the exact portable files from a release tag.
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

tag=${1-}
mode=${2:---check}
repo=${GITHUB_REPOSITORY:-Doxaiz/Fortnite-test-bot}
[[ $# -le 2 && $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && ( $mode == --check || $mode == --attach ) ]] ||
    fail 'Usage: bash tools/attach-release-assets.sh vX.Y.Z [--check | --attach]'
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid repository name.'

latest_release() {
    local info
    info=$(gh api "repos/$repo/releases/latest") || return
    jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and .prerelease == false' <<< "$info" >/dev/null ||
        fail "$tag is not the latest published stable release."
    printf '%s\n' "$info"
}

tag_commit() {
    local object kind sha
    object=$(gh api "repos/$repo/git/ref/tags/$tag" --jq .object) || return
    kind=$(jq -r '.type' <<< "$object")
    sha=$(jq -r '.sha' <<< "$object")
    if [[ $kind == tag && $sha =~ ^[0-9a-f]{40}$ ]]; then
        object=$(gh api "repos/$repo/git/tags/$sha" --jq .object) || return
        kind=$(jq -r '.type' <<< "$object")
        sha=$(jq -r '.sha' <<< "$object")
    fi
    [[ $kind == commit && $sha =~ ^[0-9a-f]{40}$ ]] || fail "Cannot resolve $tag to a commit."
    printf '%s\n' "$sha"
}

file_hash() {
    local line
    line=$(sha256sum < "$1") || return
    printf '%s\n' "${line%% *}"
}

release=$(latest_release)
release_id=$(jq -r '.id' <<< "$release")
commit=$(tag_commit)
archive="FORMA-$tag-windows-x64.zip"
files=("$archive" SHA256SUMS.txt)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

for file in "${files[@]}"; do
    # Use the blob's base64 JSON rather than piping binary bytes through gh's
    # text output. The blob endpoint also works beyond the Contents JSON limit.
    blob=$(gh api -H 'Accept: application/vnd.github.object+json' \
        "repos/$repo/contents/portable/$file?ref=$commit" --jq .sha)
    [[ $blob =~ ^[0-9a-f]{40}$ ]] || fail "Cannot locate $file in $tag."
    gh api "repos/$repo/git/blobs/$blob" --jq 'select(.encoding == "base64") | .content' \
        | base64 --decode > "$work/$file"
    [[ -s $work/$file ]] || fail "Empty file received for $file in $tag."
done
expected=$(awk -v name="$archive" '$2 == name || $2 == "*" name {print $1}' "$work/SHA256SUMS.txt")
[[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || fail "Expected one SHA-256 entry for $archive in $tag."
actual=$(file_hash "$work/$archive")
[[ $actual == "${expected,,}" ]] || fail "SHA-256 mismatch for $archive at $tag."
unzip -tq "$work/$archive"
printf 'Verified %s at %s (SHA-256 %s).\n' "$archive" "$commit" "$actual"

# Check both names before uploading anything. Existing assets must already match
# byte for byte; even partially failed uploads are never overwritten implicitly.
plan_assets() {
    local data=$1 file current digest
    pending=()
    for file in "${files[@]}"; do
        digest="sha256:$(file_hash "$work/$file")"
        current=$(jq -r --arg name "$file" '
            [.assets[] | select(.name == $name)] |
            if length == 0 then "missing"
            elif length == 1 and .[0].state == "uploaded" then (.[0].digest // "unknown")
            else "unavailable" end' <<< "$data")
        if [[ $current == missing ]]; then
            pending+=("$work/$file")
        elif [[ $current != "$digest" ]]; then
            fail "$file is already present but its digest cannot be confirmed. Nothing will be replaced."
        fi
    done
}

plan_assets "$release"
if [[ $mode == --check ]]; then
    if (( ${#pending[@]} )); then
        printf 'Not yet attached: %s\n' "${pending[@]##*/}"
    else
        printf 'Both release assets already match %s.\n' "$tag"
    fi
    exit 0
fi

# Recheck the destination after downloading. gh upload without --clobber also
# refuses an asset name that appears concurrently between this check and upload.
release=$(latest_release)
head=$(tag_commit)
[[ $(jq -r '.id' <<< "$release") == "$release_id" && $head == "$commit" ]] ||
    fail 'The release or tag changed during verification. Run the check again.'
plan_assets "$release"
if (( ${#pending[@]} )); then
    gh release upload "$tag" "${pending[@]}" --repo "$repo"
fi
release=$(latest_release)
plan_assets "$release"
(( ${#pending[@]} == 0 )) || fail 'GitHub did not report both assets as uploaded.'
printf 'Release assets match %s: %s and SHA256SUMS.txt.\n' "$tag" "$archive"
