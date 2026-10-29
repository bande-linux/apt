#!/bin/bash
# Usage: rebuild.sh --live URL --channel stable|testing --debs DIR --out DIR
#                   [--conf DIR] [--cache DIR] [--initial]
# Rebuilds the whole archive from the live, signature-checked site plus the
# packages in DIR, signs it with the keys in conf/signing-keys (secret keys in
# $GNUPGHOME) and writes the site to --out.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
everywhere=" unbound-archive-keyring unbound-apt-source unbound-apt-source-testing "

conf=$here/../conf
site_template=$here/../site
live='' channel='' debs='' out='' cache='' initial=0
while [ $# -gt 0 ]; do
    case $1 in
        --live) live=${2%/}; shift 2 ;;
        --channel) channel=$2; shift 2 ;;
        --debs) debs=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --conf) conf=$2; shift 2 ;;
        --cache) cache=$2; shift 2 ;;
        --initial) initial=1; shift ;;
        *) echo "rebuild: unknown argument $1" >&2; exit 2 ;;
    esac
done
fail() { echo "rebuild: $*" >&2; exit 1; }
if [ -z "$live" ] || [ -z "$channel" ] || [ -z "$debs" ] || [ -z "$out" ]; then
    fail "--live, --channel, --debs and --out are required"
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

codenames=$(awk '{ print $2 }' "$conf/channels")
target=$(awk -v c="$channel" '$1 == c { print $2 }' "$conf/channels")
[ -n "$target" ] || fail "unknown channel $channel"

field() {
    awk -v c="$1" -v f="$2" '
        /^Codename:/ { cur = $2 }
        cur == c && index($0, f ": ") == 1 { sub("^" f ": ", ""); print; exit }
    ' "$conf/distributions"
}

get() {
    local code
    code=$(curl -sS --retry 3 -o "$2" -w '%{http_code}' "$1") || fail "cannot fetch $1"
    case $code in
        200) return 0 ;;
        404) return 1 ;;
        *) fail "$1 answered HTTP $code" ;;
    esac
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
for c in $codenames; do
    mkdir -p "$work/live/$c"
    if ! get "$live/dists/$c/InRelease" "$work/live/$c/InRelease"; then
        [ "$initial" = 1 ] || fail "$live/dists/$c/InRelease does not exist; pass --initial for the first publish"
        continue
    fi
    gpgv --quiet --keyring "$work/keyring.gpg" --output "$work/live/$c/Release" \
        "$work/live/$c/InRelease" 2>/dev/null || fail "$c/InRelease is not signed by the archive key"
    for arch in $(field "$c" Architectures); do
        index=main/binary-$arch/Packages.xz
        sha=$(release_sha256 "$work/live/$c/Release" "$index")
        [ -n "$sha" ] || fail "$c/Release does not list $index"
        get "$live/dists/$c/$index" "$work/live/$c/$arch.xz" || fail "$c/$index is listed but missing"
        echo "$sha  $work/live/$c/$arch.xz" | sha256sum -c --quiet - || fail "$c/$index does not match Release"
        xz -dc "$work/live/$c/$arch.xz" |
            awk -v RS= '{
                for (i = 1; i <= NF; i++) { if ($i == "Filename:") f = $(i + 1); if ($i == "SHA256:") s = $(i + 1) }
                print s, f
            }' > "$work/live/$c/$arch.files"
        while read -r sha filename; do
            pool_file "$sha" "$filename"
            echo "$c $(describe "$work/pool/$sha.deb") $work/pool/$sha.deb" >> "$work/rows"
        done < "$work/live/$c/$arch.files"
    done
done
sort -u -o "$work/rows" "$work/rows"

newest() {
    local best=
    while read -r version; do
        if [ -z "$best" ] || dpkg --compare-versions "$version" gt "$best"; then best=$version; fi
    done
    echo "$best"
}

shopt -s nullglob
new=("$debs"/*.deb)
[ ${#new[@]} -gt 0 ] || fail "no packages in $debs"
for deb in "${new[@]}"; do
    read -r package arch version < <(describe "$deb")
    sha=$(sha256sum "$deb" | cut -d' ' -f1)
    suites=$target
    [[ $everywhere == *" $package "* ]] && suites=$codenames
    for c in $suites; do
        same=$(awk -v c="$c" -v p="$package" -v a="$arch" -v v="$version" \
            '$1 == c && $2 == p && $3 == a && $4 == v { print $5 }' "$work/rows")
        if [ -n "$same" ]; then
            [ "$(sha256sum "$same" | cut -d' ' -f1)" = "$sha" ] ||
                fail "$package $version ($arch) is already in $c with different contents"
            continue
        fi
        top=$(awk -v c="$c" -v p="$package" -v a="$arch" '$1 == c && $2 == p && $3 == a { print $4 }' \
            "$work/rows" | newest)
        if [ -n "$top" ] && dpkg --compare-versions "$version" lt "$top"; then
            [[ $everywhere == *" $package "* ]] && continue
            fail "$package $version ($arch) is older than $top in $c"
        fi
        cp "$deb" "$work/pool/$sha.deb"
        echo "$c $package $arch $version $work/pool/$sha.deb" >> "$work/rows"
        echo "rebuild: adding $package $version ($arch) to $c"
    done
done

mkdir -p "$work/repo/conf"
sed "s/@SIGNING_KEYS@/$signing_keys/" "$conf/distributions" > "$work/repo/conf/distributions"
cp "$conf/options" "$work/repo/conf/options"
awk '{ print $1, $2, $3 }' "$work/rows" | sort -u > "$work/groups"
while read -r c package arch; do
    rows=$(awk -v c="$c" -v p="$package" -v a="$arch" '$1 == c && $2 == p && $3 == a' "$work/rows")
    top=$(awk '{ print $4 }' <<< "$rows" | newest)
    path=$(awk -v v="$top" '$4 == v { print $5; exit }' <<< "$rows")
    reprepro --silent -b "$work/repo" --export=silent-never -C main includedeb "$c" "$path"
done < "$work/groups"
reprepro --silent -b "$work/repo" export

mkdir -p "$out"
cp -r "$work/repo/public/." "$out/"
cp "$conf/archive-key.asc" "$out/key.asc"
fingerprint=$(gpg --batch --with-colons --show-keys "$conf/archive-key.asc" | awk -F: '/^fpr/ { print $10; exit }')
sed "s/@FINGERPRINT@/$fingerprint/g" "$site_template/index.html" > "$out/index.html"

"$here/check-site.sh" "$out" "$work/keyring.gpg"
for c in $codenames; do
    echo "== $c"
    reprepro -b "$work/repo" list "$c" | sed 's/^/   /'
done
