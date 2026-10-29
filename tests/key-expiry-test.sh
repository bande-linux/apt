#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

expiry() { "$root/scripts/check-key-expiry.sh" "$@"; }

(make_conf "$scratch/long" 2y) > /dev/null 2>&1
check "a subkey for two years passes" expiry "$scratch/long"
(make_conf "$scratch/short" 30d) > /dev/null 2>&1
refuses "a subkey expiring in 30 days fails" "within 120 days" expiry "$scratch/short"
check "the warning window is adjustable" expiry "$scratch/short" 7
(export GNUPGHOME=$scratch/short/gnupg
 primary=$(cat "$scratch/short/signing-keys")
 gpg --batch --quiet --passphrase '' --quick-add-key "$primary" ed25519 sign 2y
 gpg --armor --export "$primary" > "$scratch/short/archive-key.asc") > /dev/null 2>&1
check "a new subkey before expiry passes again" expiry "$scratch/short"
echo 0000000000000000000000000000000000000000 > "$scratch/long/signing-keys"
refuses "an unknown key fails" "not in archive-key.asc" expiry "$scratch/long"
: > "$scratch/long/signing-keys"
refuses "an empty key list fails" "lists no key" expiry "$scratch/long"

finish
