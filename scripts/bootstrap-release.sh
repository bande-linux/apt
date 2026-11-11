#!/bin/bash
# Usage: bootstrap-release.sh DIR
# Creates the GitHub release apt-source-VERSION, marked latest, unless it
# already exists. It holds the repository packages found under DIR: the one
# bande-archive-keyring at VERSION and a bande-apt-source at VERSION~debNN for
# each suite, under their own names and version-less ones,
# bande-archive-keyring.deb and bande-apt-source-SUITE.deb (SUITE as its
# bande.sources names it). Needs GH_TOKEN and GH_REPO.
set -euo pipefail

dir=$1
fail() { echo "bootstrap-release: $*" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
version() { dpkg-deb --show --showformat="\${Version}" "$1"; }

# The keyring is the same for every suite: DIR may hold copies of it.
mapfile -t keyrings < <(find "$dir" -name 'bande-archive-keyring_*_all.deb' | sort)
[ ${#keyrings[@]} -gt 0 ] || fail "expected a bande-archive-keyring package in $dir"
for keyring in "${keyrings[@]}"; do
    cmp -s "$keyring" "${keyrings[0]}" || fail "$keyring differs from ${keyrings[0]}"
done
version=$(version "${keyrings[0]}")
cp "${keyrings[0]}" "$work/bande-archive-keyring.deb"
assets=("${keyrings[0]}" "$work/bande-archive-keyring.deb")

mapfile -t sources < <(find "$dir" -name 'bande-apt-source_*_all.deb' | sort)
[ ${#sources[@]} -gt 0 ] || fail "expected a bande-apt-source package in $dir"
for source in "${sources[@]}"; do
    v=$(version "$source")
    [[ $v =~ ^$version~deb[0-9]+$ ]] || fail "bande-apt-source is $v, the keyring is $version"
    suite=$(dpkg-deb --fsys-tarfile "$source" | tar -xO ./etc/apt/sources.list.d/bande.sources | sed -n 's/^Suites: //p')
    [[ $suite =~ ^[a-z]+$ ]] || fail "$source follows \"$suite\", not one suite"
    [ ! -e "$work/bande-apt-source-$suite.deb" ] || fail "two bande-apt-source packages follow $suite"
    cp "$source" "$work/bande-apt-source-$suite.deb"
    assets+=("$source" "$work/bande-apt-source-$suite.deb")
done

tag=apt-source-$version
if gh release view "$tag" > /dev/null 2>&1; then
    echo "bootstrap-release: $tag exists"
    exit 0
fi
gh release create "$tag" "${assets[@]}" --latest --title "Repository packages $version" --notes \
    "Install the keyring and your Debian release's source package to add the Bande repository; see https://bande-linux.github.io/apt"
echo "bootstrap-release: created $tag"
