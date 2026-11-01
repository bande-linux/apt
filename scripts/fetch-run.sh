#!/bin/bash
# Usage: fetch-run.sh REPO RUN_ID OUT_DIR
# Verifies a CI run of bande-linux/REPO (desktop, kernel or apps): the
# repository's release workflow, finished green, its commit on main.
# - desktop: the push of a vX.Y.Z tag that points at the run's commit; its
#   packages carry X.Y.Z.
# - kernel: a schedule or dispatch on main, naming its version with one
#   bande-version-VERSION artifact, which its packages carry.
# - apps: the push of an <app>-vX.Y.Z tag that points at the run's commit, for
#   an apps/<app> at that commit; it carries bande-<app> alone, at X.Y.Z, never
#   a name of the desktop's. Dispatch runs are test builds and never published.
# Then downloads its bande-debs-ARCH artifacts into OUT_DIR and checks that they
# carry only the repository's own package names, every architecture it builds
# and the same packages for each. A package OUT_DIR already holds at a newer
# version is left, so several apps runs merge. Prints component= and appends it
# to $GITHUB_OUTPUT when set. Needs GH_TOKEN; the repositories are public.
#
# A run given by hand may still be going; this waits up to $FETCH_RUN_WAIT
# seconds (default 900) for it to end.
set -euo pipefail

source_repo=$1 run=$2 out=$3
api=${GITHUB_API_URL:-https://api.github.com}
wait_limit=${FETCH_RUN_WAIT:-900}
poll=${FETCH_RUN_POLL:-15}
# Built by apt itself; no source repository may publish them.
repository_packages=" bande-archive-keyring bande-apt-source "
# Names the desktop and the kernel publish, which an app may never take; the
# desktop's packaging/ directories are added from its main branch.
reserved=" xdg-desktop-portal-bande bande-desktop bande-os-apple "
fail() { echo "fetch-run: $*" >&2; exit 1; }

# Per repository: its workflow, the events it publishes from, the package names
# it may publish, the component they go to, the architectures it must build
# (all: architecture-independent packages).
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
        ;;
    apps)
        workflow=.github/workflows/build.yml
        events=(push)
        component=main
        architectures=(amd64 arm64)
        ;;
    *) fail "unknown repository $source_repo; the archive takes desktop, kernel and apps" ;;
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
if [ "$source_repo" = desktop ] || [ "$source_repo" = apps ]; then
    tag=${ref#refs/tags/}
    if [ "$source_repo" = desktop ]; then
        [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || fail "run $run built $ref; the desktop publishes vX.Y.Z tags"
        want_version=${BASH_REMATCH[1]}
    else
        [[ $tag =~ ^([a-z0-9][a-z0-9-]*)-v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
            fail "run $run built $ref; the apps publish <app>-vX.Y.Z tags"
        app=${BASH_REMATCH[1]} want_version=${BASH_REMATCH[2]}
        names=("bande-$app")
    fi
    call "$api/repos/$repo/git/ref/tags/$tag" > "$work/tag.json" || fail "tag $tag does not exist"
    read -r type object < <(jq -r '[.object.type, .object.sha] | @tsv' "$work/tag.json")
    if [ "$type" = tag ]; then
        object=$(call "$api/repos/$repo/git/tags/$object" | jq -r .object.sha)
    fi
    [ "$object" = "$sha" ] || fail "tag $tag points at $object, the run built $sha"
else
    [ "$ref" = main ] || fail "run $run built $ref; the $source_repo publishes main"
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
if [ "$source_repo" = kernel ]; then
    mapfile -t named < <(jq -r '.artifacts[].name | select(startswith("bande-version-")) | ltrimstr("bande-version-")' \
        "$work/artifacts.json")
    [ ${#named[@]} -eq 1 ] || fail "run $run names ${#named[@]} versions; it must upload one bande-version-VERSION artifact"
    [[ ${named[0]} =~ ^[0-9][A-Za-z0-9.~-]*\+bande[0-9]+$ ]] || fail "run $run names version ${named[0]}, not <debian-version>+bandeN"
    want_version=${named[0]}
fi
if [ "$source_repo" = apps ]; then
    call "$api/repos/$repo/contents/apps?ref=$sha" > "$work/apps.json" || fail "cannot list apps/ at $sha"
    jq -e --arg a "$app" 'any(.[]; .type == "dir" and .name == $a)' "$work/apps.json" > /dev/null ||
        fail "tag $tag names $app, but the run's commit has no apps/$app"
    call "$api/repos/bande-linux/desktop/contents/packaging?ref=main" > "$work/packaging.json" ||
        fail "cannot list the desktop's packaging/"
    reserved+="$(jq -r '.[] | select(.type == "dir") | .name' "$work/packaging.json" | tr '\n' ' ')"
fi
mkdir -p "$out" "$work/stage"
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
        [[ $repository_packages != *" $package "* ]] || fail "$package is built by apt itself; $source_repo may not publish it"
        if [ "$source_repo" = apps ]; then
            [[ $reserved != *" $package "* ]] || fail "$package is the desktop's; an app may not take it"
        fi
        if [ "$version" != "$want_version" ]; then
            fail "$package carries version $version, the run publishes $want_version"
        fi
        echo "$arch $package $version" >> "$work/names"
        mv "$deb" "$work/stage/"
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
split=$(awk '$1 != "all" { print $2, $3 }' "$work/names" | sort -u | awk '{ print $1 }' | uniq -d)
[ -z "$split" ] || fail "packages built at different versions per architecture: $(tr '\n' ' ' <<< "$split")"

describe() { dpkg-deb --show --showformat="\${Package} \${Architecture} \${Version}\n" "$1"; }
for deb in "$work/stage"/*.deb; do
    read -r package arch version < <(describe "$deb")
    keep=1
    for held in "$out"/*.deb; do
        read -r held_package held_arch held_version < <(describe "$held")
        [ "$held_package $held_arch" = "$package $arch" ] || continue
        if dpkg --compare-versions "$version" gt "$held_version"; then
            rm "$held"
        else
            keep=0
        fi
    done
    if [ "$keep" = 1 ]; then mv "$deb" "$out/"; fi
done

echo "component=$component"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "component=$component" >> "$GITHUB_OUTPUT"
fi
