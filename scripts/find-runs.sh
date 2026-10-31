#!/bin/bash
# Usage: find-runs.sh LIVE_URL [CONF_DIR]
# Prints "REPO RUN_ID" for each source run newer than what the live, signature-
# checked archive serves, one per line, nothing when all is published:
# - desktop: the green release.yml push of the highest vX.Y.Z tag, whose
#   version is the tag; the live one is bande-desktop's in main;
# - kernel: the newest green follow-debian.yml schedule or dispatch run on main
#   with a bande-version-VERSION artifact; the live one is bande-os-apple's in
#   apple;
# - apps: every green build.yml push or dispatch run on main of the last
#   $FIND_RUNS_DAYS days (default 14) that uploaded packages and is not in the
#   live state/processed. Each run carries only the apps it built, so all of
#   them are taken; rebuild.sh skips app versions already published.
# fetch-run.sh checks each printed run in full. Needs GH_TOKEN; both
# repositories are public.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
live=${1%/} conf=${2:-$here/../conf}
api=${GITHUB_API_URL:-https://api.github.com}
days=${FIND_RUNS_DAYS:-14}
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

code=$(curl -sS --retry 3 -o "$work/InRelease" -w '%{http_code}' "$live/dists/rolling/InRelease") ||
    fail "cannot fetch $live/dists/rolling/InRelease"
case $code in
    200)
        gpgv --quiet --keyring "$work/keyring.gpg" --output "$work/Release" "$work/InRelease" 2>/dev/null ||
            fail "rolling/InRelease is not signed by the archive key"
        ;;
    404) echo "find-runs: $live serves no archive yet" >&2 ;;
    *) fail "$live/dists/rolling/InRelease answered HTTP $code" ;;
esac

# live_version COMPONENT ARCH PACKAGE: its version in the live archive, or
# nothing when the archive, the index or the package is missing.
live_version() {
    local index=$1/binary-$2/Packages.xz sha
    [ -e "$work/Release" ] || return 0
    sha=$(awk -v p="$index" '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f && $3 == p { print $1 }' "$work/Release")
    [ -n "$sha" ] || return 0
    curl -fsS --retry 3 -o "$work/index.xz" "$live/dists/rolling/$index" || fail "rolling/$index is listed but missing"
    echo "$sha  $work/index.xz" | sha256sum -c --quiet - || fail "rolling/$index does not match Release"
    xz -dc "$work/index.xz" | awk -v RS= -v p="$3" '$0 ~ "(^|\n)Package: " p "\n" {
        for (i = 1; i <= NF; i++) if ($i == "Version:") print $(i + 1)
    }' | head -1
}

newer() { [ -z "$2" ] || dpkg --compare-versions "$1" gt "$2"; }

listing "$api/repos/bande-linux/desktop/actions/workflows/release.yml/runs?event=push&status=success&per_page=100" \
    "$work/desktop.json" '{"workflow_runs": []}' "the desktop's release runs"
desktop_run='' desktop_version=''
while read -r id ref; do
    [[ ${ref#refs/tags/} =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || continue
    if [ -z "$desktop_version" ] || dpkg --compare-versions "${BASH_REMATCH[1]}" gt "$desktop_version"; then
        desktop_run=$id desktop_version=${BASH_REMATCH[1]}
    fi
done < <(jq -r '.workflow_runs[] | select(.event == "push" and .conclusion == "success") | "\(.id) \(.head_branch)"' \
    "$work/desktop.json")
if [ -n "$desktop_run" ]; then
    served=$(live_version main arm64 bande-desktop)
    if newer "$desktop_version" "$served"; then
        echo "desktop $desktop_run"
    else
        echo "find-runs: desktop $desktop_version (run $desktop_run) is published" >&2
    fi
else
    echo "find-runs: the desktop has no green vX.Y.Z release run" >&2
fi

listing "$api/repos/bande-linux/kernel/actions/artifacts?per_page=100" "$work/kernel.json" '{"artifacts": []}' \
    "the kernel's artifacts"
kernel_run='' kernel_version=''
while read -r id version; do
    call "$api/repos/bande-linux/kernel/actions/runs/$id" > "$work/run.json" || fail "cannot read kernel run $id"
    jq -e '.path == ".github/workflows/follow-debian.yml" and .head_branch == "main" and .conclusion == "success"
        and (.event == "schedule" or .event == "workflow_dispatch")' "$work/run.json" > /dev/null || continue
    kernel_run=$id kernel_version=$version
    break
done < <(jq -r '.artifacts[] | select((.name | startswith("bande-version-")) and (.expired | not))
    | "\(.workflow_run.id) \(.name | ltrimstr("bande-version-"))"' "$work/kernel.json" | head -20)
if [ -n "$kernel_run" ]; then
    served=$(live_version apple arm64 bande-os-apple)
    if newer "$kernel_version" "$served"; then
        echo "kernel $kernel_run"
    else
        echo "find-runs: kernel $kernel_version (run $kernel_run) is published" >&2
    fi
else
    echo "find-runs: the kernel has no green run that built a kernel" >&2
fi

: > "$work/processed"
if [ -e "$work/Release" ]; then
    code=$(curl -sS --retry 3 -o "$work/processed" -w '%{http_code}' "$live/state/processed") ||
        fail "cannot fetch $live/state/processed"
    case $code in
        200) ;;
        404) : > "$work/processed" ;;
        *) fail "$live/state/processed answered HTTP $code" ;;
    esac
fi
since=$(date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ)
listing "$api/repos/bande-linux/apps/actions/workflows/build.yml/runs?branch=main&status=success&created=%3E%3D$since&per_page=100" \
    "$work/apps.json" '{"workflow_runs": []}' "the apps' build runs"
while read -r id; do
    if grep -qx "apps $id" "$work/processed"; then continue; fi
    call "$api/repos/bande-linux/apps/actions/runs/$id/artifacts?per_page=100" > "$work/artifacts.json" ||
        fail "cannot list the artifacts of apps run $id"
    if jq -e '[.artifacts[] | select((.expired | not) and (.name == "bande-debs-arm64" or .name == "bande-debs-amd64"))]
        | length == 2' "$work/artifacts.json" > /dev/null; then
        echo "apps $id"
    fi
done < <(jq -r --arg since "$since" '.workflow_runs[] | select(.head_branch == "main" and .conclusion == "success"
    and (.event == "push" or .event == "workflow_dispatch") and .created_at >= $since) | .id' "$work/apps.json")
