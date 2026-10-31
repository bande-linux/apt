#!/bin/bash
# Usage: bootstrap-release.sh DIR
# Creates the GitHub release apt-source-VERSION, marked latest, holding the
# repository packages in DIR under their own and version-less names, unless it
# already exists. Needs GH_TOKEN and GH_REPO.
set -euo pipefail

dir=$1
packages=(bande-archive-keyring bande-apt-source)
fail() { echo "bootstrap-release: $*" >&2; exit 1; }

version=''
assets=()
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for package in "${packages[@]}"; do
    files=("$dir/${package}"_*_all.deb)
    if [ ! -e "${files[0]}" ] || [ ${#files[@]} -ne 1 ]; then
        fail "expected one $package package in $dir"
    fi
    v=$(dpkg-deb --show --showformat="\${Version}" "${files[0]}")
    if [ -n "$version" ] && [ "$v" != "$version" ]; then
        fail "$package is $v, the others are $version"
    fi
    version=$v
    cp "${files[0]}" "$work/$package.deb"
    assets+=("${files[0]}" "$work/$package.deb")
done

tag=apt-source-$version
if gh release view "$tag" > /dev/null 2>&1; then
    echo "bootstrap-release: $tag exists"
    exit 0
fi
gh release create "$tag" "${assets[@]}" --latest --title "Repository packages $version" --notes \
    "Install both packages to add the Bande repository; see https://bande-linux.github.io/apt"
echo "bootstrap-release: created $tag"
