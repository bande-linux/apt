#!/bin/bash
# Usage: fetch-run.sh REPO RUN_ID OUT_DIR [CONF_DIR]
# Verifies a CI run of bande-linux/REPO (desktop, dict, l10n, kernel, web, apps or
# apps-l10n): the repository's release workflow, finished green, its commit on main.
# Every package built for a suite carries the suite's ~debNN (suites.sh) right
# after its release version, written ~debNN below:
# - desktop: the push of a vX.Y.Z tag that points at the run's commit; its
#   packages carry X.Y.Z~debNN.
# - dict: the desktop's dict.yml push of a dict-YYYYMMDD tag that points at
#   the run's commit; it carries bande-dict-* packages alone, at YYYYMMDD~debNN.
# - l10n: the desktop's l10n.yml push of an l10n-YYYYMMDD[.N] tag that points at
#   the run's commit; it carries bande-desktop-l10n-* packs alone, each at
#   RELEASE~debNN+l10nYYYYMMDD[.N], where vRELEASE is a desktop tag on the run's
#   commit's history.
# - kernel and web: a schedule or dispatch on main, naming its base version
#   with one bande-version-VERSION artifact; its packages carry VERSION~debNN.
# - apps: the push of an <app>-vX.Y.Z tag that points at the run's commit, for
#   an apps/<app> at that commit; it carries bande-<app> alone, at X.Y.Z~debNN,
#   never a name of the desktop's, and its packs bande-<app>-l10n-*,
#   architecture all, in each architecture's artifact. Dispatch runs are test
#   builds and never published.
# - apps-l10n: the apps' l10n.yml push of an l10n-YYYYMMDD[.N] tag that points at
#   the run's commit; it carries bande-<app>-l10n-* packs alone, for apps/<app>
#   at that commit, each at RELEASE~debNN+l10nYYYYMMDD[.N], where <app>-vRELEASE
#   is a tag on the run's commit's history.
# Then, for each suite in CONF_DIR/suites (default conf/), downloads its
# bande-debs-SUITE-ARCH artifacts into OUT_DIR/SUITE and checks that they carry
# only the repository's own package names, every architecture it builds and
# the same packages for each. A run without any artifact of a suite (built
# before the suite was listed) leaves that suite alone; it must carry at least
# one. A package OUT_DIR already holds at a newer version is left, so several
# apps runs merge. Prints component= and appends it to $GITHUB_OUTPUT when set.
# Needs GH_TOKEN; the repositories are public.
#
# A run given by hand may still be going; this waits up to $FETCH_RUN_WAIT
# seconds (default 900) for it to end.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source_repo=$1 run=$2 out=$3 conf=${4:-$here/../conf} stamp=""
api=${GITHUB_API_URL:-https://api.github.com}
wait_limit=${FETCH_RUN_WAIT:-900}
poll=${FETCH_RUN_POLL:-15}
# Built by apt itself; no source repository may publish them.
repository_packages=" bande-archive-keyring bande-apt-source "
# Names the desktop, the kernel and the web repository publish, which an app may never take; the
# desktop's packaging/ directories are added from its main branch.
reserved=" xdg-desktop-portal-bande libpam-bande-secrets bande-desktop bande-os-apple bande-browser "
fail() { echo "fetch-run: $*" >&2; exit 1; }
# shellcheck source=scripts/suites.sh
. "$here/suites.sh"
suites=$(suite_list "$conf") || fail "conf/suites is not usable"
# Temporary, until the kernel repository builds per suite: its runs upload the
# unsuffixed bande-debs-ARCH artifacts, whose packages carry the base version
# (or base~deb14), and feed forky alone.
kernel_suite=forky

# Per repository: its workflow, the events it publishes from, the package names
# it may publish, the component they go to, the architectures it must build
# (all: architecture-independent packages).
case $source_repo in
    desktop)
        workflow=.github/workflows/release.yml
        events=(push)
        names=('bande-*' xdg-desktop-portal-bande libpam-bande-secrets)
        component=main
        architectures=(amd64 arm64 all)
        ;;
    dict)
        workflow=.github/workflows/dict.yml
        events=(push)
        names=('bande-dict-*')
        component=main
        architectures=(all)
        ;;
    l10n)
        workflow=.github/workflows/l10n.yml
        events=(push)
        names=('bande-desktop-l10n-*')
        component=main
        architectures=(all)
        ;;
    apps-l10n)
        workflow=.github/workflows/l10n.yml
        events=(push)
        names=('bande-*-l10n-*')
        component=main
        architectures=(all)
        ;;
    kernel)
        workflow=.github/workflows/follow-debian.yml
        events=(schedule workflow_dispatch)
        names=('linux-*-apple-*' bande-os-apple)
        component=apple
        architectures=(arm64)
        ;;
    web)
        workflow=.github/workflows/follow-debian.yml
        events=(schedule workflow_dispatch)
        names=(bande-browser 'bande-browser-l10n-*')
        component=main
        architectures=(amd64 arm64 all)
        ;;
    apps)
        workflow=.github/workflows/build.yml
        events=(push)
        component=main
        architectures=(amd64 arm64)
        ;;
    *) fail "unknown repository $source_repo; the archive takes desktop, dict, l10n, kernel, web, apps and apps-l10n" ;;
esac
case $source_repo in
    dict | l10n) repo=bande-linux/desktop ;;
    apps-l10n) repo=bande-linux/apps ;;
    *) repo=bande-linux/$source_repo ;;
esac

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
if [ "$source_repo" != kernel ] && [ "$source_repo" != web ]; then
    tag=${ref#refs/tags/}
    if [ "$source_repo" = l10n ] || [ "$source_repo" = apps-l10n ]; then
        [[ $tag =~ ^l10n-([0-9]{8}(\.[0-9]+)?)$ ]] || fail "run $run built $ref; the language packs publish l10n-YYYYMMDD tags"
        stamp=${BASH_REMATCH[1]}
    elif [ "$source_repo" = desktop ]; then
        [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || fail "run $run built $ref; the desktop publishes vX.Y.Z tags"
        want_version=${BASH_REMATCH[1]}
    elif [ "$source_repo" = dict ]; then
        [[ $tag =~ ^dict-([0-9]{8})$ ]] || fail "run $run built $ref; the dictionary packs publish dict-YYYYMMDD tags"
        want_version=${BASH_REMATCH[1]}
    else
        [[ $tag =~ ^([a-z0-9][a-z0-9-]*)-v([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
            fail "run $run built $ref; the apps publish <app>-vX.Y.Z tags"
        app=${BASH_REMATCH[1]} want_version=${BASH_REMATCH[2]}
        names=("bande-$app" "bande-$app-l10n-*")
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
if [ "$source_repo" = kernel ] || [ "$source_repo" = web ]; then
    mapfile -t named < <(jq -r '.artifacts[].name | select(startswith("bande-version-")) | ltrimstr("bande-version-")' \
        "$work/artifacts.json")
    [ ${#named[@]} -eq 1 ] || fail "run $run names ${#named[@]} versions; it must upload one bande-version-VERSION artifact"
    [[ ${named[0]} =~ ^[0-9][A-Za-z0-9.~-]*\+bande[0-9]+$ ]] || fail "run $run names version ${named[0]}, not <debian-version>+bandeN"
    want_version=${named[0]}
fi
if [ "$source_repo" = apps ] || [ "$source_repo" = apps-l10n ]; then
    call "$api/repos/$repo/contents/apps?ref=$sha" > "$work/apps.json" || fail "cannot list apps/ at $sha"
    if [ "$source_repo" = apps ]; then
        jq -e --arg a "$app" 'any(.[]; .type == "dir" and .name == $a)' "$work/apps.json" > /dev/null ||
            fail "tag $tag names $app, but the run's commit has no apps/$app"
    fi
    call "$api/repos/bande-linux/desktop/contents/packaging?ref=main" > "$work/packaging.json" ||
        fail "cannot list the desktop's packaging/"
    reserved+="$(jq -r '.[] | select(.type == "dir") | .name' "$work/packaging.json" | tr '\n' ' ')"
fi
# l10n_version PACKAGE VERSION NUMBER: a pack of an l10n tag carries
# RELEASE~debNUMBER+l10n$stamp, where the release tag of the program it
# translates is on the run's history.
l10n_version() {
    local package=$1 version=$2 number=$3 app release tag_name status
    [[ $version =~ ^([0-9]+\.[0-9]+\.[0-9]+)~deb$number\+l10n([0-9.]+)$ ]] && [ "${BASH_REMATCH[2]}" = "$stamp" ] ||
        fail "$package carries version $version, not RELEASE~deb$number+l10n$stamp"
    release=${BASH_REMATCH[1]}
    if [ "$source_repo" = l10n ]; then
        tag_name=v$release
    else
        app=${package#bande-} app=${app%%-l10n-*}
        jq -e --arg a "$app" 'any(.[]; .type == "dir" and .name == $a)' "$work/apps.json" > /dev/null ||
            fail "$package is for $app, but the run's commit has no apps/$app"
        [[ $reserved != *" bande-$app "* ]] || fail "$package translates the desktop's bande-$app; an app may not take it"
        tag_name=$app-v$release
    fi
    if ! grep -qxF "$tag_name" "$work/released" 2> /dev/null; then
        status=$(call "$api/repos/$repo/compare/$tag_name...$sha" | jq -r .status) ||
            fail "$package is built on $tag_name, which $repo does not have"
        case $status in
            identical | ahead) echo "$tag_name" >> "$work/released" ;;
            *) fail "$package is built on $tag_name, which is not on the history of $sha ($status)" ;;
        esac
    fi
}

# fetch_suite SUITE: SUITE's artifacts of the run, checked, into $work/stage/SUITE.
fetch_suite() {
    local suite=$1 number arch name id deb package version deb_arch allowed pattern expected first got split
    number=$(suite_number "$suite")
    mkdir -p "$work/stage/$suite"
    : > "$work/names"
    for arch in "${architectures[@]}"; do
        name=$prefix$arch
        id=$(jq -r --arg n "$name" '[.artifacts[] | select(.name == $n)] | if length == 1 then .[0].id else "" end' \
            "$work/artifacts.json")
        [ -n "$id" ] || fail "run $run has no single $name artifact"
        call "$api/repos/$repo/actions/artifacts/$id/zip" > "$work/$name.zip" || fail "cannot download $name"
        mkdir "$work/$name"
        unzip -q -j "$work/$name.zip" '*.deb' -d "$work/$name" 2> /dev/null || fail "$name holds no packages"
        for deb in "$work/$name"/*.deb; do
            read -r package version deb_arch < <(dpkg-deb --show --showformat="\${Package} \${Version} \${Architecture}\n" "$deb")
            [ "$deb_arch" = "$arch" ] || { [ "$source_repo" = apps ] && [ "$deb_arch" = all ] && [[ $package == *-l10n-* ]]; } ||
                fail "$name holds $package for $deb_arch"
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
            if [ -n "${stamp:-}" ]; then
                l10n_version "$package" "$version" "$number"
            elif [ "$source_repo" = kernel ] && [ "$version" = "$want_version" ]; then
                : # Temporary: the kernel builds without the suffix yet.
            elif [ "$version" != "$want_version~deb$number" ]; then
                fail "$package carries version $version, the run publishes $want_version~deb$number for $suite"
            fi
            echo "$arch $package $version" >> "$work/names"
            mv "$deb" "$work/stage/$suite/"
        done
    done

    # Every architecture-specific package must be built for every architecture, or
    # machines of the one that lacks it would be left with a mismatched set.
    expected='' first=''
    for arch in "${architectures[@]}"; do
        [ "$arch" != all ] || continue
        got=$(awk -v a="$arch" '$1 == a { print $2 }' "$work/names" | sort -u | tr '\n' ' ')
        if [ -n "$first" ] && [ "$got" != "$expected" ]; then
            fail "incomplete architecture in $suite: $first carries [${expected% }], $arch carries [${got% }]"
        fi
        first=${first:-$arch} expected=$got
    done
    split=$(awk '$1 != "all" { print $2, $3 }' "$work/names" | sort -u | awk '{ print $1 }' | uniq -d)
    [ -z "$split" ] || fail "packages built at different versions per architecture in $suite: $(tr '\n' ' ' <<< "$split")"
}

mkdir -p "$out" "$work/stage"
shopt -s nullglob
fetched=''
for suite in $suites; do
    if [ "$source_repo" = kernel ]; then
        [ "$suite" = "$kernel_suite" ] || continue
        prefix=bande-debs-
    else
        prefix=bande-debs-$suite-
        # A run built before the suite was listed leaves it as it is.
        if ! jq -e --arg p "$prefix" 'any(.artifacts[]; .name | startswith($p))' "$work/artifacts.json" > /dev/null; then
            echo "fetch-run: run $run built nothing for $suite; it stays as it is" >&2
            continue
        fi
    fi
    fetch_suite "$suite"
    fetched+=" $suite"
done
[ -n "$fetched" ] || fail "run $run has no bande-debs-SUITE-ARCH artifacts for any suite of conf/suites: ${suites//$'\n'/ }"

describe() { dpkg-deb --show --showformat="\${Package} \${Architecture} \${Version}\n" "$1"; }
for suite in $fetched; do
    mkdir -p "$out/$suite"
    for deb in "$work/stage/$suite"/*.deb; do
        read -r package arch version < <(describe "$deb")
        keep=1
        for held in "$out/$suite"/*.deb; do
            read -r held_package held_arch held_version < <(describe "$held")
            [ "$held_package $held_arch" = "$package $arch" ] || continue
            if dpkg --compare-versions "$version" gt "$held_version"; then
                rm "$held"
            else
                keep=0
            fi
        done
        if [ "$keep" = 1 ]; then mv "$deb" "$out/$suite/"; fi
    done
done

echo "component=$component"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "component=$component" >> "$GITHUB_OUTPUT"
fi
