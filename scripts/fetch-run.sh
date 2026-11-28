#!/bin/bash
# Usage: fetch-run.sh REPO RUN_ID OUT_DIR [CONF_DIR]
#        REPO: browser, desktop, dict or l10n. Needs GH_TOKEN; waits up to
#        $FETCH_RUN_WAIT seconds (default 900) for a run still going. Exits 1 when it refuses the
#        run, 75 when GitHub cannot be read.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
source_repo=$1 run=$2 out=$3 conf=${4:-$here/../conf} stamp=""
api=${GITHUB_API_URL:-https://api.github.com}
wait_limit=${FETCH_RUN_WAIT:-900}
poll=${FETCH_RUN_POLL:-15}
repository_packages=" bande-archive-keyring bande-apt-source "
fail() { echo "fetch-run: $*" >&2; exit 1; }
unavailable() { echo "fetch-run: $*" >&2; exit 75; }
# shellcheck source=scripts/suites.sh
. "$here/suites.sh"
suites=$(suite_list "$conf") || fail "conf/suites is not usable"

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
    browser)
        workflow=.github/workflows/browser-follow-debian.yml
        events=(push schedule workflow_dispatch)
        names=(bande-browser 'bande-browser-l10n-*' bande-firefox-esr-settings)
        component=main
        architectures=(amd64 arm64 all)
        ;;
    *) fail "unknown repository $source_repo; the archive takes browser, desktop, dict and l10n" ;;
esac
repo=bande-linux/desktop

call() {
    curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

call "$api/repos/$repo/actions/runs/$run" > "$work/run.json" || unavailable "cannot read run $run of $repo"
read -r event path ref sha owner < <(jq -r '[.event, .path, .head_branch, .head_sha, .head_repository.full_name] | @tsv' "$work/run.json")
[ "$path" = "$workflow" ] || fail "run $run is from $path, not $workflow"
[ "$owner" = "$repo" ] || fail "run $run built $owner, not $repo"
[[ " ${events[*]} " == *" $event "* ]] || fail "run $run was started by $event; $source_repo publishes from ${events[*]}"
if [ "$source_repo" != browser ]; then
    tag=${ref#refs/tags/}
    if [ "$source_repo" = l10n ]; then
        [[ $tag =~ ^l10n-([0-9]{8}(\.[0-9]+)?)$ ]] || fail "run $run built $ref; the language packs publish l10n-YYYYMMDD tags"
        stamp=${BASH_REMATCH[1]}
    elif [ "$source_repo" = desktop ]; then
        [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-([0-9]+))?$ ]] ||
            fail "run $run built $ref; the desktop publishes vX.Y.Z and vX.Y.Z-R tags"
        want_version=${BASH_REMATCH[1]}-${BASH_REMATCH[3]:-1}
    else
        [[ $tag =~ ^dict-([0-9]{8})$ ]] || fail "run $run built $ref; the dictionary packs publish dict-YYYYMMDD tags"
        want_version=${BASH_REMATCH[1]}-1
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
    call "$api/repos/$repo/actions/runs/$run" > "$work/run.json" || unavailable "cannot read run $run of $repo"
done
[ "$conclusion" = success ] || fail "run $run ended in $conclusion, not success"

status=$(call "$api/repos/$repo/compare/$sha...main" | jq -r .status) || unavailable "cannot compare $sha with main"
case $status in
    identical | ahead) ;;
    *) fail "$sha is not on main ($status)" ;;
esac

call "$api/repos/$repo/actions/runs/$run/artifacts?per_page=100" > "$work/artifacts.json" ||
    unavailable "cannot list the artifacts of run $run"
if [ "$source_repo" = browser ]; then
    mapfile -t named < <(jq -r '.artifacts[].name | select(startswith("bande-version-")) | ltrimstr("bande-version-")' \
        "$work/artifacts.json")
    [ ${#named[@]} -eq 1 ] || fail "run $run names ${#named[@]} versions; it must upload one bande-version-VERSION artifact"
    [[ ${named[0]} =~ ^[0-9][A-Za-z0-9.~-]*\+bande[0-9]+$ ]] || fail "run $run names version ${named[0]}, not <debian-version>+bandeN"
    want_version=${named[0]}
fi
l10n_version() {
    local package=$1 version=$2 number=$3 tag_name status
    [[ $version =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)~deb$number\+l10n([0-9.]+)$ ]] && [ "${BASH_REMATCH[3]}" = "$stamp" ] ||
        fail "$package carries version $version, not X.Y.Z-R~deb$number+l10n$stamp"
    tag_name=v${BASH_REMATCH[1]}
    [ "${BASH_REMATCH[2]}" = 1 ] || tag_name+=-${BASH_REMATCH[2]}
    if ! grep -qxF "$tag_name" "$work/released" 2> /dev/null; then
        status=$(call "$api/repos/$repo/compare/$tag_name...$sha" | jq -r .status) ||
            fail "$package is built on $tag_name, which $repo does not have"
        case $status in
            identical | ahead) echo "$tag_name" >> "$work/released" ;;
            *) fail "$package is built on $tag_name, which is not on the history of $sha ($status)" ;;
        esac
    fi
}

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
        call "$api/repos/$repo/actions/artifacts/$id/zip" > "$work/$name.zip" || unavailable "cannot download $name"
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
            if [ -n "${stamp:-}" ]; then
                l10n_version "$package" "$version" "$number"
            elif [ "$version" != "$want_version~deb$number" ]; then
                fail "$package carries version $version, the run publishes $want_version~deb$number for $suite"
            fi
            echo "$arch $package $version" >> "$work/names"
            mv "$deb" "$work/stage/$suite/"
        done
    done

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
    prefix=bande-debs-$suite-
    if ! jq -e --arg p "$prefix" 'any(.artifacts[]; .name | startswith($p))' "$work/artifacts.json" > /dev/null; then
        echo "fetch-run: run $run built nothing for $suite; it stays as it is" >&2
        continue
    fi
    fetch_suite "$suite"
    fetched+=" $suite"
done
[ -n "$fetched" ] || fail "run $run has no bande-debs-SUITE-ARCH artifacts for any suite of conf/suites: ${suites//$'\n'/ }"

for suite in $fetched; do
    mkdir -p "$out/$suite"
    mv "$work/stage/$suite"/*.deb "$out/$suite/"
done

echo "component=$component"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "component=$component" >> "$GITHUB_OUTPUT"
fi
