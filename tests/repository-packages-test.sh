#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

build() { "$root/scripts/build-repository-packages.sh" "$@"; }
file() { dpkg-deb --fsys-tarfile "$scratch/$1/$2_$3_all.deb" | tar -xO "./$4"; }

version=$(build --version)
check "the version counts the packaging commits" sh -c "echo '$version' | grep -qE '^1\.[1-9][0-9]*$'"
check "the packages build" build "$scratch/a"
check "they carry that version" test -e "$scratch/a/bande-archive-keyring_${version}_all.deb" -a \
    -e "$scratch/a/bande-apt-source_${version}_all.deb"
sleep 1
build "$scratch/b" > /dev/null
check "the same commit builds the same keyring" cmp "$scratch/a/bande-archive-keyring_${version}_all.deb" "$scratch/b/bande-archive-keyring_${version}_all.deb"
check "and the same source package" cmp "$scratch/a/bande-apt-source_${version}_all.deb" "$scratch/b/bande-apt-source_${version}_all.deb"
check "the keyring holds the archive keys" cmp <(gpg --batch --dearmor < "$root/conf/archive-key.asc") \
    <(file a bande-archive-keyring "$version" usr/share/keyrings/bande-archive-keyring.pgp)
check "the source follows rolling main apple" sh -c "$(declare -f file); scratch='$scratch'
    file a bande-apt-source '$version' etc/apt/sources.list.d/bande.sources | grep -qx 'Suites: rolling' &&
    file a bande-apt-source '$version' etc/apt/sources.list.d/bande.sources | grep -qx 'Components: main apple'"
check "the source trusts only the keyring" sh -c "$(declare -f file); scratch='$scratch'
    file a bande-apt-source '$version' etc/apt/sources.list.d/bande.sources | grep -qx 'Signed-By: /usr/share/keyrings/bande-archive-keyring.pgp'"
check "the source depends on the keyring" sh -c "dpkg-deb -f '$scratch/a/bande-apt-source_${version}_all.deb' Depends | grep -qx bande-archive-keyring"
check "the /etc files are conffiles" sh -c "dpkg-deb --ctrl-tarfile '$scratch/a/bande-archive-keyring_${version}_all.deb' | tar -xO ./conffiles | grep -qx /etc/apt/preferences.d/bande.pref"
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
check "the pin lets the archive provide the kernel" grep -qx 'Package: bande-\* xdg-desktop-portal-bande linux-\*-apple-\*' "$scratch/apt/preferences.d/bande.pref"
check "a version can be given" sh -c "REPOSITORY_VERSION=9.9 '$root/scripts/build-repository-packages.sh' '$scratch/c' > /dev/null && test -e '$scratch/c/bande-apt-source_9.9_all.deb'"
shallow=$scratch/shallow
git clone -q --depth 1 "file://$root" "$shallow" 2> /dev/null
refuses "a shallow clone cannot count the commits" "shallow clone" "$shallow/scripts/build-repository-packages.sh" --version

finish
