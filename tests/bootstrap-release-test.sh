#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

bin=$scratch/bin
mkdir -p "$bin"
cat > "$bin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$GH_LOG"
[ "$1 $2" != "release view" ] || [ -e "$GH_EXISTING/$3" ]
GH
chmod +x "$bin/gh"
export PATH=$bin:$PATH GH_LOG=$scratch/gh.log GH_EXISTING=$scratch/existing
mkdir -p "$GH_EXISTING"
release() { : > "$GH_LOG"; "$root/scripts/bootstrap-release.sh" "$@"; }

for p in unbound-archive-keyring unbound-apt-source; do make_deb "$scratch/debs" $p 1.1 all; done
check "a new version gets a release" release "$scratch/debs"
check "it is marked latest" grep -q -- "--latest" "$GH_LOG"
check "it is tagged apt-source-1.1" grep -q "release create apt-source-1.1 " "$GH_LOG"
check "it carries versioned and version-less packages" sh -c "grep -o '[^ /]*\.deb' '$GH_LOG' | sort | tr '\n' ' ' | grep -qx 'unbound-apt-source.deb unbound-apt-source_1.1_all.deb unbound-archive-keyring.deb unbound-archive-keyring_1.1_all.deb '"
touch "$GH_EXISTING/apt-source-1.1"
check "an existing release is left alone" release "$scratch/debs"
check "nothing is created for it" sh -c "! grep -q 'release create' '$GH_LOG'"
make_deb "$scratch/mixed" unbound-archive-keyring 1.0 all
make_deb "$scratch/mixed" unbound-apt-source 1.1 all
refuses "packages of different versions are refused" "the others are" release "$scratch/mixed"
rm "$scratch/mixed/unbound-archive-keyring_1.0_all.deb"
refuses "a missing package is refused" "expected one unbound-archive-keyring" release "$scratch/mixed"

finish
