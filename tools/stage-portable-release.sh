#!/usr/bin/env bash
# Stage a package from the green Windows job in this workflow, without publishing.
set -euo pipefail

fail() { printf '::error title=Draft staging failed::%s\n' "$*" >&2; exit 1; }

tag=${1-}
dir=${2-}
repo=${GITHUB_REPOSITORY-}
commit=${GITHUB_SHA-}
[[ $# == 2 && $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && -d $dir ]] ||
    fail 'Expected a vX.Y.Z tag and the verified artifact directory.'
[[ ${GITHUB_EVENT_NAME-} == workflow_dispatch && ${GITHUB_REF-} == refs/heads/main &&
    $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $commit =~ ^[0-9a-f]{40}$ ]] ||
    fail 'Draft staging must be manually requested on main.'
[[ $(git rev-parse HEAD) == "$commit" ]] || fail 'The checked-out commit differs from the workflow commit.'

app="FORMA-$tag-windows-x64.zip"
shopt -s nullglob
sources=("$dir"/AutoHotkey-v*-source.zip)
[[ ${#sources[@]} == 1 ]] || fail 'Expected one embedded AutoHotkey source ZIP.'
runtime=${sources[0]##*/}
[[ $runtime =~ ^AutoHotkey-v[0-9]+\.[0-9]+\.[0-9]+-source\.zip$ ]] || fail 'Invalid AutoHotkey archive name.'
files=("$app" "$runtime" SHA256SUMS.txt)
[[ -s $dir/SHA256SUMS.txt ]] || fail 'Missing SHA256SUMS.txt.'
manifest=$(tr -d '\r' < "$dir/SHA256SUMS.txt")
[[ $(awk 'END {print NR}' <<< "$manifest") == 2 ]] || fail 'Expected two checksum entries.'
declare -A hashes sizes
for file in "${files[@]}"; do
    [[ -s $dir/$file ]] || fail "Missing $file."
    hash=$(sha256sum < "$dir/$file")
    hashes[$file]=${hash%% *}
    sizes[$file]=$(stat -c %s -- "$dir/$file")
    if [[ $file == *.zip ]]; then
        grep -Fxq -- "${hashes[$file]}  $file" <<< "$manifest" || fail "SHA-256 mismatch for $file."
        unzip -tq "$dir/$file"
    fi
done

read_draft() {
    local data refs checkout ref="refs/tags/$tag"
    data=$(gh api --paginate "repos/$repo/releases?per_page=100" | jq -ces --arg tag "$tag" \
        '[.[][] | select(.tag_name == $tag)] | if length == 1 then .[0] else empty end') ||
        fail "Expected one existing draft for $tag."
    jq -e --arg commit "$commit" '.draft and (.prerelease | not) and .target_commitish == $commit' \
        <<< "$data" >/dev/null || fail 'The release must be an unpublished stable draft at the exact tested commit.'
    # An existing tag overrides target_commitish when published. Do not stage under a different commit.
    refs=$(git ls-remote origin "$ref" "$ref^{}")
    checkout=$(awk -v ref="$ref" '$2 == ref {sha = $1} $2 == ref "^{}" {peeled = $1}
        END {print (peeled ? peeled : sha)}' <<< "$refs")
    [[ -z $checkout || $checkout == "$commit" ]] || fail "$tag points to a different commit."
    printf '%s\n' "$data"
}

plan() {
    local data=$1 file current
    pending=()
    for file in "${files[@]}"; do
        current=$(jq -r --arg name "$file" '[.assets[] | select(.name == $name)] |
            if length == 0 then "missing"
            elif length == 1 and .[0].state == "uploaded" then "\(.[0].digest) \(.[0].size)"
            else "incomplete" end' <<< "$data")
        if [[ $current == missing ]]; then
            pending+=("$dir/$file")
        elif [[ $current != "sha256:${hashes[$file]} ${sizes[$file]}" ]]; then
            fail "$file already exists but does not match this build. Nothing will be overwritten."
        fi
    done
    [[ $(jq -r '.assets | length' <<< "$data") == $((${#files[@]} - ${#pending[@]})) ]] ||
        fail 'Unexpected assets in the draft; review before staging.'
}

draft=$(read_draft)
id=$(jq -r '.id' <<< "$draft")
plan "$draft"
if (( ${#pending[@]} )); then
    gh release upload "$tag" --repo "$repo" "${pending[@]}" || fail 'GitHub did not accept the draft asset upload.'
fi

draft=$(read_draft)
[[ $(jq -r '.id' <<< "$draft") == "$id" ]] || fail 'Draft changed during staging.'
plan "$draft"
(( ${#pending[@]} == 0 )) || fail 'GitHub did not report all assets as uploaded.'

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for file in "${files[@]}"; do
    gh release download "$tag" --repo "$repo" --dir "$work" --pattern "$file" || fail "Could not download $file from the draft."
    cmp -- "$dir/$file" "$work/$file" || fail "Downloaded $file differs from the smoke-tested build."
    printf '::notice title=Verified draft asset::%s sha256:%s %s bytes\n' "$file" "${hashes[$file]}" "${sizes[$file]}"
done
printf 'Draft %s (%s) verified at %s. It has not been published.\n' "$tag" "$id" "$commit"
