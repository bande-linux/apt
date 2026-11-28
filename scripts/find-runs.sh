#!/bin/bash
# Usage: find-runs.sh LIVE_URL [CONF_DIR]
# Prints "REPO RUN_ID" for each source run newer than what the live, signature-
# checked archive serves, one per line, nothing when all is published. A live
# version is the newest of the package's across the suites in conf/suites,
# compared without the suite's ~debNN, as the tags name the release alone:
# - apt: "apt VERSION" when $APT_VERSION, the version of the keyring and source
#   packages this repository builds, is newer than the live
#   bande-archive-keyring's in any suite (a new suite has none);
# - desktop: the green release.yml push of the highest vX.Y.Z or vX.Y.Z-R tag,
#   whose version is X.Y.Z-R (R is 1 for vX.Y.Z); the live one is
#   bande-desktop's in main;
# - dict: the green dict.yml push of the desktop's highest dict-YYYYMMDD tag,
#   whose version is YYYYMMDD-1; the live one is bande-dict-en's in main;
# - browser: the newest green browser-follow-debian.yml run on main of the
#   desktop with a bande-version-VERSION artifact; the live one is
#   bande-browser's in main;
# - l10n: the green l10n.yml push of the desktop's highest l10n-YYYYMMDD[.N]
#   tag, translation-only language packs. It waits while a
#   release tag on the run's history is newer than what the archive serves or
#   this publish takes, since its packs are built on that release (rebuild.sh
#   --add-l10n).
# - resign: "resign VALID_UNTIL" when a suite's live InRelease has fewer than 7
#   days left before its Valid-Until (the earliest), or none. An InRelease past
#   it may be an old one replayed: it is no base for new runs, so only "resign
#   expired" is printed, and the publish re-signs the archive from its verified
#   signature.
# A run the live state/processed lists, which holds the runs a publish took or
# refused, is not printed again.
# InRelease and state/processed are read past the Pages CDN (fetch-fresh.sh),
# and the indexes by hash, so a publish in progress cannot mix generations.
# fetch-run.sh checks each printed run in full. Needs GH_TOKEN; the source
# repositories are public.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
live=${1%/} conf=${2:-$here/../conf}
api=${GITHUB_API_URL:-https://api.github.com}
fail() { echo "find-runs: $*" >&2; exit 1; }

call() {
    curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

# listing URL OUT EMPTY WHAT: fetches an API listing into OUT. A repository or
# workflow that does not exist (yet) answers 404: OUT gets EMPTY, which means
# nothing new from that source. Network errors and other answers fail.
listing() {
    local code
    code=$(curl -sSL --retry 3 -o "$2" -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" \
        -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$1") ||
        fail "cannot list $4"
    case $code in
        200) ;;
        404)
            echo "find-runs: $4 not found (HTTP 404); nothing new from it" >&2
            echo "$3" > "$2"
            ;;
        *) fail "listing $4 answered HTTP $code" ;;
    esac
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gpg --batch --quiet --dearmor < "$conf/archive-key.asc" > "$work/keyring.gpg"

# shellcheck source=scripts/suites.sh
. "$here/suites.sh"
suites=$(suite_list "$conf") || fail "conf/suites is not usable"
resign='' resign_seconds='' live_suites=''
for suite in $suites; do
    code=$("$here/fetch-fresh.sh" "$live" "dists/$suite/InRelease" "$work/$suite.InRelease") ||
        fail "cannot fetch $live/dists/$suite/InRelease"
    case $code in
        200) ;;
        404) echo "find-runs: $live serves no $suite yet" >&2; continue ;;
        *) fail "$live/dists/$suite/InRelease answered HTTP $code" ;;
    esac
    gpgv --quiet --keyring "$work/keyring.gpg" --output "$work/$suite.Release" "$work/$suite.InRelease" 2>/dev/null ||
        fail "$suite/InRelease is not signed by the archive key"
    live_suites+=" $suite"
    until=$(sed -n 's/^Valid-Until: //p' "$work/$suite.Release")
    if [ -z "$until" ]; then
        resign=${resign:-none}
        continue
    fi
    seconds=$(date -d "$until" +%s) || fail "$suite/InRelease has an unreadable Valid-Until: $until"
    left=$((seconds - $(date +%s)))
    if [ "$left" -le 0 ]; then
        echo "find-runs: warning: $suite/InRelease expired at $until; re-signing it, no new runs taken" >&2
        echo "resign expired"
        exit 0
    fi
    if [ "$left" -lt $((7 * 86400)) ]; then
        if [ -z "$resign_seconds" ] || [ "$seconds" -lt "$resign_seconds" ]; then resign_seconds=$seconds; fi
    else
        echo "find-runs: $suite/InRelease is valid until $until" >&2
    fi
done
if [ "$resign" = none ]; then
    echo "resign none"
elif [ -n "$resign_seconds" ]; then
    echo "resign $(date -u -d "@$resign_seconds" +%Y-%m-%dT%H:%MZ)"
fi
[ -n "$live_suites" ] || echo "find-runs: $live serves no archive yet" >&2

# suite_version SUITE COMPONENT ARCH PACKAGE: its version in the live SUITE,
# or nothing when the suite, the index or the package is missing.
suite_version() {
    local suite=$1 index=$2/binary-$3/Packages.xz sha
    [ -e "$work/$suite.Release" ] || return 0
    sha=$(awk -v p="$index" '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f && $3 == p { print $1 }' "$work/$suite.Release")
    [ -n "$sha" ] || return 0
    curl -fs --retry 3 -o "$work/index.xz" "$live/dists/$suite/$2/binary-$3/by-hash/SHA256/$sha" ||
        fail "$suite/$index is listed but missing"
    echo "$sha  $work/index.xz" | sha256sum -c --quiet - || fail "$suite/$index does not match Release"
    xz -dc "$work/index.xz" | awk -v RS= -v p="$4" '$0 ~ "(^|\n)Package: " p "\n" {
        for (i = 1; i <= NF; i++) if ($i == "Version:") print $(i + 1)
    }' | head -1
}

# live_version COMPONENT ARCH PACKAGE: the newest of its versions across the
# live suites, each without its suite's ~debNN; nothing when none has it.
live_version() {
    local suite version best=''
    for suite in $live_suites; do
        version=$(suite_version "$suite" "$@")
        [ -n "$version" ] || continue
        version=$(release_part "$suite" "$version")
        if [ -z "$best" ] || dpkg --compare-versions "$version" gt "$best"; then best=$version; fi
    done
    echo "$best"
}

newer() { [ -z "$2" ] || dpkg --compare-versions "$1" gt "$2"; }

# release_version TAG: the Debian version a desktop release tag builds,
# X.Y.Z-R for vX.Y.Z-R and X.Y.Z-1 for vX.Y.Z; false for any other tag.
release_version() {
    [[ $1 =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-([0-9]+))?$ ]] || return 1
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[3]:-1}"
}

if [ -n "${APT_VERSION:-}" ]; then
    behind=''
    for suite in $suites; do
        if newer "$APT_VERSION" "$(suite_version "$suite" main arm64 bande-archive-keyring)"; then behind+=" $suite"; fi
    done
    if [ -n "$behind" ]; then
        echo "apt $APT_VERSION"
    else
        echo "find-runs: the repository packages $APT_VERSION are published" >&2
    fi
fi

: > "$work/processed"
if [ -n "$live_suites" ]; then
    code=$("$here/fetch-fresh.sh" "$live" state/processed "$work/processed") ||
        fail "cannot fetch $live/state/processed"
    case $code in
        200) ;;
        404) : > "$work/processed" ;;
        *) fail "$live/state/processed answered HTTP $code" ;;
    esac
fi
# taken SOURCE RUN: true when a publish already took or refused the run.
taken() { grep -qx "$1 $2" "$work/processed"; }

listing "$api/repos/bande-linux/desktop/actions/workflows/release.yml/runs?event=push&status=success&per_page=100" \
    "$work/desktop.json" '{"workflow_runs": []}' "the desktop's release runs"
desktop_run='' desktop_version='' desktop_next=''
while read -r id ref; do
    version=$(release_version "${ref#refs/tags/}") || continue
    if [ -z "$desktop_version" ] || dpkg --compare-versions "$version" gt "$desktop_version"; then
        desktop_run=$id desktop_version=$version
    fi
done < <(jq -r '.workflow_runs[] | select(.event == "push" and .conclusion == "success") | "\(.id) \(.head_branch)"' \
    "$work/desktop.json")
if [ -n "$desktop_run" ]; then
    served=$(live_version main arm64 bande-desktop)
    desktop_next=$served
    if taken desktop "$desktop_run"; then
        echo "find-runs: desktop $desktop_version (run $desktop_run) was taken or refused" >&2
    elif newer "$desktop_version" "$served"; then
        echo "desktop $desktop_run"
        desktop_next=$desktop_version
    else
        echo "find-runs: desktop $desktop_version (run $desktop_run) is published" >&2
    fi
else
    echo "find-runs: the desktop has no green vX.Y.Z[-R] release run" >&2
fi

listing "$api/repos/bande-linux/desktop/actions/workflows/dict.yml/runs?event=push&status=success&per_page=100" \
    "$work/dict.json" '{"workflow_runs": []}' "the dictionary pack runs"
dict_run='' dict_version=''
while read -r id ref; do
    [[ ${ref#refs/tags/} =~ ^dict-([0-9]{8})$ ]] || continue
    if [ -z "$dict_version" ] || dpkg --compare-versions "${BASH_REMATCH[1]}-1" gt "$dict_version"; then
        dict_run=$id dict_version=${BASH_REMATCH[1]}-1
    fi
done < <(jq -r '.workflow_runs[] | select(.event == "push" and .conclusion == "success") | "\(.id) \(.head_branch)"' \
    "$work/dict.json")
if [ -n "$dict_run" ]; then
    served=$(live_version main arm64 bande-dict-en)
    if taken dict "$dict_run"; then
        echo "find-runs: the dictionary packs $dict_version (run $dict_run) were taken or refused" >&2
    elif newer "$dict_version" "$served"; then
        echo "dict $dict_run"
    else
        echo "find-runs: the dictionary packs $dict_version (run $dict_run) are published" >&2
    fi
else
    echo "find-runs: the desktop has no green dict-YYYYMMDD run" >&2
fi

listing "$api/repos/bande-linux/desktop/actions/artifacts?per_page=100" "$work/artifacts.json" '{"artifacts": []}' \
    "the desktop's artifacts"
browser_run='' browser_version=''
while read -r id named; do
    call "$api/repos/bande-linux/desktop/actions/runs/$id" > "$work/run.json" || fail "cannot read desktop run $id"
    jq -e '.path == ".github/workflows/browser-follow-debian.yml" and .head_branch == "main" and .conclusion == "success"
        and (.event == "push" or .event == "schedule" or .event == "workflow_dispatch")' "$work/run.json" > /dev/null || continue
    browser_run=$id browser_version=$named
    break
done < <(jq -r '.artifacts[] | select((.name | startswith("bande-version-")) and (.expired | not))
    | "\(.workflow_run.id) \(.name | ltrimstr("bande-version-"))"' "$work/artifacts.json" | head -20)
if [ -n "$browser_run" ]; then
    served=$(live_version main arm64 bande-browser)
    if taken browser "$browser_run"; then
        echo "find-runs: browser $browser_version (run $browser_run) was taken or refused" >&2
    elif newer "$browser_version" "$served"; then
        echo "browser $browser_run"
    else
        echo "find-runs: browser $browser_version (run $browser_run) is published" >&2
    fi
else
    echo "find-runs: the desktop has no green browser run that built a package" >&2
fi

# release_waits SHA NEXT: true, naming it, when the desktop's highest release
# tag is newer than NEXT, the version the archive will serve, and is on the
# history of SHA.
release_waits() {
    local sha=$1 next=$2 tag='' version='' name built status
    while read -r name; do
        built=$(release_version "$name") || continue
        if [ -z "$version" ] || dpkg --compare-versions "$built" gt "$version"; then
            tag=$name version=$built
        fi
    done < <(jq -r '.[].ref | ltrimstr("refs/tags/")' "$work/tags.json")
    [ -n "$tag" ] && newer "$version" "$next" || return 1
    status=$(call "$api/repos/bande-linux/desktop/compare/$tag...$sha" | jq -r .status) ||
        fail "cannot compare desktop $tag with $sha"
    [ "$status" = ahead ] || [ "$status" = identical ] || return 1
    echo "$tag"
}

run='' stamp='' sha=''
listing "$api/repos/bande-linux/desktop/actions/workflows/l10n.yml/runs?event=push&status=success&per_page=100" \
    "$work/l10n.json" '{"workflow_runs": []}' "the desktop's language pack runs"
while read -r id ref head; do
    [[ ${ref#refs/tags/} =~ ^l10n-([0-9]{8}(\.[0-9]+)?)$ ]] || continue
    if [ -z "$stamp" ] || dpkg --compare-versions "${BASH_REMATCH[1]}" gt "$stamp"; then
        run=$id stamp=${BASH_REMATCH[1]} sha=$head
    fi
done < <(jq -r '.workflow_runs[] | select(.event == "push" and .conclusion == "success")
    | "\(.id) \(.head_branch) \(.head_sha)"' "$work/l10n.json")
if [ -z "$run" ]; then
    echo "find-runs: the desktop has no green l10n-YYYYMMDD run" >&2
elif taken l10n "$run"; then
    echo "find-runs: the language packs l10n-$stamp of the desktop (run $run) were taken" >&2
else
    listing "$api/repos/bande-linux/desktop/git/matching-refs/tags/" "$work/tags.json" '[]' "the desktop's tags"
    if waits=$(release_waits "$sha" "${desktop_next:-$(live_version main arm64 bande-desktop)}"); then
        echo "find-runs: the language packs l10n-$stamp of the desktop (run $run) wait for $waits to be published" >&2
    else
        echo "l10n $run"
    fi
fi
