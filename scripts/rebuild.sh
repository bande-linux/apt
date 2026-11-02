#!/bin/bash
# Usage: rebuild.sh --live URL --add|--add-each SOURCE:COMPONENT=DIR [...] --out DIR
#                   [--processed SOURCE=ID,...] [--conf DIR] [--cache DIR]
# Rebuilds the whole archive from the live, signature-checked site plus the
# packages in each DIR, which come from the repository SOURCE and go to its
# COMPONENT (main or apple), signs it with the keys in conf/signing-keys (secret
# keys in $GNUPGHOME) and writes the site to --out.
# - --add: one build, whose packages on each architecture carry one version; a
#   version older than the published one, or one published with other
#   contents, is refused.
# - --add-each: packages built on their own; one whose version is already
#   published, or older, is skipped.
# Each package keeps its newest version only, and apple keeps the packages of
# its newest two kernel versions only.
#
# The site also keeps state/owners, the source each package comes from: a
# package of another source's name is refused. And state/processed, the runs
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
# A site that serves neither dists/rolling/InRelease nor key.asc has never been
# published, and the archive starts empty. One that serves key.asc but no
# InRelease is refused, so a broken site is never published over.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
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
        --processed) processed+=("$2"); shift 2 ;;
        --out) out=$2; shift 2 ;;
        --conf) conf=$2; shift 2 ;;
        --cache) cache=$2; shift 2 ;;
        *) echo "rebuild: unknown argument $1" >&2; exit 2 ;;
    esac
done
fail() { echo "rebuild: $*" >&2; exit 1; }
if [ -z "$live" ] || [ $((${#batches[@]} + ${#processed[@]})) -eq 0 ] || [ -z "$out" ]; then
    fail "--live, --add, --add-each or --processed, and --out are required"
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

field() {
    awk -v f="$1" 'index($0, f ": ") == 1 { sub("^" f ": ", ""); print; exit }' "$conf/distributions"
}
suite=$(field Codename)
components=$(field Components)
architectures=$(field Architectures)
for batch in "${batches[@]}"; do
    [[ ${batch#* } =~ ^[a-z]+:[a-z]+=. ]] || fail "${batch#* } is not SOURCE:COMPONENT=DIR"
    component=${batch#*:} component=${component%%=*}
    [[ " $components " == *" $component "* ]] || fail "$suite has no component $component"
done
for entry in "${processed[@]}"; do
    [[ $entry =~ ^[a-z]+=[0-9]+(,[0-9]+)*$ ]] || fail "--processed $entry is not SOURCE=ID,..."
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

# live_index PATH SHA256 OUT: an index of the live Release, by hash; a site
# published before by-hash has none, and serves it under PATH only.
live_index() {
    get "$live/dists/$suite/$(dirname "$1")/by-hash/SHA256/$2" "$3" ||
        fresh "dists/$suite/$1" "$3" || fail "$suite/$1 is listed but missing"
    echo "$2  $3" | sha256sum -c --quiet - || fail "$suite/$1 does not match Release"
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

: > "$work/rows"
mkdir -p "$work/live/$suite"
dist=$work/live/$suite
if fresh "dists/$suite/InRelease" "$dist/InRelease"; then
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
            live_index "$index" "$sha" "$dist/$c-$arch.xz"
            xz -dc "$dist/$c-$arch.xz" |
                awk -v RS= '{
                    for (i = 1; i <= NF; i++) { if ($i == "Filename:") f = $(i + 1); if ($i == "SHA256:") s = $(i + 1) }
                    print s, f
                }' > "$dist/$c-$arch.files"
            while read -r sha filename; do
                pool_file "$sha" "$filename"
                echo "$c $(describe "$work/pool/$sha.deb") $work/pool/$sha.deb" >> "$work/rows"
            done < "$dist/$c-$arch.files"
        done
    done
    for state in owners processed; do
        fresh "state/$state" "$work/$state" || : > "$work/$state"
    done
elif fresh key.asc "$work/live-key.asc"; then
    fail "$live serves key.asc but no dists/$suite/InRelease; refusing to start the archive over"
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
cp "$work/owners" "$work/claims"
for batch in "${batches[@]}"; do
    mode=${batch%% *} batch=${batch#* }
    source=${batch%%:*} component=${batch#*:} component=${component%%=*} debs=${batch#*=}
    new=("$debs"/*.deb)
    [ ${#new[@]} -gt 0 ] || fail "no packages in $debs"
    : > "$work/batch"
    for deb in "${new[@]}"; do
        read -r package arch version < <(describe "$deb")
        if [[ $repository_packages == *" $package "* ]]; then
            [ "$source" = apt ] || fail "$package is built by apt itself, not $source"
            [ "$component" = main ] || fail "$package belongs in main, not $component"
        fi
        owner=$(awk -v p="$package" '$1 == p { print $2; exit }' "$work/claims")
        [ -z "$owner" ] || [ "$owner" = "$source" ] || fail "$package is published from $owner, not $source"
        echo "$mode $component $package $arch $version $deb" >> "$work/batch"
    done
    awk -v s="$source" '{ print $3, s }' "$work/batch" | sort -u >> "$work/claims"

    # One build: on each architecture, its own and the architecture-independent
    # packages carry one version.
    built=$(awk '$4 != "all" { print $4 }' "$work/batch" | sort -u)
    for arch in ${built:-all}; do
        [ "$mode" = one ] || break
        versions=$(awk -v a="$arch" '$4 == a || $4 == "all" { print $5 }' "$work/batch" | sort -u)
        [ "$(wc -l <<< "$versions")" -le 1 ] ||
            fail "the $arch packages for $component carry different versions: $(tr '\n' ' ' <<< "$versions")"
    done
    cat "$work/batch" >> "$work/new"
done

while read -r mode c package arch version deb; do
    sha=$(sha256sum "$deb" | cut -d' ' -f1)
    same=$(awk -v c="$c" -v p="$package" -v a="$arch" -v v="$version" \
        '$1 == c && $2 == p && $3 == a && $4 == v { print $5 }' "$work/rows")
    if [ -n "$same" ]; then
        if [ "$mode" = each ]; then
            echo "rebuild: $package $version ($arch) is already in $c; keeping the published one"
            continue
        fi
        [ "$(sha256sum "$same" | cut -d' ' -f1)" = "$sha" ] ||
            fail "$package $version ($arch) is already in $c with different contents"
        continue
    fi
    top=$(awk -v c="$c" -v p="$package" -v a="$arch" '$1 == c && $2 == p && $3 == a { print $4 }' \
        "$work/rows" | newest)
    if [ -n "$top" ] && dpkg --compare-versions "$version" lt "$top"; then
        if [ "$mode" = each ]; then
            echo "rebuild: skipping $package $version ($arch), older than $top in $c"
            continue
        fi
        fail "$package $version ($arch) is older than $top in $c"
    fi
    cp "$deb" "$work/pool/$sha.deb"
    echo "$c $package $arch $version $work/pool/$sha.deb" >> "$work/rows"
    echo "rebuild: adding $package $version ($arch) to $c"
done < "$work/new"

mkdir -p "$work/repo/conf"
cp "$conf/distributions" "$work/repo/conf/distributions"
cp "$conf/options" "$work/repo/conf/options"
awk '{ print $1, $2, $3 }' "$work/rows" | sort -u > "$work/groups"
: > "$work/chosen"
while read -r c package arch; do
    rows=$(awk -v c="$c" -v p="$package" -v a="$arch" '$1 == c && $2 == p && $3 == a' "$work/rows")
    top=$(awk '{ print $4 }' <<< "$rows" | newest)
    awk -v v="$top" '$4 == v { print; exit }' <<< "$rows" >> "$work/chosen"
done < "$work/groups"

# shellcheck disable=SC2053 # kernel_packages is a glob pattern
is_kernel() { [ "$1" = apple ] && [[ $2 == $kernel_packages ]]; }
kernels=$(while read -r c package _ version _; do
    if is_kernel "$c" "$package"; then echo "$version"; fi
done < "$work/chosen" | sort -u)
kept=''
for _ in $(seq "$keep_kernels"); do
    top=$({ grep -vxF -f <(printf '%s\n' "$kept") <<< "$kernels" || true; } | newest)
    [ -z "$top" ] || kept+="$top"$'\n'
done
while read -r c package arch version path; do
    if is_kernel "$c" "$package" && ! grep -qxF -- "$version" <<< "$kept"; then
        echo "rebuild: dropping $package $version ($arch) from $c, older than the newest $keep_kernels kernels"
        continue
    fi
    reprepro --silent -b "$work/repo" --export=silent-never -C "$c" includedeb "$suite" "$path"
done < "$work/chosen"
reprepro --silent -b "$work/repo" export

# The earlier generations' by-hash files: those state/by-hash lists, and those
# of the live Release, as "MTIME PATH [INDEX]", where PATH is under
# dists/$suite and INDEX names the file the live Release lists. apt-ftparchive
# keeps the newest by mtime, so a file state/by-hash lists keeps its exact time
# there; the Release Date, whole seconds, is only for a site without that list,
# since two quick publishes would tie on it.
public=$work/repo/public/dists/$suite
: > "$work/by-hash"
if [ -e "$dist/Release" ]; then
    fresh state/by-hash "$work/by-hash" || : > "$work/by-hash"
    date=$(date -d "$(sed -n 's/^Date: //p' "$dist/Release")" +%s)
    awk -v d="$date" '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f && $3 ~ "/" && $3 !~ "/Release$" {
        dir = $3; sub("/[^/]*$", "", dir); print d, dir "/by-hash/SHA256/" $1, $3
    }' "$dist/Release" >> "$work/by-hash"
fi
awk '!($2 in t) { t[$2] = $1 } $3 != "" { i[$2] = $3 } END { for (p in t) print t[p], p, i[p] }' "$work/by-hash" |
    sort -k2,2 | while read -r mtime path index; do
    [[ $mtime =~ ^[0-9]+(\.[0-9]+)?$ && $path =~ ^([a-z0-9-]+/)+by-hash/SHA256/([0-9a-f]{64})$ ]] ||
        fail "state/by-hash lists $mtime $path"
    sha=${path##*/} dest=$public/$path
    # A directory the archive no longer has keeps nothing.
    [ -d "$public/${path%/by-hash/*}" ] || continue
    mkdir -p "$(dirname "$dest")"
    if ! get "$live/dists/$suite/$path" "$dest"; then
        if [ -z "$index" ] || ! fresh "dists/$suite/$index" "$dest"; then
            echo "rebuild: $suite/$path is gone from the live site; not keeping it"
            rm -f "$dest"
            continue
        fi
    fi
    echo "$sha  $dest" | sha256sum -c --quiet - || fail "$suite/$path does not match its name"
    touch -d "@$mtime" "$dest"
done

# Release, by apt-ftparchive: SHA256 sums, Acquire-By-Hash, Valid-Until
# $valid_days days out, and by-hash copies of every index, keeping the newest
# $by_hash_keep generations in each directory.
rm -f "$public/Release"
release_options=()
for f in Origin Label Suite Codename Architectures Components Description; do
    release_options+=(-o "APT::FTPArchive::Release::$f=$(field "$f")")
done
(cd "$public" && apt-ftparchive "${release_options[@]}" -o APT::FTPArchive::DoByHash=true \
    -o APT::FTPArchive::Release::ValidTime=$((valid_days * 86400)) \
    -o APT::FTPArchive::By-Hash-Keep="$by_hash_keep" -o APT::FTPArchive::MD5=false \
    -o APT::FTPArchive::SHA1=false -o APT::FTPArchive::SHA512=false release . > "$work/Release")
mv "$work/Release" "$public/Release"
signers=()
for key in $signing_keys; do signers+=(--local-user "$key"); done
gpg --batch --yes --digest-algo SHA512 "${signers[@]}" --clearsign -o "$public/InRelease" "$public/Release"
gpg --batch --yes --digest-algo SHA512 "${signers[@]}" --armor --detach-sign -o "$public/Release.gpg" "$public/Release"

mkdir -p "$out"
cp -r "$work/repo/public/." "$out/"
cp "$conf/archive-key.asc" "$out/key.asc"
fingerprint=$(gpg --batch --with-colons --show-keys "$conf/archive-key.asc" | awk -F: '/^fpr/ { print $10; exit }')
sed "s/@FINGERPRINT@/$fingerprint/g" "$site_template/index.html" > "$out/index.html"

mkdir -p "$out/state"
reprepro -b "$work/repo" list "$suite" | awk '{ print $2 }' | sort -u | while read -r package; do
    awk -v p="$package" '$1 == p { print; exit }' "$work/claims"
done > "$out/state/owners"
for entry in "${processed[@]}"; do
    tr , '\n' <<< "${entry#*=}" | sed "s/^/${entry%%=*} /" >> "$work/processed"
done
awk '!seen[$0]++' "$work/processed" | tail -n 2000 > "$out/state/processed"
(cd "$public" && find . -path '*/by-hash/SHA256/*' -type f -printf '%T@ %P\n' | sort -k2) > "$out/state/by-hash"

"$here/check-site.sh" "$out" "$work/keyring.gpg"
echo "== $suite"
reprepro -b "$work/repo" list "$suite" | sed 's/^/   /'
