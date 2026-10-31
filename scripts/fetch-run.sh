#!/bin/bash
# Usage: fetch-run.sh REPO RUN_ID OUT_DIR
# Verifies a CI run of bande-linux/REPO (desktop or kernel): the repository's
# release workflow, finished green, its commit on main. A desktop run must be
# the push of a vX.Y.Z tag that points at the run's commit, and its packages
# carry X.Y.Z. A kernel run must be a schedule or dispatch on main. Then downloads its bande-debs-ARCH artifacts into
# OUT_DIR and checks that they carry only the repository's own package names,
# every architecture it builds and the same packages for each. Prints
# component= and appends it to $GITHUB_OUTPUT when set. Needs GH_TOKEN with
# Actions and Contents read access to the repository.
#
# The run's last job starts the publish, so the run is usually still going; this
# waits up to $FETCH_RUN_WAIT seconds (default 900) for it to end.
set -euo pipefail

source_repo=$1 run=$2 out=$3
api=${GITHUB_API_URL:-https://api.github.com}
wait_limit=${FETCH_RUN_WAIT:-900}
poll=${FETCH_RUN_POLL:-15}
repository_packages=" bande-archive-keyring bande-apt-source "
fail() { echo "fetch-run: $*" >&2; exit 1; }

# Per repository: its workflow, the events it publishes from, the package names
# it may publish, the component they go to, the architectures it must build
# (all: architecture-independent packages) and the form of its versions.
case $source_repo in
    desktop)
        workflow=.github/workflows/release.yml
        events=(push)
        names=('bande-*' xdg-desktop-portal-bande)
        component=main
        architectures=(amd64 arm64 all)
        ;;
    kernel)
        workflow=.github/workflows/follow-debian.yml
        events=(schedule workflow_dispatch)
        names=('linux-*-apple-*' bande-os-apple)
        component=apple
        architectures=(arm64)
        version_form='^[0-9][^ ]*\+bande[0-9]+$'
        ;;
    *) fail "unknown repository $source_repo; the archive takes desktop and kernel" ;;
esac
repo=bande-linux/$source_repo

call() {
    curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

call "$api/repos/$repo/actions/runs/$run" > "$work/run.json" || fail "cannot read run $run of $repo"
read -r event path ref sha owner < <(jq -r '[.event, .path, .head_branch, .head_sha, .head_repository.full_name] | @tsv' "$work/run.json")
[ "$path" = "$workflow" ] || fail "run $run is from $path, not $workflow"
[ "$owner" = "$repo" ] || fail "run $run built $owner, not $repo"
[[ " ${events[*]} " == *" $event "* ]] || fail "run $run was started by $event; $source_repo publishes from ${events[*]}"
if [ "$source_repo" = desktop ]; then
    tag=${ref#refs/tags/}
    [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || fail "run $run built $ref; the desktop publishes vX.Y.Z tags"
    version_form="^${BASH_REMATCH[1]//./\\.}\$"
    call "$api/repos/$repo/git/ref/tags/$tag" > "$work/tag.json" || fail "tag $tag does not exist"
    read -r type object < <(jq -r '[.object.type, .object.sha] | @tsv' "$work/tag.json")
    if [ "$type" = tag ]; then
        object=$(call "$api/repos/$repo/git/tags/$object" | jq -r .object.sha)
    fi
    [ "$object" = "$sha" ] || fail "tag $tag points at $object, the run built $sha"
else
    [ "$ref" = main ] || fail "run $run built $ref; the kernel publishes main"
fi

waited=0
while :; do
    read -r status conclusion < <(jq -r '[.status, .conclusion // "none"] | @tsv' "$work/run.json")
    [ "$status" != completed ] || break
    [ "$waited" -lt "$wait_limit" ] || fail "run $run is still $status after ${wait_limit}s"
    sleep "$poll"
    waited=$((waited + poll))
    call "$api/repos/$repo/actions/runs/$run" > "$work/run.json" || fail "cannot read run $run of $repo"
done
[ "$conclusion" = success ] || fail "run $run ended in $conclusion, not success"

status=$(call "$api/repos/$repo/compare/$sha...main" | jq -r .status)
case $status in
    identical | ahead) ;;
    *) fail "$sha is not on main ($status)" ;;
esac

call "$api/repos/$repo/actions/runs/$run/artifacts?per_page=100" > "$work/artifacts.json"
mkdir -p "$out"
: > "$work/names"
shopt -s nullglob
for arch in "${architectures[@]}"; do
    name=bande-debs-$arch
    id=$(jq -r --arg n "$name" '[.artifacts[] | select(.name == $n)] | if length == 1 then .[0].id else "" end' \
        "$work/artifacts.json")
    [ -n "$id" ] || fail "run $run has no single $name artifact"
    call "$api/repos/$repo/actions/artifacts/$id/zip" > "$work/$name.zip" || fail "cannot download $name"
    mkdir "$work/$name"
    unzip -q -j "$work/$name.zip" '*.deb' -d "$work/$name" 2> /dev/null || fail "$name holds no packages"
    for deb in "$work/$name"/*.deb; do
        read -r package version deb_arch < <(dpkg-deb --show --showformat="\${Package} \${Version} \${Architecture}\n" "$deb")
        [ "$deb_arch" = "$arch" ] || fail "$name holds $package for $deb_arch"
        allowed=0
        for pattern in "${names[@]}"; do
            # shellcheck disable=SC2053 # the names are glob patterns
            [[ $package != $pattern ]] || allowed=1
        done
        [ "$allowed" = 1 ] || fail "$(basename "$deb") is $package, which $source_repo does not publish"
        if [[ $repository_packages != *" $package "* ]] && [[ ! $version =~ $version_form ]]; then
            fail "$package from $sha carries version $version"
        fi
        echo "$arch $package" >> "$work/names"
        mv "$deb" "$out/"
    done
done

# Every architecture-specific package must be built for every architecture, or
# machines of the one that lacks it would be left with a mismatched set.
expected='' first=''
for arch in "${architectures[@]}"; do
    [ "$arch" != all ] || continue
    got=$(awk -v a="$arch" '$1 == a { print $2 }' "$work/names" | sort -u | tr '\n' ' ')
    if [ -n "$first" ] && [ "$got" != "$expected" ]; then
        fail "incomplete architecture: $first carries [${expected% }], $arch carries [${got% }]"
    fi
    first=${first:-$arch} expected=$got
done

echo "component=$component"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "component=$component" >> "$GITHUB_OUTPUT"
fi
