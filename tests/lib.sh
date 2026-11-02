#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'xargs -r kill < "$scratch/servers" 2>/dev/null || true; rm -rf "$scratch"' EXIT
: > "$scratch/servers"
failures=0

check() {
    local label=$1
    shift
    if "$@" > "$scratch/last.log" 2>&1; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        sed 's/^/     /' "$scratch/last.log"
        failures=$((failures + 1))
    fi
}

refuses() {
    local label=$1 expect=$2
    shift 2
    if "$@" > "$scratch/last.log" 2>&1; then
        echo "FAIL $label (accepted)"
        failures=$((failures + 1))
    elif grep -q -- "$expect" "$scratch/last.log"; then
        echo "ok   $label"
    else
        echo "FAIL $label (refused for another reason)"
        sed 's/^/     /' "$scratch/last.log"
        failures=$((failures + 1))
    fi
}

finish() {
    if [ "$failures" -gt 0 ]; then
        echo "$failures failed"
        exit 1
    fi
    echo "all passed"
}

make_conf() {
    local conf=$1 expiry=${2:-2y} primary
    export GNUPGHOME=$conf/gnupg
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    cp "$root"/conf/{options,distributions} "$conf/"
    gpg --batch --quiet --passphrase '' --quick-generate-key 'Bande test archive key' ed25519 cert never
    primary=$(gpg --with-colons --list-keys | awk -F: '/^fpr/ { print $10; exit }')
    gpg --batch --quiet --passphrase '' --quick-add-key "$primary" ed25519 sign "$expiry"
    echo "$primary" > "$conf/signing-keys"
    gpg --armor --export "$primary" > "$conf/archive-key.asc"
    gpg --batch --quiet --dearmor < "$conf/archive-key.asc" > "$conf/keyring.gpg"
}

add_archive_key() {
    local conf=$1 primary
    gpg --batch --quiet --passphrase '' --quick-generate-key "Bande test archive key $RANDOM" ed25519 cert never
    primary=$(gpg --with-colons --list-keys | awk -F: '/^fpr/ { f = $10 } END { print f }')
    gpg --batch --quiet --passphrase '' --quick-add-key "$primary" ed25519 sign 2y
    echo "$primary" >> "$conf/signing-keys"
    gpg --armor --export "$primary" > "$conf/new-key.asc"
    mapfile -t keys < "$conf/signing-keys"
    gpg --armor --export "${keys[@]}" > "$conf/archive-key.asc"
    gpg --batch --quiet --dearmor < "$conf/archive-key.asc" > "$conf/keyring.gpg"
}

make_deb() {
    local dir=$1 package=$2 version=$3 arch=$4 extra=${5:-} tree
    tree=$(mktemp -d -p "$scratch")
    mkdir -p "$tree/DEBIAN" "$tree/usr/share/doc/$package"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Test <test@example.org>\nSection: misc\nPriority: optional\n%bDescription: test package\n' \
        "$package" "$version" "$arch" "${recommends:+Recommends: $recommends\n}" > "$tree/DEBIAN/control"
    printf '%s %s %s\n' "$package" "$version" "$extra" > "$tree/usr/share/doc/$package/stamp"
    mkdir -p "$dir"
    dpkg-deb --root-owner-group -b "$tree" "$dir/${package}_${version}_${arch}.deb" > /dev/null
}

serve() {
    local dir=$1 port
    port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    python3 -m http.server --bind 127.0.0.1 --directory "$dir" "$port" > /dev/null 2>&1 &
    echo $! >> "$scratch/servers"
    [ -d "$dir" ] || { echo "serve: $dir does not exist" >&2; return 1; }
    for _ in $(seq 100); do
        curl -fs -o /dev/null "http://127.0.0.1:$port/" && break
        sleep 0.1
    done
    echo "http://127.0.0.1:$port"
}

# set_valid_until SITE CONF [DATE]: rewrites the Valid-Until of SITE's Release to
# DATE (date -d syntax), or drops it without DATE, and signs it again with CONF's
# keys, as a publish would have.
set_valid_until() {
    local dist=$1/dists/rolling conf=$2 signers=()
    sed -i '/^Valid-Until: /d' "$dist/Release"
    if [ $# -gt 2 ]; then
        sed -i "/^Date: /a Valid-Until: $(LC_ALL=C date -u -d "$3" '+%a, %d %b %Y %H:%M:%S UTC')" "$dist/Release"
    fi
    while read -r key; do signers+=(--local-user "$key"); done < "$conf/signing-keys"
    gpg --batch --yes --digest-algo SHA512 "${signers[@]}" --clearsign -o "$dist/InRelease" "$dist/Release"
    gpg --batch --yes --digest-algo SHA512 "${signers[@]}" --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"
}
