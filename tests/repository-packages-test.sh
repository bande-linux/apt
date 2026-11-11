#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

build() { "$root/scripts/build-repository-packages.sh" "$@"; }
# file DIR PACKAGE VERSION PATH: PATH in forky's PACKAGE at VERSION under DIR.
file() { dpkg-deb --fsys-tarfile "$scratch/$1/forky/$2_$3_all.deb" | tar -xO "./$4"; }

version=$(build --version)
check "the version counts the packaging commits" sh -c "echo '$version' | grep -qE '^1\.[1-9][0-9]*$'"
check "the packages build" build "$scratch/a"
check "the keyring carries that version, the source forky's suffix too" test -e "$scratch/a/forky/bande-archive-keyring_${version}_all.deb" -a \
    -e "$scratch/a/forky/bande-apt-source_${version}~deb14_all.deb"
sleep 1
build "$scratch/b" > /dev/null
check "the same commit builds the same keyring" cmp "$scratch/a/forky/bande-archive-keyring_${version}_all.deb" "$scratch/b/forky/bande-archive-keyring_${version}_all.deb"
check "and the same source package" cmp "$scratch/a/forky/bande-apt-source_${version}~deb14_all.deb" "$scratch/b/forky/bande-apt-source_${version}~deb14_all.deb"
check "the keyring holds the archive keys" cmp <(gpg --batch --dearmor < "$root/conf/archive-key.asc") \
    <(file a bande-archive-keyring "$version" usr/share/keyrings/bande-archive-keyring.pgp)
check "the source follows forky main only" sh -c "$(declare -f file); scratch='$scratch'
    file a bande-apt-source '$version~deb14' etc/apt/sources.list.d/bande.sources | grep -qx 'Suites: forky' &&
    file a bande-apt-source '$version~deb14' etc/apt/sources.list.d/bande.sources | grep -qx 'Components: main'"
check "it carries the apple source outside /etc" sh -c "$(declare -f file); scratch='$scratch'
    file a bande-apt-source '$version~deb14' usr/share/bande-apt-source/bande-apple.sources | grep -qx 'Components: apple' &&
    file a bande-apt-source '$version~deb14' usr/share/bande-apt-source/bande-apple.sources | grep -qx 'Signed-By: /usr/share/keyrings/bande-archive-keyring.pgp'"
check "its postinst and postrm are executable and the postinst reads the device tree" sh -c "
    dpkg-deb --ctrl-tarfile '$scratch/a/forky/bande-apt-source_${version}~deb14_all.deb' | tar -tvf - | grep -E '^-rwxr-xr-x .* \\./postinst$' &&
    dpkg-deb --ctrl-tarfile '$scratch/a/forky/bande-apt-source_${version}~deb14_all.deb' | tar -tvf - | grep -E '^-rwxr-xr-x .* \\./postrm$' &&
    dpkg-deb --ctrl-tarfile '$scratch/a/forky/bande-apt-source_${version}~deb14_all.deb' | tar -xO ./postinst | grep -qF /proc/device-tree/compatible"
check "the source trusts only the keyring" sh -c "$(declare -f file); scratch='$scratch'
    file a bande-apt-source '$version~deb14' etc/apt/sources.list.d/bande.sources | grep -qx 'Signed-By: /usr/share/keyrings/bande-archive-keyring.pgp'"
check "the source depends on the keyring" sh -c "dpkg-deb -f '$scratch/a/forky/bande-apt-source_${version}~deb14_all.deb' Depends | grep -qx bande-archive-keyring"
check "the /etc files are conffiles" sh -c "dpkg-deb --ctrl-tarfile '$scratch/a/forky/bande-archive-keyring_${version}_all.deb' | tar -xO ./conffiles | grep -qx /etc/apt/preferences.d/bande.pref"
mkdir -p "$scratch/apt/preferences.d"
file a bande-archive-keyring "$version" etc/apt/preferences.d/bande.pref > "$scratch/apt/preferences.d/bande.pref"
mkdir -p "$scratch/apt/sources.d" "$scratch/apt/lists/partial"
: > "$scratch/apt/status"
: > "$scratch/apt/apt.conf"
policy() {
    APT_CONFIG="$scratch/apt/apt.conf" apt-cache -o Dir::Etc::SourceList="$scratch/apt/no-sources" -o Dir::Etc::SourceParts="$scratch/apt/sources.d" \
        -o Dir::State::Lists="$scratch/apt/lists" -o Dir::State::status="$scratch/apt/status" \
        -o Dir::Etc::Preferences="$scratch/apt/no-preferences" -o Dir::Etc::PreferencesParts="$1" policy 2>&1
}
check "apt reads the pin" sh -c "$(declare -f policy); scratch='$scratch'; policy '$scratch/apt/preferences.d' | { ! grep -q '^[EW]:'; }"
mkdir -p "$scratch/broken"
printf 'Package: *\nPin: origin x\nPin-Priority: high\n' > "$scratch/broken/broken.pref"
check "a broken pin would show" sh -c "$(declare -f policy); scratch='$scratch'; policy '$scratch/broken' | grep -q '^[EW]:'"
check "the pin lets the archive provide the kernel" grep -qx 'Package: bande-\* xdg-desktop-portal-bande libpam-bande-secrets linux-\*-apple-\*' "$scratch/apt/preferences.d/bande.pref"
check "a version can be given" sh -c "REPOSITORY_VERSION=9.9 '$root/scripts/build-repository-packages.sh' '$scratch/c' > /dev/null && test -e '$scratch/c/forky/bande-apt-source_9.9~deb14_all.deb'"
two=$scratch/two
mkdir -p "$two" && cp "$root/conf/archive-key.asc" "$two/" && printf 'forky\nduke\n' > "$two/suites"
check "two suites build" build "$scratch/d" "$two"
check "one source package per suite, at its suffix" test -e "$scratch/d/forky/bande-apt-source_${version}~deb14_all.deb" -a \
    -e "$scratch/d/duke/bande-apt-source_${version}~deb15_all.deb" -a ! -e "$scratch/d/duke/bande-apt-source_${version}~deb14_all.deb"
check "each follows its suite" sh -c "$(declare -f file); scratch='$scratch'
    file d bande-apt-source '$version~deb14' etc/apt/sources.list.d/bande.sources | grep -qx 'Suites: forky' &&
    dpkg-deb --fsys-tarfile '$scratch/d/duke/bande-apt-source_${version}~deb15_all.deb' | tar -xO ./etc/apt/sources.list.d/bande.sources | grep -qx 'Suites: duke' &&
    dpkg-deb --fsys-tarfile '$scratch/d/duke/bande-apt-source_${version}~deb15_all.deb' | tar -xO ./usr/share/bande-apt-source/bande-apple.sources | grep -qx 'Suites: duke'"
check "and says so" sh -c "dpkg-deb -f '$scratch/d/duke/bande-apt-source_${version}~deb15_all.deb' Description | grep -q 'duke suite of the Bande APT repository for Debian\$' && dpkg-deb -f '$scratch/d/duke/bande-apt-source_${version}~deb15_all.deb' Description | grep -q '15 (duke)'"
check "the keyring is the same for both, without a suffix" cmp "$scratch/d/forky/bande-archive-keyring_${version}_all.deb" "$scratch/d/duke/bande-archive-keyring_${version}_all.deb"
printf 'forky\nsid\n' > "$two/suites"
refuses "a suite without a Debian version number is refused" "gives sid no Debian version number" build "$scratch/e" "$two"
printf 'forky\nforky\n' > "$two/suites"
refuses "a suite listed twice is refused" "lists forky twice" build "$scratch/e" "$two"
: > "$two/suites"
refuses "no suite is refused" "lists no suite" build "$scratch/e" "$two"

shallow=$scratch/shallow
git clone -q --depth 1 "file://$root" "$shallow" 2> /dev/null
refuses "a shallow clone cannot count the commits" "shallow clone" "$shallow/scripts/build-repository-packages.sh" --version

finish
