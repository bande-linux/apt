#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

host_arch=$(dpkg --print-architecture)
conf=$scratch/conf
make_conf "$conf"
rebuild() { "$root/scripts/rebuild.sh" --conf "$conf" --cache "$scratch/cache" "$@"; }
# listed SITE COMPONENT ARCH: the package=version pairs of one index.
listed() {
    local packages=$1/dists/rolling/$2/binary-$3/Packages
    [ -e "$packages" ] || { echo "$packages is missing" >&2; return 1; }
    grep -h '^Package:\|^Version:' "$packages" | paste - - | awk '{ print $2 "=" $4 }' | sort | tr '\n' ' '
}
has() { [[ " $(listed "$1" "$2" "$3")" == *" $4 "* ]]; }
lacks() { ! has "$@"; }
both() { has "$1" "$2" amd64 "$3" && has "$1" "$2" arm64 "$3"; }
desktop() {
    make_deb "$scratch/in-$1" bande-compositor "$2" amd64
    make_deb "$scratch/in-$1" bande-compositor "$2" arm64
    make_deb "$scratch/in-$1" bande-desktop "$2" all
}
kernel() {
    make_deb "$scratch/in-$1" "linux-image-$2-apple-arm64-16k" "$3" arm64
    make_deb "$scratch/in-$1" linux-image-apple-arm64-16k "$3" arm64
    make_deb "$scratch/in-$1" bande-os-apple "$3" arm64
}
d1=0.0.0+git20261029.1.aaaaaaa

empty=$(mktemp -d -p "$scratch")
refuses "first publish needs --initial" "pass --initial" \
    rebuild --live "$(serve "$empty")" --add desktop:main="$scratch/none" --out "$scratch/x"

desktop 1 "$d1"
for p in bande-archive-keyring bande-apt-source; do make_deb "$scratch/in-1" $p 1.0 all; done
check "initial desktop publish" rebuild --initial --live "$(serve "$empty")" --add desktop:main="$scratch/in-1" --out "$scratch/site-1"
check "main carries the build on amd64 and arm64" both "$scratch/site-1" main "bande-compositor=$d1"
check "main carries the architecture-independent packages on both" both "$scratch/site-1" main "bande-desktop=$d1"
check "main carries the repository packages" both "$scratch/site-1" main bande-apt-source=1.0
check "apple starts empty" sh -c "[ -z \"\$(grep '^Package:' '$scratch/site-1/dists/rolling/apple/binary-arm64/Packages')\" ]"
check "Release lists both components and architectures" sh -c \
    "grep -q '^Components: main apple' '$scratch/site-1/dists/rolling/Release' && grep -q '^Architectures: amd64 arm64' '$scratch/site-1/dists/rolling/Release'"
check "index carries the fingerprint" grep -q "$(gpg --with-colons --show-keys "$conf/archive-key.asc" | awk -F: '/^fpr/ { print $10; exit }')" "$scratch/site-1/index.html"
check "key.asc is published" cmp "$conf/archive-key.asc" "$scratch/site-1/key.asc"

kernel k1 7.2.12 7.2.12-1+bande1
check "kernel publish" rebuild --live "$(serve "$scratch/site-1")" --add kernel:apple="$scratch/in-k1" --out "$scratch/site-k1"
check "apple carries the kernel on arm64" has "$scratch/site-k1" apple arm64 linux-image-7.2.12-apple-arm64-16k=7.2.12-1+bande1
check "apple carries bande-os-apple" has "$scratch/site-k1" apple arm64 bande-os-apple=7.2.12-1+bande1
check "apple stays empty on amd64" sh -c "[ -z \"\$(grep '^Package:' '$scratch/site-k1/dists/rolling/apple/binary-amd64/Packages')\" ]"
check "a kernel publish keeps main" diff <(listed "$scratch/site-1" main arm64) <(listed "$scratch/site-k1" main arm64)

site=$scratch/site-k1
for n in 2 3 4; do
    desktop $n "0.0.0+git20261030.$n.bbbbbb$n"
    check "desktop publish $n" rebuild --live "$(serve "$site")" --add desktop:main="$scratch/in-$n" --out "$scratch/site-$n"
    site=$scratch/site-$n
done
check "main carries the newest build" both "$site" main bande-compositor=0.0.0+git20261030.4.bbbbbb4
check "main dropped the previous build" lacks "$site" main amd64 bande-compositor=0.0.0+git20261030.3.bbbbbb3
check "dropped files leave the pool" test ! -e "$site/pool/main/b/bande-compositor/bande-compositor_${d1}_arm64.deb"
check "repository packages survive rebuilds" has "$site" main arm64 bande-archive-keyring=1.0
check "desktop publishes keep the kernel" has "$site" apple arm64 linux-image-7.2.12-apple-arm64-16k=7.2.12-1+bande1

kernel k2 7.2.14 7.2.14-1+bande1
check "a second kernel" rebuild --live "$(serve "$site")" --add kernel:apple="$scratch/in-k2" --out "$scratch/site-k2"
check "two kernels are both kept" has "$scratch/site-k2" apple arm64 linux-image-7.2.12-apple-arm64-16k=7.2.12-1+bande1
check "the second kernel is in" has "$scratch/site-k2" apple arm64 linux-image-7.2.14-apple-arm64-16k=7.2.14-1+bande1
kernel k3 7.3.1 7.3.1-1+bande2
check "a third kernel" rebuild --live "$(serve "$scratch/site-k2")" --add kernel:apple="$scratch/in-k3" --out "$scratch/site-k3"
site=$scratch/site-k3
check "the newest kernel is in" has "$site" apple arm64 linux-image-7.3.1-apple-arm64-16k=7.3.1-1+bande2
check "the one before it stays" has "$site" apple arm64 linux-image-7.2.14-apple-arm64-16k=7.2.14-1+bande1
check "the oldest kernel is dropped" lacks "$site" apple arm64 linux-image-7.2.12-apple-arm64-16k=7.2.12-1+bande1
check "its file leaves the pool" sh -c "! find '$site/pool' -name 'linux-image-7.2.12-*' | grep -q ."
check "the kernel metapackage follows the newest kernel" has "$site" apple arm64 linux-image-apple-arm64-16k=7.3.1-1+bande2
check "bande-os-apple follows the newest kernel" has "$site" apple arm64 bande-os-apple=7.3.1-1+bande2
check "main is untouched by kernels" diff <(listed "$scratch/site-4" main amd64) <(listed "$site" main amd64)

live=$(serve "$site")
check "republishing the same build changes nothing" rebuild --live "$live" --add desktop:main="$scratch/in-4" --out "$scratch/same"
check "same build gives the same packages" diff <(listed "$site" main arm64) <(listed "$scratch/same" main arm64)
refuses "an older build is refused" "is older than" \
    rebuild --live "$live" --add desktop:main="$scratch/in-2" --out "$scratch/older"
refuses "an older kernel is refused" "is older than" \
    rebuild --live "$live" --add kernel:apple="$scratch/in-k2" --out "$scratch/older-kernel"
make_deb "$scratch/in-changed" bande-compositor 0.0.0+git20261030.4.bbbbbb4 arm64 changed
refuses "a changed package under a published version is refused" "different contents" \
    rebuild --live "$live" --add desktop:main="$scratch/in-changed" --out "$scratch/changed"
make_deb "$scratch/in-split" bande-compositor 0.0.0+git20261031.5.ccccccc arm64
make_deb "$scratch/in-split" bande-greeter 0.0.0+git20261031.6.ddddddd arm64
refuses "one architecture's packages of two versions are refused" "arm64 packages for main carry different versions" \
    rebuild --live "$live" --add desktop:main="$scratch/in-split" --out "$scratch/split"
make_deb "$scratch/in-split-all" bande-compositor 0.0.0+git20261031.5.ccccccc arm64
make_deb "$scratch/in-split-all" bande-desktop 0.0.0+git20261031.6.ddddddd all
refuses "an architecture-independent package of another version is refused" "arm64 packages for main carry different versions" \
    rebuild --live "$live" --add desktop:main="$scratch/in-split-all" --out "$scratch/split-all"
make_deb "$scratch/in-mixed" bande-compositor 0.0.0+git20261031.5.ccccccc amd64
make_deb "$scratch/in-mixed" bande-compositor 0.0.0+git20261031.5.ccccccc arm64
make_deb "$scratch/in-mixed" bande-apt-source 1.1 all
check "repository packages carry their own version" rebuild --live "$live" --add desktop:main="$scratch/in-mixed" --out "$scratch/mixed"
make_deb "$scratch/in-misplaced" bande-archive-keyring 1.1 all
refuses "repository packages stay in main" "belongs in main" \
    rebuild --live "$live" --add kernel:apple="$scratch/in-misplaced" --out "$scratch/misplaced"

desktop 5 0.0.0+git20261031.5.eeeeeee
kernel k4 7.3.2 7.3.2-1+bande1
check "one publish takes a desktop and a kernel" rebuild --live "$live" --add desktop:main="$scratch/in-5" --add kernel:apple="$scratch/in-k4" --out "$scratch/both"
check "main takes the desktop" both "$scratch/both" main bande-compositor=0.0.0+git20261031.5.eeeeeee
check "apple takes the kernel" has "$scratch/both" apple arm64 linux-image-7.3.2-apple-arm64-16k=7.3.2-1+bande1
check "the kernel limit holds across both" lacks "$scratch/both" apple arm64 linux-image-7.2.14-apple-arm64-16k=7.2.14-1+bande1
refuses "every batch is checked" "belongs in main" \
    rebuild --live "$live" --add desktop:main="$scratch/in-5" --add kernel:apple="$scratch/in-misplaced" --out "$scratch/both-bad"

a1=0.1.0+git20261101.3.aaaaaaa a2=0.2.0+git20261101.4.bbbbbbb
for arch in amd64 arm64; do
    make_deb "$scratch/in-apps" bande-weather "$a1" $arch
    make_deb "$scratch/in-apps" bande-clock "$a2" $arch
done
check "an apps publish" rebuild --live "$live" --add-each apps:main="$scratch/in-apps" --processed apps=501,502 --out "$scratch/apps"
check "main takes an app at its own version" both "$scratch/apps" main "bande-weather=$a1"
check "and the other at its own" both "$scratch/apps" main "bande-clock=$a2"
check "the desktop stays beside the apps" both "$scratch/apps" main bande-compositor=0.0.0+git20261030.4.bbbbbb4
check "owners name each source" sh -c "grep -qx 'bande-weather apps' '$scratch/apps/state/owners' && grep -qx 'bande-compositor desktop' '$scratch/apps/state/owners' && grep -qx 'bande-os-apple kernel' '$scratch/apps/state/owners'"
check "the processed runs are kept" sh -c "grep -qx 'apps 501' '$scratch/apps/state/processed' && grep -qx 'apps 502' '$scratch/apps/state/processed'"
apps_live=$(serve "$scratch/apps")
for arch in amd64 arm64; do make_deb "$scratch/in-apps-again" bande-weather "$a1" $arch rebuilt; done
check "a same-version republish of an app is skipped" rebuild --live "$apps_live" --add-each apps:main="$scratch/in-apps-again" --processed apps=503 --out "$scratch/apps-again"
check "the published app is kept" diff <(find "$scratch/apps/pool" -name 'bande-weather_*' -exec sha256sum {} + | awk '{ print $1 }' | sort) \
    <(find "$scratch/apps-again/pool" -name 'bande-weather_*' -exec sha256sum {} + | awk '{ print $1 }' | sort)
check "processed runs carry over and grow" sh -c "grep -qx 'apps 501' '$scratch/apps-again/state/processed' && grep -qx 'apps 503' '$scratch/apps-again/state/processed'"
for arch in amd64 arm64; do make_deb "$scratch/in-apps-old" bande-weather 0.1.0+git20261031.2.9999999 $arch; done
check "an older app is skipped" rebuild --live "$apps_live" --add-each apps:main="$scratch/in-apps-old" --out "$scratch/apps-old"
check "the newer app stays" both "$scratch/apps-old" main "bande-weather=$a1"
check "a publish without apps keeps the processed runs" sh -c "'$root/scripts/rebuild.sh' --conf '$conf' --live '$apps_live' --add desktop:main='$scratch/in-4' --out '$scratch/apps-desktop' > /dev/null && grep -qx 'apps 502' '$scratch/apps-desktop/state/processed'"
for arch in amd64 arm64; do make_deb "$scratch/in-apps-taken" bande-compositor 9.0.0+git20261101.9.ccccccc $arch; done
refuses "an app may not take a desktop package" "bande-compositor is published from desktop, not apps" \
    rebuild --live "$apps_live" --add-each apps:main="$scratch/in-apps-taken" --out "$scratch/apps-taken"
make_deb "$scratch/in-desktop-taken" bande-weather 0.3.0 all
refuses "the desktop may not take an app" "bande-weather is published from apps, not desktop" \
    rebuild --live "$apps_live" --add desktop:main="$scratch/in-desktop-taken" --out "$scratch/desktop-taken"
refuses "two sources may not claim one name in one publish" "is published from desktop, not apps" \
    rebuild --live "$live" --add desktop:main="$scratch/in-desktop-taken" --add-each apps:main="$scratch/in-apps" --out "$scratch/both-claim"

make_deb "$scratch/in-arm64" bande-compositor "$d1" arm64
make_deb "$scratch/in-arm64" bande-desktop "$d1" all
partial_conf=$scratch/partial-conf
cp -r "$conf" "$partial_conf"
sed -i 's/^Architectures: .*/Architectures: arm64/; s/^Components: .*/Components: main/' "$partial_conf/distributions"
(export GNUPGHOME=$conf/gnupg
 "$root/scripts/rebuild.sh" --conf "$partial_conf" --initial --live "$(serve "$empty")" \
    --add desktop:main="$scratch/in-arm64" --out "$scratch/partial") > /dev/null
check "a live Release without amd64 and apple is taken" sh -c \
    "'$root/scripts/rebuild.sh' --conf '$conf' --live '$(serve "$scratch/partial")' --add kernel:apple='$scratch/in-k1' --out '$scratch/grown' > '$scratch/grown.log'"
check "it says what starts empty" grep -q "does not list apple/binary-amd64/Packages.xz yet" "$scratch/grown.log"
check "the arm64 packages carry over" has "$scratch/grown" main arm64 "bande-compositor=$d1"
check "the new architecture starts empty" lacks "$scratch/grown" main amd64 "bande-compositor=$d1"
check "the new component takes the kernel" has "$scratch/grown" apple arm64 linux-image-7.2.12-apple-arm64-16k=7.2.12-1+bande1

tampered=$(mktemp -d -p "$scratch")
cp -r "$site/." "$tampered/"
echo x >> "$tampered/pool/main/b/bande-desktop/bande-desktop_0.0.0+git20261030.4.bbbbbb4_all.deb"
refuses "a tampered pool file is refused" "does not match its signed index" \
    "$root/scripts/rebuild.sh" --conf "$conf" --live "$(serve "$tampered")" --add desktop:main="$scratch/in-4" --out "$scratch/t1"
cp -r "$site/." "$tampered/"
kernel_deb=$(find "$tampered/pool/apple" -type f -name 'linux-image-7.3.1-*.deb')
echo x >> "$kernel_deb"
refuses "a tampered kernel is refused" "does not match its signed index" \
    "$root/scripts/rebuild.sh" --conf "$conf" --live "$(serve "$tampered")" --add desktop:main="$scratch/in-4" --out "$scratch/t1b"
forged=$scratch/forged
(make_conf "$forged" && "$root/scripts/rebuild.sh" --conf "$forged" --initial --live "$(serve "$empty")" \
    --add desktop:main="$scratch/in-1" --out "$scratch/forged-site") > /dev/null
refuses "an index signed by another key is refused" "not signed by the archive key" \
    "$root/scripts/rebuild.sh" --conf "$conf" --live "$(serve "$scratch/forged-site")" --add desktop:main="$scratch/in-4" --out "$scratch/t2"

big=$(mktemp -d -p "$scratch")
cp -r "$site/." "$big/"
truncate -s 96M "$big/pool/huge.deb"
refuses "an unlisted pool file is refused" "not listed" "$root/scripts/check-site.sh" "$big" "$conf/keyring.gpg"
rm "$big/pool/huge.deb"
truncate -s 96M "$big/huge.bin"
refuses "a file over 95 MB is refused" "files over 95 MB" "$root/scripts/check-site.sh" "$big" "$conf/keyring.gpg"
rm "$big/huge.bin"
for i in $(seq 9); do truncate -s 90M "$big/filler-$i.bin"; done
refuses "a site over 800 MB is refused" "over 800 MB" "$root/scripts/check-site.sh" "$big" "$conf/keyring.gpg"
rm "$big"/filler-*.bin
for i in $(seq 7); do truncate -s 90M "$big/filler-$i.bin"; done
check "a site over 600 MB passes with a warning" sh -c "'$root/scripts/check-site.sh' '$big' '$conf/keyring.gpg' 2>&1 | grep -q 'warning: site is'"

lists=$scratch/apt
mkdir -p "$lists/sources.d" "$lists/lists/partial" "$lists/archives/partial"
: > "$lists/status"
chmod -R 755 "$lists"
cp "$conf/keyring.gpg" "$lists/keyring.gpg"
chmod 644 "$lists/keyring.gpg"
cat > "$lists/apt.conf" <<EOF
Dir::Etc::SourceList "/dev/null";
Dir::Etc::SourceParts "$lists/sources.d";
Dir::State::Lists "$lists/lists";
Dir::Cache::Archives "$lists/archives";
Dir::State::status "$lists/status";
Debug::NoLocking "true";
EOF
cat > "$lists/sources.d/bande.sources" <<EOF
Types: deb
URIs: $(serve "$site")
Suites: rolling
Components: main apple
Signed-By: $lists/keyring.gpg
EOF
apt_env=(env APT_CONFIG="$lists/apt.conf")
check "apt accepts the signed archive" "${apt_env[@]}" apt-get update -o APT::Update::Error-Mode=any
check "apt sees the newest desktop build" sh -c "APT_CONFIG='$lists/apt.conf' apt-cache policy bande-compositor | grep -q 'Candidate: 0.0.0+git20261030.4.bbbbbb4'"
if [ "$host_arch" = arm64 ]; then
    check "apt on arm64 sees the newest kernel" sh -c "APT_CONFIG='$lists/apt.conf' apt-cache policy bande-os-apple | grep -q 'Candidate: 7.3.1-1+bande2'"
else
    check "apt on $host_arch sees no kernel" sh -c "! APT_CONFIG='$lists/apt.conf' apt-cache policy bande-os-apple | grep -q Candidate"
fi
check "apt downloads from it" "${apt_env[@]}" apt-get install -y -q --download-only bande-compositor
check "the download is the newest build" test -e "$lists/archives/bande-compositor_0.0.0+git20261030.4.bbbbbb4_${host_arch}.deb"

cp "$conf/archive-key.asc" "$scratch/old-key.asc"
add_archive_key "$conf"
check "rotation: rebuild signs with old and new key" rebuild --live "$(serve "$site")" --add desktop:main="$scratch/in-4" --out "$scratch/rotated"
check "rotation: InRelease carries two signatures" sh -c "[ \$(gpgv --keyring '$conf/keyring.gpg' '$scratch/rotated/dists/rolling/InRelease' 2>&1 | grep -c 'Good signature') = 2 ]"
gpg --dearmor < "$scratch/old-key.asc" > "$scratch/old.gpg"
gpg --dearmor < "$conf/new-key.asc" > "$scratch/new.gpg"
check "rotation: apt with only the old key accepts it" sqv --keyring "$scratch/old.gpg" --output "$scratch/old.txt" --cleartext "$scratch/rotated/dists/rolling/InRelease"
check "rotation: apt with only the new key accepts it" sqv --keyring "$scratch/new.gpg" --output "$scratch/new.txt" --cleartext "$scratch/rotated/dists/rolling/InRelease"
refuses "apt with an unrelated key refuses it" "signature" sqv --keyring "$forged/keyring.gpg" --output "$scratch/forged.txt" --cleartext "$scratch/rotated/dists/rolling/InRelease"

finish
