#!/bin/bash
# Usage: build-repository-packages.sh OUT_DIR
#        build-repository-packages.sh --version
# Builds bande-archive-keyring (the keys in conf/archive-key.asc and an APT pin
# that lets the archive provide only Bande's packages) and bande-apt-source
# (the rolling source) from packaging/ into OUT_DIR. Their version is
# 1.<commits that touched packaging/, the keys or this script>, so it rises
# with every change, and the same commit builds the same packages.
# $REPOSITORY_VERSION overrides the version.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
archive_host=bande-linux.github.io
archive_url=https://$archive_host/apt
keyring=/usr/share/keyrings/bande-archive-keyring.pgp
inputs=(packaging conf/archive-key.asc scripts/build-repository-packages.sh)
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
out=${1:?usage: build-repository-packages.sh OUT_DIR | --version}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
substitute() {
    sed -e "s|@ARCHIVE_URL@|$archive_url|g" -e "s|@ARCHIVE_HOST@|$archive_host|g" -e "s|@KEYRING@|$keyring|g" \
        -e "s|@VERSION@|$version|g" "$1"
}

# package NAME: the tree under $work/NAME gets its control paragraph, conffiles
# and copyright, then is built with fixed owners, modes and times.
package() {
    local name=$1 tree=$work/$1
    mkdir -p "$tree/DEBIAN" "$tree/usr/share/doc/$name"
    substitute "$root/packaging/control.in" |
        awk -v RS= -v p="$name" '$0 ~ "^Package: " p "\n" { print; exit }' > "$tree/DEBIAN/control"
    [ -s "$tree/DEBIAN/control" ] || fail "packaging/control.in has no $name"
    (cd "$tree" && find etc -type f 2>/dev/null | sed 's|^|/|' | sort) > "$tree/DEBIAN/conffiles"
    [ -s "$tree/DEBIAN/conffiles" ] || rm "$tree/DEBIAN/conffiles"
    cp "$root/packaging/copyright" "$tree/usr/share/doc/$name/copyright"
    find "$tree" -type d -exec chmod 0755 {} +
    find "$tree" -type f -exec chmod 0644 {} +
    find "$tree" -exec touch -h -d "@$epoch" {} +
    mkdir -p "$out"
    SOURCE_DATE_EPOCH=$epoch dpkg-deb --root-owner-group -Zxz --build "$tree" "$out/${name}_${version}_all.deb" > /dev/null
    echo "build-repository-packages: $name $version"
}

mkdir -p "$work/bande-archive-keyring/usr/share/keyrings" "$work/bande-archive-keyring/etc/apt/preferences.d"
gpg --batch --quiet --dearmor < "$root/conf/archive-key.asc" > "$work/bande-archive-keyring$keyring"
substitute "$root/packaging/bande.pref.in" > "$work/bande-archive-keyring/etc/apt/preferences.d/bande.pref"
package bande-archive-keyring

mkdir -p "$work/bande-apt-source/etc/apt/sources.list.d"
substitute "$root/packaging/bande.sources.in" > "$work/bande-apt-source/etc/apt/sources.list.d/bande.sources"
package bande-apt-source
