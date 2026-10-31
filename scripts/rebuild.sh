#!/bin/bash
# Usage: rebuild.sh --live URL --component main|apple --debs DIR --out DIR
#                   [--conf DIR] [--cache DIR] [--initial]
# Rebuilds the whole archive from the live, signature-checked site plus the
# packages in DIR, which go to --component, signs it with the keys in
# conf/signing-keys (secret keys in $GNUPGHOME) and writes the site to --out.
# Each package keeps its newest version only, and apple keeps the packages of
# its newest two kernel versions only.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# The keyring and source packages live in main and carry their own version.
repository_packages=" unbound-archive-keyring unbound-apt-source "
# Kernel packages carry the kernel version in their name, so each kernel stays
# until it is dropped; keep_kernels bounds how many fit within the Pages limit.
kernel_packages='linux-*-apple-*'
keep_kernels=2

conf=$here/../conf
site_template=$here/../site
live='' component='' debs='' out='' cache='' initial=0
while [ $# -gt 0 ]; do
    case $1 in
        --live) live=${2%/}; shift 2 ;;
        --component) component=$2; shift 2 ;;
        --debs) debs=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --conf) conf=$2; shift 2 ;;
        --cache) cache=$2; shift 2 ;;
        --initial) initial=1; shift ;;
        *) echo "rebuild: unknown argument $1" >&2; exit 2 ;;
    esac
done
fail() { echo "rebuild: $*" >&2; exit 1; }
if [ -z "$live" ] || [ -z "$component" ] || [ -z "$debs" ] || [ -z "$out" ]; then
    fail "--live, --component, --debs and --out are required"
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
[[ " $components " == *" $component "* ]] || fail "$suite has no component $component"

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
mkdir -p "$work/live/$suite"
dist=$work/live/$suite
if get "$live/dists/$suite/InRelease" "$dist/InRelease"; then
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
            get "$live/dists/$suite/$index" "$dist/$c-$arch.xz" || fail "$suite/$index is listed but missing"
            echo "$sha  $dist/$c-$arch.xz" | sha256sum -c --quiet - || fail "$suite/$index does not match Release"
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
else
    [ "$initial" = 1 ] || fail "$live/dists/$suite/InRelease does not exist; pass --initial for the first publish"
fi
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
: > "$work/new"
for deb in "${new[@]}"; do
    read -r package arch version < <(describe "$deb")
    if [[ $repository_packages == *" $package "* ]] && [ "$component" != main ]; then
        fail "$package belongs in main, not $component"
    fi
    echo "$package $arch $version $deb" >> "$work/new"
done

# One build: on each architecture, its own and the architecture-independent
# packages carry one version, the repository packages aside.
built=$(awk '$2 != "all" { print $2 }' "$work/new" | sort -u)
for arch in ${built:-all}; do
    versions=$(awk -v a="$arch" -v skip="$repository_packages" \
        '($2 == a || $2 == "all") && index(skip, " " $1 " ") == 0 { print $3 }' "$work/new" | sort -u)
    [ "$(wc -l <<< "$versions")" -le 1 ] ||
        fail "the $arch packages carry different versions: $(tr '\n' ' ' <<< "$versions")"
done

while read -r package arch version deb; do
    sha=$(sha256sum "$deb" | cut -d' ' -f1)
    c=$component
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
        fail "$package $version ($arch) is older than $top in $c"
    fi
    cp "$deb" "$work/pool/$sha.deb"
    echo "$c $package $arch $version $work/pool/$sha.deb" >> "$work/rows"
    echo "rebuild: adding $package $version ($arch) to $c"
done < "$work/new"

mkdir -p "$work/repo/conf"
sed "s/@SIGNING_KEYS@/$signing_keys/" "$conf/distributions" > "$work/repo/conf/distributions"
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

mkdir -p "$out"
cp -r "$work/repo/public/." "$out/"
cp "$conf/archive-key.asc" "$out/key.asc"
fingerprint=$(gpg --batch --with-colons --show-keys "$conf/archive-key.asc" | awk -F: '/^fpr/ { print $10; exit }')
sed "s/@FINGERPRINT@/$fingerprint/g" "$site_template/index.html" > "$out/index.html"

"$here/check-site.sh" "$out" "$work/keyring.gpg"
echo "== $suite"
reprepro -b "$work/repo" list "$suite" | sed 's/^/   /'
