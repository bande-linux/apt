#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
shellcheck -x scripts/*.sh tests/*.sh packaging/*.postinst packaging/*.postrm
status=0
for t in tests/*-test.sh; do
    echo "== $t"
    "$t" || status=1
done
exit "$status"
