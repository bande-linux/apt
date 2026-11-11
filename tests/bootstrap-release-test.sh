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

# The repository packages as build-repository-packages.sh lays them out.
REPOSITORY_VERSION=1.1 "$root/scripts/build-repository-packages.sh" "$scratch/debs" > /dev/null
check "a new version gets a release" release "$scratch/debs"
check "it is marked latest" grep -q -- "--latest" "$GH_LOG"
check "it is tagged apt-source-1.1" grep -q "release create apt-source-1.1 " "$GH_LOG"
check "it carries versioned and version-less packages, the source named by its suite" sh -c "grep -o '[^ /]*\.deb' '$GH_LOG' | sort | tr '\n' ' ' | grep -qx 'bande-apt-source-forky.deb bande-apt-source_1.1~deb14_all.deb bande-archive-keyring.deb bande-archive-keyring_1.1_all.deb '"
touch "$GH_EXISTING/apt-source-1.1"
check "an existing release is left alone" release "$scratch/debs"
check "nothing is created for it" sh -c "! grep -q 'release create' '$GH_LOG'"
two=$scratch/two
mkdir -p "$two" && cp "$root/conf/archive-key.asc" "$two/" && printf 'forky\nduke\n' > "$two/suites"
REPOSITORY_VERSION=1.2 "$root/scripts/build-repository-packages.sh" "$scratch/debs-two" "$two" > /dev/null
check "two suites get one release" release "$scratch/debs-two"
check "with one keyring and a source per suite" sh -c "grep -o '[^ /]*\.deb' '$GH_LOG' | sort | tr '\n' ' ' | grep -qx 'bande-apt-source-duke.deb bande-apt-source-forky.deb bande-apt-source_1.2~deb14_all.deb bande-apt-source_1.2~deb15_all.deb bande-archive-keyring.deb bande-archive-keyring_1.2_all.deb '"
cp -r "$scratch/debs" "$scratch/mixed"
REPOSITORY_VERSION=1.0 "$root/scripts/build-repository-packages.sh" "$scratch/old" > /dev/null
cp "$scratch/old/forky/bande-apt-source_1.0~deb14_all.deb" "$scratch/mixed/forky/"
refuses "packages of different versions are refused" "bande-apt-source is 1.0~deb14, the keyring is 1.1" release "$scratch/mixed"
rm "$scratch/mixed/forky/bande-archive-keyring_1.1_all.deb"
refuses "a missing keyring is refused" "expected a bande-archive-keyring" release "$scratch/mixed"

finish
