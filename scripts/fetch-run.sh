#!/bin/bash
# Usage: fetch-run.sh RUN_ID OUT_DIR [TAG]
# Verifies a desktop CI run (every other job green, the commit on main) and
# downloads its packages into OUT_DIR. Without TAG the run must be a push to
# main and feeds testing. With TAG vX.Y.Z the tag must point at the run's
# commit, whose Cargo.toml says X.Y.Z, and the packages feed stable: those of
# a main run are promoted to X.Y.Z unchanged but for their version, those of a
# run on the tag itself must already carry it. Prints channel= and version=
# and appends them to $GITHUB_OUTPUT when set. Needs GH_TOKEN with Actions and
# Contents read access to $DESKTOP_REPO.
set -euo pipefail

run=$1 out=$2 tag=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
api=${GITHUB_API_URL:-https://api.github.com}
repo=${DESKTOP_REPO:-unbound-linux/desktop}
publisher_job=ci/publish
everywhere=" unbound-archive-keyring unbound-apt-source unbound-apt-source-testing "
fail() { echo "fetch-run: $*" >&2; exit 1; }

call() {
    curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

call "$api/repos/$repo/actions/runs/$run" > "$work/run.json" || fail "cannot read run $run"
read -r event path ref sha owner < <(jq -r '[.event, .path, .head_branch, .head_sha, .head_repository.full_name] | @tsv' "$work/run.json")
[ "$path" = .github/workflows/ci.yml ] || fail "run $run is from $path, not .github/workflows/ci.yml"
[ "$owner" = "$repo" ] || fail "run $run built $owner, not $repo"

if [ -z "$tag" ]; then
    if [ "$event" != push ] || [ "$ref" != main ]; then
        fail "run $run built $ref ($event); testing takes pushes to main"
    fi
    channel=testing
else
    [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || fail "$tag is not a vX.Y.Z tag"
    release=${BASH_REMATCH[1]}
    if ! { [ "$ref" = main ] && [ "$event" = push ]; } && [ "$ref" != "$tag" ]; then
        fail "run $run built $ref ($event), neither main nor $tag"
    fi
    channel=stable
    call "$api/repos/$repo/git/ref/tags/$tag" > "$work/tag.json" || fail "tag $tag does not exist"
    read -r type object < <(jq -r '[.object.type, .object.sha] | @tsv' "$work/tag.json")
    if [ "$type" = tag ]; then
        object=$(call "$api/repos/$repo/git/tags/$object" | jq -r .object.sha)
    fi
    [ "$object" = "$sha" ] || fail "tag $tag points at $object, the run built $sha"
    declared=$(call "$api/repos/$repo/contents/Cargo.toml?ref=$sha" | jq -r .content | base64 -d |
        awk '/^\[/ { s = $0 } s == "[workspace.package]" && $1 == "version" { gsub(/"/, "", $3); print $3; exit }')
    [ "$declared" = "$release" ] || fail "Cargo.toml at $sha says ${declared:-no version}, the tag says $release"
fi

status=$(call "$api/repos/$repo/compare/$sha...main" | jq -r .status)
case $status in
    identical | ahead) ;;
    *) fail "$sha is not on main ($status)" ;;
esac

call "$api/repos/$repo/actions/runs/$run/jobs?per_page=100" > "$work/jobs.json"
jq -e '.jobs | length > 0' "$work/jobs.json" > /dev/null || fail "run $run has no jobs"
bad=$(jq -r --arg self "$publisher_job" \
    '.jobs[] | select(.name != $self and .conclusion != "success") | "\(.name)=\(.conclusion // .status)"' \
    "$work/jobs.json")
[ -z "$bad" ] || fail "run $run has jobs that did not succeed: $(tr '\n' ' ' <<< "$bad")"

call "$api/repos/$repo/actions/runs/$run/artifacts?per_page=100" > "$work/artifacts.json"
mapfile -t artifacts < <(jq -r '.artifacts[] | select(.name | startswith("unbound-debs-")) | "\(.id) \(.name)"' \
    "$work/artifacts.json")
[ ${#artifacts[@]} -gt 0 ] || fail "run $run has no unbound-debs-* artifacts"
mkdir -p "$out"
for artifact in "${artifacts[@]}"; do
    read -r id name <<< "$artifact"
    call "$api/repos/$repo/actions/artifacts/$id/zip" > "$work/$name.zip" || fail "cannot download $name"
    unzip -q -o -j "$work/$name.zip" '*.deb' -d "$out"
done

shopt -s nullglob
debs=("$out"/*.deb)
[ ${#debs[@]} -gt 0 ] || fail "the artifacts hold no packages"
versions=()
for deb in "${debs[@]}"; do
    read -r package version < <(dpkg-deb --show --showformat="\${Package} \${Version}\n" "$deb")
    [[ $package == unbound-* || $package == xdg-desktop-portal-unbound ]] ||
        fail "$(basename "$deb") is $package, which the archive does not carry"
    [[ $everywhere == *" $package "* ]] || versions+=("$version")
done
[ ${#versions[@]} -gt 0 ] || fail "the artifacts hold only repository packages"
version=${versions[0]}
for v in "${versions[@]}"; do
    [ "$v" = "$version" ] || fail "packages carry different versions: $version and $v"
done
if [ "$ref" = main ]; then
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+\+git[0-9]{8}\.[0-9]+\.${sha:0:7}$ ]] ||
        fail "main build $sha carries version $version"
    if [ "$channel" = stable ]; then
        "$here/promote.sh" "$version" "$release" "$out"
        version=$release
    fi
else
    [ "$version" = "$release" ] || fail "tag $tag built version $version"
fi

echo "channel=$channel"
echo "version=$version"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'channel=%s\nversion=%s\n' "$channel" "$version" >> "$GITHUB_OUTPUT"
fi
