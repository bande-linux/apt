#!/bin/bash
# Usage: check-site.sh SITE KEYRING
# Fails unless every index is signed by KEYRING, every listed file exists with
# its checksum, every pool file is listed, and the site fits GitHub Pages.
set -euo pipefail

site=$1 keyring=$2
max_total=$((800 * 1024 * 1024))
warn_total=$((600 * 1024 * 1024))
max_file=$((95 * 1024 * 1024))
fail() { echo "check-site: $*" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: > "$work/listed"

for inrelease in "$site"/dists/*/InRelease; do
    dist=$(dirname "$inrelease")
    gpgv --quiet --keyring "$keyring" --output "$work/Release" "$inrelease" 2>/dev/null ||
        fail "$inrelease is not signed by the archive key"
    awk '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f { print $1, $3 }' "$work/Release" |
        while read -r sha path; do
            [ -e "$dist/$path" ] || fail "$dist/$path is listed in Release but missing"
            echo "$sha  $dist/$path" | sha256sum -c --quiet - || fail "$dist/$path does not match Release"
        done
    for packages in "$dist"/main/binary-*/Packages; do
        awk -v RS= '{
            for (i = 1; i <= NF; i++) { if ($i == "Filename:") f = $(i + 1); if ($i == "SHA256:") s = $(i + 1) }
            print s, f
        }' "$packages" >> "$work/listed"
    done
done

sort -u "$work/listed" | while read -r sha filename; do
    [ -e "$site/$filename" ] || fail "$filename is listed but missing"
    echo "$sha  $site/$filename" | sha256sum -c --quiet - || fail "$filename does not match its index"
done
awk '{ print $2 }' "$work/listed" | sort -u > "$work/names"
(cd "$site" && find pool -type f 2>/dev/null | sort) > "$work/pool"
unlisted=$(comm -13 "$work/names" "$work/pool")
[ -z "$unlisted" ] || fail "pool files not listed in any index: $unlisted"

large=$(find "$site" -type f -size +"$max_file"c)
[ -z "$large" ] || fail "files over 95 MB: $large"
total=$(du -sb "$site" | cut -f1)
[ "$total" -le "$max_total" ] || fail "site is $((total / 1024 / 1024)) MB, over 800 MB"
[ "$total" -le "$warn_total" ] || echo "check-site: warning: site is $((total / 1024 / 1024)) MB, over 600 MB" >&2
echo "check-site: $((total / 1024 / 1024)) MB, $(wc -l < "$work/names") packages, signatures and checksums good"
