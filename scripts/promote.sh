#!/bin/bash
# Usage: promote.sh FROM_VERSION TO_VERSION DIR
# Rewrites the packages in DIR that carry FROM_VERSION to TO_VERSION, including
# exact-version relations between them. Only the control file changes; the
# installed files stay byte for byte the ones that were tested.
set -euo pipefail

from=$1 to=$2 dir=$3
fail() { echo "promote: $*" >&2; exit 1; }
quoted=$(printf '%s' "$from" | sed 's/[.+~]/\\&/g')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
manifest() {
    local files=$work/files
    rm -rf "$files"
    dpkg-deb --extract "$1" "$files"
    (cd "$files" && find . -printf '%p %m %u %g %s %l\n' | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort)
}

shopt -s nullglob
promoted=0
for deb in "$dir"/*.deb; do
    read -r package version arch < <(dpkg-deb --show --showformat="\${Package} \${Version} \${Architecture}\n" "$deb")
    [ "$version" = "$from" ] || continue
    tree=$work/$package-$arch
    dpkg-deb --raw-extract "$deb" "$tree"
    sed -i -E \
        -e "s/^Version: .*/Version: $to/" \
        -e "/^(Pre-)?Depends|^Recommends|^Suggests|^Breaks|^Conflicts|^Replaces|^Provides|^Enhances/s/\(= $quoted\)/(= $to)/g" \
        "$tree/DEBIAN/control"
    ! grep -q -- "$from" "$tree/DEBIAN/control" || fail "$package still names $from after promotion"
    out=$dir/${package}_${to}_${arch}.deb
    dpkg-deb --build "$tree" "$out" > /dev/null
    [ "$(manifest "$deb")" = "$(manifest "$out")" ] || fail "$package changed its files"
    rm "$deb"
    rm -rf "$tree"
    promoted=$((promoted + 1))
    echo "promote: $package $from -> $to ($arch)"
done
[ "$promoted" -gt 0 ] || fail "no package in $dir carries $from"
