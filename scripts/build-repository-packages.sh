#!/bin/bash
# Usage: build-repository-packages.sh OUT_DIR [CONF_DIR]
#        build-repository-packages.sh --version
# Builds, from packaging/ into OUT_DIR/SUITE for each suite in conf/suites,
# bande-archive-keyring (the keys in conf/archive-key.asc and an APT pin that
# lets the archive provide only Bande's packages), the same for every suite,
# and bande-apt-source (the SUITE main source, and the apple source its
# postinst enables on Apple Silicon). Their version is VERSION = 1.<commits
# that touched packaging/, the keys, conf/suites or this script>, so it rises
# with every change, and the same commit builds the same packages; the source
# package carries VERSION~debNN, as every package built for a suite.
# $REPOSITORY_VERSION overrides the version.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
archive_host=bande-linux.github.io
archive_url=https://$archive_host/apt
keyring=/usr/share/keyrings/bande-archive-keyring.pgp
inputs=(packaging conf/archive-key.asc conf/suites scripts/build-repository-packages.sh)
fail() { echo "build-repository-packages: $*" >&2; exit 1; }

if [ -n "${REPOSITORY_VERSION:-}" ]; then
    version=$REPOSITORY_VERSION
    epoch=${SOURCE_DATE_EPOCH:-0}
else
    [ "$(git -C "$root" rev-parse --is-shallow-repository)" = false ] ||
        fail "$root is a shallow clone, which cannot count the commits; fetch the whole history"
    count=$(git -C "$root" rev-list --count HEAD -- "${inputs[@]}")
    [ "$count" -gt 0 ] || fail "no commit touches ${inputs[*]}"
    version=1.$count
    epoch=$(git -C "$root" log -1 --format=%ct -- "${inputs[@]}")
fi
if [ "${1:-}" = --version ]; then
    echo "$version"
    exit 0
fi
out=${1:?usage: build-repository-packages.sh OUT_DIR [CONF_DIR] | --version}
conf=${2:-$root/conf}
# shellcheck source=scripts/suites.sh
. "$root/scripts/suites.sh"
suites=$(suite_list "$conf") || fail "conf/suites is not usable"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# substitute FILE [SUITE]: FILE with the archive's values, for SUITE.
substitute() {
    local suite=${2:-} number='' suffix=''
    if [ -n "$suite" ]; then number=$(suite_number "$suite") suffix="~deb$number"; fi
    sed -e "s|@ARCHIVE_URL@|$archive_url|g" -e "s|@ARCHIVE_HOST@|$archive_host|g" -e "s|@KEYRING@|$keyring|g" \
        -e "s|@VERSION@|$version|g" -e "s|@SUFFIX@|$suffix|g" -e "s|@SUITE@|$suite|g" -e "s|@NUMBER@|$number|g" "$1"
}

# package NAME DIR [SUITE]: the tree under $work/NAME gets its control paragraph,
# conffiles, maintainer scripts and copyright, then is built into DIR with fixed
# owners, modes and times.
package() {
    local name=$1 dir=$2 suite=${3:-} tree=$work/$1 built
    mkdir -p "$tree/DEBIAN" "$tree/usr/share/doc/$name"
    substitute "$root/packaging/control.in" "$suite" |
        awk -v RS= -v p="$name" '$0 ~ "^Package: " p "\n" { print; exit }' > "$tree/DEBIAN/control"
    [ -s "$tree/DEBIAN/control" ] || fail "packaging/control.in has no $name"
    (cd "$tree" && find etc -type f 2>/dev/null | sed 's|^|/|' | sort) > "$tree/DEBIAN/conffiles"
    [ -s "$tree/DEBIAN/conffiles" ] || rm "$tree/DEBIAN/conffiles"
    cp "$root/packaging/copyright" "$tree/usr/share/doc/$name/copyright"
    find "$tree" -type d -exec chmod 0755 {} +
    find "$tree" -type f -exec chmod 0644 {} +
    for script in postinst postrm; do
        [ ! -e "$root/packaging/$name.$script" ] || install -m 0755 "$root/packaging/$name.$script" "$tree/DEBIAN/$script"
    done
    find "$tree" -exec touch -h -d "@$epoch" {} +
    mkdir -p "$dir"
    built=$(sed -n 's/^Version: //p' "$tree/DEBIAN/control")
    SOURCE_DATE_EPOCH=$epoch dpkg-deb --root-owner-group -Zxz --build "$tree" "$dir/${name}_${built}_all.deb" > /dev/null
    echo "build-repository-packages: $name $built${suite:+ for $suite}"
}

mkdir -p "$work/bande-archive-keyring/usr/share/keyrings" "$work/bande-archive-keyring/etc/apt/preferences.d"
gpg --batch --quiet --dearmor < "$conf/archive-key.asc" > "$work/bande-archive-keyring$keyring"
substitute "$root/packaging/bande.pref.in" > "$work/bande-archive-keyring/etc/apt/preferences.d/bande.pref"
package bande-archive-keyring "$work/keyring"

for suite in $suites; do
    mkdir -p "$out/$suite"
    cp "$work/keyring"/*.deb "$out/$suite/"
    rm -rf "$work/bande-apt-source"
    mkdir -p "$work/bande-apt-source/etc/apt/sources.list.d" "$work/bande-apt-source/usr/share/bande-apt-source"
    substitute "$root/packaging/bande.sources.in" "$suite" > "$work/bande-apt-source/etc/apt/sources.list.d/bande.sources"
    substitute "$root/packaging/bande-apple.sources.in" "$suite" \
        > "$work/bande-apt-source/usr/share/bande-apt-source/bande-apple.sources"
    package bande-apt-source "$out/$suite" "$suite"
done
