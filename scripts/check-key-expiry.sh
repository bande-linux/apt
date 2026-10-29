#!/bin/bash
# Usage: check-key-expiry.sh CONF_DIR [DAYS]
# Fails unless every primary key in CONF_DIR/signing-keys is in archive-key.asc
# and has a valid signing subkey that lasts at least DAYS more (default 120).
set -euo pipefail

conf=$1 days=${2:-120}
fail() { echo "check-key-expiry: $*" >&2; exit 1; }
limit=$(($(date +%s) + days * 86400))
listing=$(gpg --batch --with-colons --show-keys "$conf/archive-key.asc")

keys=$(grep -v '^\s*$' "$conf/signing-keys" || true)
[ -n "$keys" ] || fail "$conf/signing-keys lists no key"
for key in $keys; do
    subkeys=$(awk -F: -v k="$key" '
        /^pub/ { want = 1; cur = ""; next }
        /^fpr/ && want { cur = $10; want = 0; next }
        /^sub/ && cur == k { print $2 ":" $7 ":" $12 }
    ' <<< "$listing")
    awk -F: -v k="$key" '/^fpr/ && $10 == k { found = 1 } END { exit !found }' <<< "$listing" ||
        fail "$key is not in archive-key.asc"
    longest=-1
    while IFS=: read -r validity expires caps; do
        if [ -z "$caps" ] || [[ $validity == [re] || $caps != *s* ]]; then continue; fi
        [ -n "$expires" ] || { longest=0; break; }
        [ "$longest" = 0 ] || [ "$expires" -le "$longest" ] || longest=$expires
    done <<< "$subkeys"
    [ "$longest" != -1 ] || fail "$key has no valid signing subkey"
    if [ "$longest" != 0 ] && [ "$longest" -lt "$limit" ]; then
        fail "$key's signing subkeys expire on $(date -u -d "@$longest" +%F), within $days days"
    fi
    echo "check-key-expiry: $key can sign$([ "$longest" = 0 ] || echo " until $(date -u -d "@$longest" +%F)")"
done
