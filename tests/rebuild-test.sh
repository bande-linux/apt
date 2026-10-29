#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

conf=$scratch/conf
make_conf "$conf"
rebuild() { "$root/scripts/rebuild.sh" --conf "$conf" --cache "$scratch/cache" "$@"; }
listed() { grep -h '^Package:\|^Version:' "$1"/dists/"$2"/main/binary-arm64/Packages | paste - - | awk '{ print $2 "=" $4 }' | sort | tr '\n' ' '; }
has() { [[ " $(listed "$1" "$2")" == *" $3 "* ]]; }
lacks() { ! has "$@"; }
build() { make_deb "$scratch/in-$1" unbound-compositor "$2" arm64; make_deb "$scratch/in-$1" unbound-desktop "$2" all; }

empty=$(mktemp -d -p "$scratch")
refuses "first publish needs --initial" "pass --initial" \
    rebuild --live "$(serve "$empty")" --channel testing --debs "$scratch/none" --out "$scratch/x"

build 1 0.0.0+git20261029.1.aaaaaaa
for p in unbound-archive-keyring unbound-apt-source unbound-apt-source-testing; do make_deb "$scratch/in-1" $p 1.0 all; done
check "initial testing publish" rebuild --initial --live "$(serve "$empty")" --channel testing --debs "$scratch/in-1" --out "$scratch/site-1"
check "testing carries the build" has "$scratch/site-1" trixie-testing unbound-compositor=0.0.0+git20261029.1.aaaaaaa
check "release stays without desktop packages" lacks "$scratch/site-1" trixie unbound-compositor=0.0.0+git20261029.1.aaaaaaa
check "channel packages are in release" has "$scratch/site-1" trixie unbound-apt-source=1.0
check "channel packages are in testing" has "$scratch/site-1" trixie-testing unbound-apt-source-testing=1.0
check "index carries the fingerprint" grep -q "$(gpg --with-colons --show-keys "$conf/archive-key.asc" | awk -F: '/^fpr/ { print $10; exit }')" "$scratch/site-1/index.html"
check "key.asc is published" cmp "$conf/archive-key.asc" "$scratch/site-1/key.asc"

site=$scratch/site-1
n=1
for build_no in 2 3 4; do
    build $build_no "0.0.0+git20261030.$build_no.bbbbbb$build_no"
    check "testing publish $build_no" rebuild --live "$(serve "$site")" --channel testing --debs "$scratch/in-$build_no" --out "$scratch/site-$build_no"
    site=$scratch/site-$build_no
    n=$build_no
done
check "testing carries the newest build" has "$site" trixie-testing unbound-compositor=0.0.0+git20261030.4.bbbbbb4
check "testing dropped the previous build" lacks "$site" trixie-testing unbound-compositor=0.0.0+git20261030.3.bbbbbb3
check "dropped files leave the pool" test ! -e "$site/pool/main/u/unbound-compositor/unbound-compositor_0.0.0+git20261029.1.aaaaaaa_arm64.deb"
check "channel packages survive rebuilds" has "$site" trixie unbound-archive-keyring=1.0

live=$(serve "$site")
check "republishing the same build changes nothing" rebuild --live "$live" --channel testing --debs "$scratch/in-$n" --out "$scratch/same"
check "same build gives the same packages" diff <(listed "$site" trixie-testing) <(listed "$scratch/same" trixie-testing)
refuses "an older build is refused" "is older than" \
    rebuild --live "$live" --channel testing --debs "$scratch/in-2" --out "$scratch/older"
make_deb "$scratch/in-changed" unbound-compositor 0.0.0+git20261030.4.bbbbbb4 arm64 changed
refuses "a changed package under a published version is refused" "different contents" \
    rebuild --live "$live" --channel testing --debs "$scratch/in-changed" --out "$scratch/changed"

make_deb "$scratch/in-old-source" unbound-compositor 0.1.0 arm64
make_deb "$scratch/in-old-source" unbound-apt-source 0.9 all
check "an older channel package from a tag is skipped" rebuild --live "$live" --channel stable --debs "$scratch/in-old-source" --out "$scratch/release"
check "release carries the tag" has "$scratch/release" trixie unbound-compositor=0.1.0
check "release keeps the newer channel package" has "$scratch/release" trixie unbound-apt-source=1.0
check "testing is untouched by a release" diff <(listed "$site" trixie-testing) <(listed "$scratch/release" trixie-testing)

tampered=$(mktemp -d -p "$scratch")
cp -r "$site/." "$tampered/"
echo x >> "$tampered/pool/main/u/unbound-desktop/unbound-desktop_0.0.0+git20261030.4.bbbbbb4_all.deb"
refuses "a tampered pool file is refused" "does not match its signed index" \
    "$root/scripts/rebuild.sh" --conf "$conf" --live "$(serve "$tampered")" --channel testing --debs "$scratch/in-$n" --out "$scratch/t1"
forged=$scratch/forged
(make_conf "$forged" && "$root/scripts/rebuild.sh" --conf "$forged" --initial --live "$(serve "$empty")" \
    --channel testing --debs "$scratch/in-1" --out "$scratch/forged-site") > /dev/null
refuses "an index signed by another key is refused" "not signed by the archive key" \
    "$root/scripts/rebuild.sh" --conf "$conf" --live "$(serve "$scratch/forged-site")" --channel testing --debs "$scratch/in-$n" --out "$scratch/t2"

big=$(mktemp -d -p "$scratch")
cp -r "$scratch/release/." "$big/"
truncate -s 96M "$big/pool/huge.deb"
refuses "an unlisted pool file is refused" "not listed" "$root/scripts/check-site.sh" "$big" "$conf/keyring.gpg"

lists=$scratch/apt
mkdir -p "$lists/sources.d" "$lists/lists/partial" "$lists/archives/partial"
chmod -R 755 "$lists"
cp "$conf/keyring.gpg" "$lists/keyring.gpg"
chmod 644 "$lists/keyring.gpg"
cat > "$lists/apt.conf" <<EOF
Dir::Etc::SourceList "/dev/null";
Dir::Etc::SourceParts "$lists/sources.d";
Dir::State::Lists "$lists/lists";
Dir::Cache::Archives "$lists/archives";
EOF
cat > "$lists/sources.d/unbound.sources" <<EOF
Types: deb
URIs: $(serve "$scratch/release")
Suites: trixie-testing
Components: main
Signed-By: $lists/keyring.gpg
EOF
check "apt accepts the signed archive" env APT_CONFIG="$lists/apt.conf" apt-get update -o APT::Update::Error-Mode=any
check "apt sees the newest testing build" sh -c "APT_CONFIG='$lists/apt.conf' apt-cache policy unbound-compositor | grep -q 'Candidate: 0.0.0+git20261030.4.bbbbbb4'"
check "apt installs from it" env APT_CONFIG="$lists/apt.conf" apt-get install -y -q unbound-compositor

cp "$conf/archive-key.asc" "$scratch/old-key.asc"
add_archive_key "$conf"
check "rotation: rebuild signs with old and new key" rebuild --live "$(serve "$scratch/release")" --channel testing --debs "$scratch/in-$n" --out "$scratch/rotated"
check "rotation: InRelease carries two signatures" sh -c "[ \$(gpgv --keyring '$conf/keyring.gpg' '$scratch/rotated/dists/trixie/InRelease' 2>&1 | grep -c 'Good signature') = 2 ]"
gpg --dearmor < "$scratch/old-key.asc" > "$scratch/old.gpg"
gpg --dearmor < "$conf/new-key.asc" > "$scratch/new.gpg"
check "rotation: apt with only the old key accepts it" sqv --keyring "$scratch/old.gpg" --output "$scratch/old.txt" --cleartext "$scratch/rotated/dists/trixie/InRelease"
check "rotation: apt with only the new key accepts it" sqv --keyring "$scratch/new.gpg" --output "$scratch/new.txt" --cleartext "$scratch/rotated/dists/trixie/InRelease"
refuses "apt with an unrelated key refuses it" "signature" sqv --keyring "$forged/keyring.gpg" --output "$scratch/forged.txt" --cleartext "$scratch/rotated/dists/trixie/InRelease"

finish
