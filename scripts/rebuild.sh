#!/bin/bash
# Usage: rebuild.sh --live URL --add|--add-each|--add-l10n SOURCE:COMPONENT=DIR [...] --out DIR
#                   [--processed SOURCE=ID,...] [--conf DIR] [--cache DIR]
# Rebuilds the whole archive, every suite conf/suites lists, from the live,
# signature-checked site plus the packages in each DIR/SUITE, which come from
# the repository SOURCE and go to its COMPONENT (main or apple) of SUITE, signs
# it with the keys in conf/signing-keys (secret keys in $GNUPGHOME) and writes
# the site to --out. A DIR may hold packages for some suites only.
# - --add: one build, whose packages on each architecture carry one version; a
#   version older than the published one, or one published with other
#   contents, is refused.
# - --add-each: packages built on their own; one whose version is already
#   published, or older, is skipped.
# - --add-l10n: language packs of a translation-only build, each at
#   RELEASE+l10nSTAMP for the package it enhances at RELEASE. A pack is added only
#   while that package is at RELEASE in the archive, after this publish's other
#   additions, so a pack built on an older release, or on one not published
#   yet, is skipped; otherwise as --add-each.
# Each package keeps its newest version only, and apple keeps the packages of
# its newest two kernel versions only, in each suite. The suites share one pool.
#
# The site also keeps state/owners, the source each package comes from: a
# package of another source's name is refused, unless conf/handovers moves it:
# "PACKAGE FROM TO" gives a name FROM published to TO. And state/processed, the runs
# of each source already taken (--processed adds to it), which find-runs.sh
# reads.
#
# Release is written by apt-ftparchive, with Acquire-By-Hash: every index is
# also published under by-hash/SHA256/<sha256>, which never changes, so a client
# holding any InRelease the Pages CDN served finds the matching indexes.
# apt-ftparchive keeps the last $by_hash_keep generations of them in each
# directory; state/by-hash lists them, since Pages cannot list a directory, and
# the next publish restores them from the live site. Mutable files (InRelease,
# state) are read past the CDN with fetch-fresh.sh, indexes by hash.
#
# A suite the live site does not serve yet (no dists/SUITE/InRelease) starts
# empty. A site that serves no suite's InRelease nor key.asc has never been
# published, and the archive starts empty. One that serves key.asc but no
# suite's InRelease is refused, so a broken site is never published over.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/suites.sh
. "$here/suites.sh"
# The keyring and source packages are built by this repository (source apt) and
# live in main.
repository_packages=" bande-archive-keyring bande-apt-source "
# Kernel packages carry the kernel version in their name, so each kernel stays
# until it is dropped; keep_kernels bounds how many fit within the Pages limit.
kernel_packages='linux-*-apple-*'
keep_kernels=2
by_hash_keep=3
# Valid-Until, as Debian's archives set it: apt refuses an InRelease past it, so
# an old one cannot be replayed. look.yml re-signs once fewer than 7 days remain.
valid_days=14

conf=$here/../conf
site_template=$here/../site
live='' out='' cache=''
batches=() processed=()
while [ $# -gt 0 ]; do
    case $1 in
        --live) live=${2%/}; shift 2 ;;
        --add) batches+=("one $2"); shift 2 ;;
        --add-each) batches+=("each $2"); shift 2 ;;
        --add-l10n) batches+=("l10n $2"); shift 2 ;;
        --processed) processed+=("$2"); shift 2 ;;
        --out) out=$2; shift 2 ;;
        --conf) conf=$2; shift 2 ;;
        --cache) cache=$2; shift 2 ;;
        *) echo "rebuild: unknown argument $1" >&2; exit 2 ;;
    esac
done
fail() { echo "rebuild: $*" >&2; exit 1; }
if [ -z "$live" ] || [ $((${#batches[@]} + ${#processed[@]})) -eq 0 ] || [ -z "$out" ]; then
    fail "--live, --add, --add-each, --add-l10n or --processed, and --out are required"
fi
conf=$(cd "$conf" && pwd)
[ -s "$conf/archive-key.asc" ] || fail "$conf/archive-key.asc is missing"
signing_keys=$(grep -v '^\s*$' "$conf/signing-keys" | tr '\n' ' ' | sed 's/ $//')
[ -n "$signing_keys" ] || fail "$conf/signing-keys lists no key"
[ ! -e "$out" ] || [ -z "$(ls -A "$out")" ] || fail "$out is not empty"
[ -z "$cache" ] || mkdir -p "$cache"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/pool" "$work/live"
gpg --batch --quiet --dearmor < "$conf/archive-key.asc" > "$work/keyring.gpg"

# conf/distribution.in is the reprepro stanza of every suite, @SUITE@ its
# codename and @NUMBER@ its Debian version number.
suites=$(suite_list "$conf") || fail "conf/suites is not usable"
stanza() { sed -e "s/@SUITE@/$1/g" -e "s/@NUMBER@/$(suite_number "$1")/g" "$conf/distribution.in"; }
# field SUITE FIELD: a field of SUITE's stanza.
field() { stanza "$1" | awk -v f="$2" 'index($0, f ": ") == 1 { sub("^" f ": ", ""); print; exit }'; }
components=$(field "${suites%%$'\n'*}" Components)
architectures=$(field "${suites%%$'\n'*}" Architectures)
for batch in "${batches[@]}"; do
    [[ ${batch#* } =~ ^[a-z]+:[a-z]+=. ]] || fail "${batch#* } is not SOURCE:COMPONENT=DIR"
    component=${batch#*:} component=${component%%=*}
    [[ " $components " == *" $component "* ]] || fail "the archive has no component $component"
done
for entry in "${processed[@]}"; do
    [[ $entry =~ ^[a-z0-9-]+=[0-9]+(,[0-9]+)*$ ]] || fail "--processed $entry is not SOURCE=ID,..."
done

get() {
    local code
    code=$(curl -sS --retry 3 -o "$2" -w '%{http_code}' "$1") || fail "cannot fetch $1"
    case $code in
        200) return 0 ;;
        404) return 1 ;;
        *) fail "$1 answered HTTP $code" ;;
    esac
}

# fresh PATH OUT: like get for $live/PATH, past the Pages CDN, for files a
# publish replaces.
fresh() {
    local code
    code=$("$here/fetch-fresh.sh" "$live" "$1" "$2") || fail "cannot fetch $live/$1"
    case $code in
        200) return 0 ;;
        404) return 1 ;;
        *) fail "$live/$1 answered HTTP $code" ;;
    esac
}

# live_index SUITE PATH SHA256 OUT: an index of the live SUITE's Release, by hash.
live_index() {
    get "$live/dists/$1/$(dirname "$2")/by-hash/SHA256/$3" "$4" || fail "$1/$2 is listed but missing"
    echo "$3  $4" | sha256sum -c --quiet - || fail "$1/$2 does not match Release"
}

release_sha256() {
    awk -v p="$2" '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f && $3 == p { print $1 }' "$1"
}

pool_file() {
    local sha=$1 filename=$2 dest=$work/pool/$1.deb
    [ -e "$dest" ] && return 0
    if [ -n "$cache" ] && [ -e "$cache/$sha.deb" ]; then
        cp "$cache/$sha.deb" "$dest"
    else
        get "$live/$filename" "$dest" || fail "$live/$filename is listed but missing"
    fi
    echo "$sha  $dest" | sha256sum -c --quiet - || fail "$filename does not match its signed index"
    [ -z "$cache" ] || cp "$dest" "$cache/$sha.deb"
}

describe() {
    dpkg-deb --show --showformat="\${Package} \${Architecture} \${Version}\n" "$1"
}

# Rows: "SUITE/COMPONENT PACKAGE ARCH VERSION FILE", the live packages and then
# the new ones.
: > "$work/rows"
live_suites=''
for suite in $suites; do
    dist=$work/live/$suite
    mkdir -p "$dist"
    if ! fresh "dists/$suite/InRelease" "$dist/InRelease"; then
        echo "rebuild: $live serves no $suite yet; it starts empty"
        continue
    fi
    live_suites+=" $suite"
    gpgv --quiet --keyring "$work/keyring.gpg" --output "$dist/Release" "$dist/InRelease" 2>/dev/null ||
        fail "$suite/InRelease is not signed by the archive key"
    for c in $components; do
        for arch in $architectures; do
            index=$c/binary-$arch/Packages.xz
            sha=$(release_sha256 "$dist/Release" "$index")
            if [ -z "$sha" ]; then
                # A component or architecture added since the last publish.
                echo "rebuild: $suite/Release does not list $index yet; starting it empty"
                continue
            fi
            live_index "$suite" "$index" "$sha" "$dist/$c-$arch.xz"
            xz -dc "$dist/$c-$arch.xz" |
                awk -v RS= '{
                    for (i = 1; i <= NF; i++) { if ($i == "Filename:") f = $(i + 1); if ($i == "SHA256:") s = $(i + 1) }
                    print s, f
                }' > "$dist/$c-$arch.files"
            while read -r sha filename; do
                pool_file "$sha" "$filename"
                echo "$suite/$c $(describe "$work/pool/$sha.deb") $work/pool/$sha.deb" >> "$work/rows"
            done < "$dist/$c-$arch.files"
        done
    done
done
if [ -n "$live_suites" ]; then
    for state in owners processed; do
        fresh "state/$state" "$work/$state" || : > "$work/$state"
    done
elif fresh key.asc "$work/live-key.asc"; then
    fail "$live serves key.asc but no suite's InRelease; refusing to start the archive over"
else
    echo "rebuild: $live has never been published; starting the archive"
fi
touch "$work/owners" "$work/processed"
sort -u -o "$work/rows" "$work/rows"

newest() {
    local best=
    while read -r version; do
        if [ -z "$best" ] || dpkg --compare-versions "$version" gt "$best"; then best=$version; fi
    done
    echo "$best"
}

shopt -s nullglob
: > "$work/new"
handovers=$conf/handovers
[ -f "$handovers" ] || handovers=/dev/null
awk 'FILENAME == ARGV[1] { if ($0 !~ /^#/ && NF == 3) to[$1 " " $2] = $3; next }
    ($1 " " $2) in to { $2 = to[$1 " " $2] } { print }' "$handovers" "$work/owners" > "$work/claims"
for batch in "${batches[@]}"; do
    mode=${batch%% *} batch=${batch#* }
    source=${batch%%:*} component=${batch#*:} component=${component%%=*} debs=${batch#*=}
    # DIR holds one directory per suite; one it lacks gets nothing.
    stray=("$debs"/*.deb)
    [ ${#stray[@]} -eq 0 ] || fail "$debs holds packages outside a suite's directory"
    for dir in "$debs"/*/; do
        dir=${dir%/}
        [[ $'\n'$suites$'\n' == *$'\n'${dir##*/}$'\n'* ]] || fail "$dir is not a suite conf/suites lists"
    done
    : > "$work/batch"
    for suite in $suites; do
        for deb in "$debs/$suite"/*.deb; do
            read -r package arch version < <(describe "$deb")
            if [[ $repository_packages == *" $package "* ]]; then
                [ "$source" = apt ] || fail "$package is built by apt itself, not $source"
                [ "$component" = main ] || fail "$package belongs in main, not $component"
            fi
            owner=$(awk -v p="$package" '$1 == p { print $2; exit }' "$work/claims")
            [ -z "$owner" ] || [ "$owner" = "$source" ] || fail "$package is published from $owner, not $source"
            echo "$mode $suite/$component $package $arch $version $deb" >> "$work/batch"
        done
    done
    [ -s "$work/batch" ] || fail "no packages in $debs"
    awk -v s="$source" '{ print $3, s }' "$work/batch" | sort -u >> "$work/claims"

    # One build: in each suite, on each architecture, its own and the
    # architecture-independent packages carry one version.
    awk '{ print $2 }' "$work/batch" | sort -u > "$work/dists"
    while [ "$mode" = one ] && read -r c; do
        built=$(awk -v c="$c" '$2 == c && $4 != "all" { print $4 }' "$work/batch" | sort -u)
        for arch in ${built:-all}; do
            versions=$(awk -v c="$c" -v a="$arch" '$2 == c && ($4 == a || $4 == "all") { print $5 }' "$work/batch" | sort -u)
            [ "$(wc -l <<< "$versions")" -le 1 ] ||
                fail "the $arch packages for $c carry different versions: $(tr '\n' ' ' <<< "$versions")"
        done
    done < "$work/dists"
    cat "$work/batch" >> "$work/new"
done

# add MODE COMPONENT PACKAGE ARCH VERSION DEB: one new package, as its mode says.
add() {
    local mode=$1 c=$2 package=$3 arch=$4 version=$5 deb=$6 sha same top base release served
    if [ "$mode" = l10n ]; then
        base=$(dpkg-deb -f "$deb" Enhances)
        [[ $base =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || fail "$package enhances \"$base\", not one package"
        [[ $version =~ ^(.+)\+l10n[0-9]{8}(\.[0-9]+)?$ ]] || fail "$package $version is not RELEASE+l10nYYYYMMDD"
        release=${BASH_REMATCH[1]}
        served=$(awk -v c="$c" -v p="$base" '$1 == c && $2 == p { print $4 }' "$work/rows" | newest)
        if [ "$served" != "$release" ]; then
            echo "rebuild: skipping $package $version, built for $base $release; $c has ${served:-no $base}"
            return 0
        fi
        mode=each
    fi
    sha=$(sha256sum "$deb" | cut -d' ' -f1)
    same=$(awk -v c="$c" -v p="$package" -v a="$arch" -v v="$version" \
        '$1 == c && $2 == p && $3 == a && $4 == v { print $5 }' "$work/rows")
    if [ -n "$same" ]; then
        if [ "$mode" = each ]; then
            echo "rebuild: $package $version ($arch) is already in $c; keeping the published one"
            return 0
        fi
        [ "$(sha256sum "$same" | cut -d' ' -f1)" = "$sha" ] ||
            fail "$package $version ($arch) is already in $c with different contents"
        return 0
    fi
    top=$(awk -v c="$c" -v p="$package" -v a="$arch" '$1 == c && $2 == p && $3 == a { print $4 }' \
        "$work/rows" | newest)
    if [ -n "$top" ] && dpkg --compare-versions "$version" lt "$top"; then
        if [ "$mode" = each ]; then
            echo "rebuild: skipping $package $version ($arch), older than $top in $c"
            return 0
        fi
        fail "$package $version ($arch) is older than $top in $c"
    fi
    cp "$deb" "$work/pool/$sha.deb"
    echo "$c $package $arch $version $work/pool/$sha.deb" >> "$work/rows"
    echo "rebuild: adding $package $version ($arch) to $c"
}
# Language packs last, against the releases this publish adds.
while read -r mode c package arch version deb; do
    [ "$mode" = l10n ] || add "$mode" "$c" "$package" "$arch" "$version" "$deb"
done < "$work/new"
while read -r mode c package arch version deb; do
    [ "$mode" != l10n ] || add "$mode" "$c" "$package" "$arch" "$version" "$deb"
done < "$work/new"

mkdir -p "$work/repo/conf"
for suite in $suites; do stanza "$suite"; echo; done > "$work/repo/conf/distributions"
cp "$conf/options" "$work/repo/conf/options"
awk '{ print $1, $2, $3 }' "$work/rows" | sort -u > "$work/groups"
: > "$work/chosen"
while read -r c package arch; do
    rows=$(awk -v c="$c" -v p="$package" -v a="$arch" '$1 == c && $2 == p && $3 == a' "$work/rows")
    top=$(awk '{ print $4 }' <<< "$rows" | newest)
    awk -v v="$top" '$4 == v { print; exit }' <<< "$rows" >> "$work/chosen"
done < "$work/groups"

# shellcheck disable=SC2053 # kernel_packages is a glob pattern
is_kernel() { [ "${1#*/}" = apple ] && [[ $2 == $kernel_packages ]]; }
# Each suite's apple keeps its own newest kernels.
declare -A kept
for suite in $suites; do
    kernels=$(while read -r c package _ version _; do
        if [ "$c" = "$suite/apple" ] && is_kernel "$c" "$package"; then echo "$version"; fi
    done < "$work/chosen" | sort -u)
    kept[$suite]=''
    for _ in $(seq "$keep_kernels"); do
        top=$({ grep -vxF -f <(printf '%s\n' "${kept[$suite]}") <<< "$kernels" || true; } | newest)
        [ -z "$top" ] || kept[$suite]+="$top"$'\n'
    done
done
while read -r c package arch version path; do
    if is_kernel "$c" "$package" && ! grep -qxF -- "$version" <<< "${kept[${c%/*}]}"; then
        echo "rebuild: dropping $package $version ($arch) from $c, older than the newest $keep_kernels kernels"
        continue
    fi
    reprepro --silent -b "$work/repo" --export=silent-never -C "${c#*/}" includedeb "${c%/*}" "$path"
done < "$work/chosen"
reprepro --silent -b "$work/repo" export

# The earlier generations' by-hash files, as state/by-hash lists them: "MTIME
# PATH", where PATH is under dists/ and starts with its suite. apt-ftparchive
# keeps the newest by mtime, so each keeps its exact time there, since two
# quick publishes would tie on the whole-second Release Date.
public=$work/repo/public/dists
: > "$work/by-hash"
if [ -n "$live_suites" ]; then
    fresh state/by-hash "$work/by-hash" || fail "the live site lists no state/by-hash"
fi
sort -k2,2 -u "$work/by-hash" | while read -r mtime path; do
    [[ $mtime =~ ^[0-9]+(\.[0-9]+)?$ && $path =~ ^([a-z0-9-]+/)+by-hash/SHA256/([0-9a-f]{64})$ ]] ||
        fail "state/by-hash lists $mtime $path"
    sha=${path##*/} dest=$public/$path
    # A directory the archive no longer has keeps nothing.
    [ -d "$public/${path%/by-hash/*}" ] || continue
    mkdir -p "$(dirname "$dest")"
    if ! get "$live/dists/$path" "$dest"; then
        echo "rebuild: $path is gone from the live site; not keeping it"
        rm -f "$dest"
        continue
    fi
    echo "$sha  $dest" | sha256sum -c --quiet - || fail "$path does not match its name"
    touch -d "@$mtime" "$dest"
done

# Each suite's Release, by apt-ftparchive: SHA256 sums, Acquire-By-Hash,
# Valid-Until $valid_days days out, and by-hash copies of every index, keeping
# the newest $by_hash_keep generations in each directory.
signers=()
for key in $signing_keys; do signers+=(--local-user "$key"); done
for suite in $suites; do
    rm -f "$public/$suite/Release"
    release_options=()
    for f in Origin Label Suite Codename Architectures Components Description; do
        release_options+=(-o "APT::FTPArchive::Release::$f=$(field "$suite" "$f")")
    done
    (cd "$public/$suite" && apt-ftparchive "${release_options[@]}" -o APT::FTPArchive::DoByHash=true \
        -o APT::FTPArchive::Release::ValidTime=$((valid_days * 86400)) \
        -o APT::FTPArchive::By-Hash-Keep="$by_hash_keep" -o APT::FTPArchive::MD5=false \
        -o APT::FTPArchive::SHA1=false -o APT::FTPArchive::SHA512=false release . > "$work/Release")
    mv "$work/Release" "$public/$suite/Release"
    gpg --batch --yes --digest-algo SHA512 "${signers[@]}" --clearsign -o "$public/$suite/InRelease" "$public/$suite/Release"
    gpg --batch --yes --digest-algo SHA512 "${signers[@]}" --armor --detach-sign -o "$public/$suite/Release.gpg" \
        "$public/$suite/Release"
done

mkdir -p "$out"
cp -r "$work/repo/public/." "$out/"
cp "$conf/archive-key.asc" "$out/key.asc"
fingerprint=$(gpg --batch --with-colons --show-keys "$conf/archive-key.asc" | awk -F: '/^fpr/ { print $10; exit }')
sed "s/@FINGERPRINT@/$fingerprint/g" "$site_template/index.html" > "$out/index.html"

mkdir -p "$out/state"
for suite in $suites; do reprepro -b "$work/repo" list "$suite"; done | awk '{ print $2 }' | sort -u | while read -r package; do
    awk -v p="$package" '$1 == p { print; exit }' "$work/claims"
done > "$out/state/owners"
for entry in "${processed[@]}"; do
    tr , '\n' <<< "${entry#*=}" | sed "s/^/${entry%%=*} /" >> "$work/processed"
done
awk '!seen[$0]++' "$work/processed" | tail -n 2000 > "$out/state/processed"
(cd "$public" && find . -path '*/by-hash/SHA256/*' -type f -printf '%T@ %P\n' | sort -k2) > "$out/state/by-hash"

"$here/check-site.sh" "$out" "$work/keyring.gpg"
for suite in $suites; do
    echo "== $suite"
    reprepro -b "$work/repo" list "$suite" | sed 's/^/   /'
done
