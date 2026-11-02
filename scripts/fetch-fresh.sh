#!/bin/bash
# Usage: fetch-fresh.sh SITE PATH OUT
# Fetches SITE/PATH into OUT past the GitHub Pages CDN and prints the HTTP status.
# Pages serves every file with max-age=600, and its CDN caches each file on its
# own and ignores the query string, so "?nonce" still answers from the cache.
# It keys on the literal path, though, which the origin decodes: a random set of
# PATH's letters is percent-encoded, a path the CDN has not seen. SITE is left
# alone: Pages routes a project site (/apt) before it decodes. A
# response with an Age above 0 came from the cache anyway: it is tried again
# with another path, and fails after five.
set -euo pipefail

base=${1%/} path=/${2#/} out=$3
url=$base$path
headers=$(mktemp)
trap 'rm -f "$headers"' EXIT
for attempt in 1 2 3 4 5; do
    fresh=$path
    while [ "$fresh" = "$path" ]; do
        fresh=''
        for ((i = 0; i < ${#path}; i++)); do
            c=${path:i:1}
            if [[ $c == [A-Za-z] ]] && ((SRANDOM % 2)); then printf -v c '%%%02X' "'$c"; fi
            fresh+=$c
        done
    done
    code=$(curl -sS --retry 3 -D "$headers" -o "$out" -w '%{http_code}' "$base$fresh") ||
        { echo "fetch-fresh: cannot fetch $url" >&2; exit 1; }
    age=$(tr -d '\r' < "$headers" | awk -F': *' 'tolower($1) == "age" { a = $2 } END { print a + 0 }')
    if [ "$age" -eq 0 ]; then
        echo "$code"
        exit 0
    fi
done
echo "fetch-fresh: $url came from the CDN cache $attempt times (Age: $age)" >&2
exit 1
