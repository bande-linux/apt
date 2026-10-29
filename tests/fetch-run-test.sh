#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

repo=unbound-linux/desktop
sha=788731fba292303f508c4dddda080bafd65aba29
other=1111111111111111111111111111111111111111
main_version=0.0.0+git20261029.35.788731f
export GH_TOKEN=test DESKTOP_REPO=$repo

api() {
    local dir=$1 ref=$2 event=$3 version=$4 failing=${5:-} compare=${6:-ahead} cargo=${7:-0.1.0} tagged=${8:-$sha}
    local base=$dir/repos/$repo debs=$dir/debs conclusion=success
    mkdir -p "$base/actions/runs/7" "$base/actions/artifacts/9" "$base/compare" "$base/git/ref/tags" "$base/git/tags" \
        "$base/contents" "$debs"
    jq -n --arg e "$event" --arg r "$ref" --arg s "$sha" --arg o "$repo" \
        '{event: $e, path: ".github/workflows/ci.yml", head_branch: $r, head_sha: $s, head_repository: {full_name: $o}}' \
        > "$base/actions/runs/7/index.html"
    [ -z "$failing" ] || conclusion=failure
    jq -n --arg c "$conclusion" '{jobs: [
        {name: "ci/lint", status: "completed", conclusion: "success"},
        {name: "ci/deb", status: "completed", conclusion: $c},
        {name: "ci/publish", status: "in_progress", conclusion: null}]}' > "$base/actions/runs/7/jobs"
    jq -n '{artifacts: [{id: 9, name: "unbound-debs-arm64"}, {id: 8, name: "screendumps"}]}' > "$base/actions/runs/7/artifacts"
    jq -n --arg s "$compare" '{status: $s}' > "$base/compare/$sha...main"
    jq -n --arg s "$tagged" '{object: {type: "commit", sha: $s}}' > "$base/git/ref/tags/v0.1.0"
    jq -n --arg s "$sha" '{object: {type: "tag", sha: "abcd"}}' > "$base/git/ref/tags/v0.1.1"
    jq -n --arg s "$sha" '{object: {type: "commit", sha: $s}}' > "$base/git/tags/abcd"
    printf '[workspace]\nmembers = ["crates/*"]\n\n[workspace.package]\nversion = "%s"\nedition = "2024"\n' "$cargo" |
        base64 -w0 | jq -R '{content: .}' > "$base/contents/Cargo.toml"
    make_deb "$debs" unbound-compositor "$version" arm64
    make_deb "$debs" unbound-apt-source 1.0 all
    tree=$(mktemp -d -p "$scratch")
    mkdir -p "$tree/DEBIAN"
    printf 'Package: unbound-desktop\nVersion: %s\nArchitecture: all\nMaintainer: T <t@example.org>\nSection: misc\nPriority: optional\nDepends: unbound-compositor (= %s), dbus-user-session\nDescription: test\n' \
        "$version" "$version" > "$tree/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$tree" "$debs/unbound-desktop_${version}_all.deb" > /dev/null
    (cd "$debs" && python3 -m zipfile -c "$base/actions/artifacts/9/zip" ./*.deb)
    export GITHUB_API_URL
    GITHUB_API_URL=$(serve "$dir")
}

case_dir() { mktemp -d -p "$scratch"; }
fetch() { "$root/scripts/fetch-run.sh" 7 "$@"; }

d=$(case_dir); api "$d" main push "$main_version"
check "a green main run feeds testing" sh -c "'$root/scripts/fetch-run.sh' 7 '$d/out' | grep -qx channel=testing"
check "its packages are downloaded" test -e "$d/out/unbound-compositor_${main_version}_arm64.deb"

d=$(case_dir); api "$d" feature push "$main_version"
refuses "a branch run is refused" "testing takes pushes to main" fetch "$d/out"
d=$(case_dir); api "$d" main push "$main_version" failing
refuses "a run with a failed job is refused" "did not succeed" fetch "$d/out"
d=$(case_dir); api "$d" main push "$main_version" "" diverged
refuses "a commit off main is refused" "is not on main" fetch "$d/out"
d=$(case_dir); api "$d" main push 0.0.0+git20261029.35.0000000
refuses "a version naming another commit is refused" "carries version" fetch "$d/out"
d=$(case_dir); api "$d" main push "$main_version"
make_deb "$d/extra" libc6 9.9 arm64
(cd "$d/extra" && python3 -m zipfile -c "$d/repos/$repo/actions/artifacts/9/zip" ./*.deb "$d"/debs/*.deb)
refuses "a package outside the archive's names is refused" "does not carry" fetch "$d/out"

d=$(case_dir); api "$d" main push "$main_version"
check "a tag promotes the main run to stable" sh -c "'$root/scripts/fetch-run.sh' 7 '$d/out' v0.1.0 | grep -qx channel=stable"
check "promoted packages carry the release version" test -e "$d/out/unbound-compositor_0.1.0_arm64.deb"
check "no package keeps the main version" sh -c "! ls '$d/out' | grep -q 'git20261029'"
check "exact dependencies follow the promotion" sh -c "dpkg-deb -f '$d/out/unbound-desktop_0.1.0_all.deb' Depends | grep -q 'unbound-compositor (= 0.1.0)'"
check "repository packages keep their own version" test -e "$d/out/unbound-apt-source_1.0_all.deb"
check "promotion keeps the installed files" sh -c "
    a=\$(mktemp -d); b=\$(mktemp -d)
    dpkg-deb -x '$d/debs/unbound-compositor_${main_version}_arm64.deb' \$a
    dpkg-deb -x '$d/out/unbound-compositor_0.1.0_arm64.deb' \$b
    diff -r \$a \$b"

d=$(case_dir); api "$d" main push "$main_version" "" ahead 0.1.1
check "an annotated tag is followed to its commit" fetch "$d/out" v0.1.1
d=$(case_dir); api "$d" main push "$main_version" "" ahead 0.1.0 "$other"
refuses "a tag on another commit is refused" "points at" fetch "$d/out" v0.1.0
d=$(case_dir); api "$d" main push "$main_version" "" ahead 0.2.0
refuses "a tag that disagrees with Cargo.toml is refused" "Cargo.toml at" fetch "$d/out" v0.1.0
d=$(case_dir); api "$d" main push "$main_version"
refuses "a tag that is not vX.Y.Z is refused" "not a vX.Y.Z tag" fetch "$d/out" v0.1
d=$(case_dir); api "$d" v0.1.0 workflow_dispatch 0.1.0
check "a rebuild on the tag feeds stable as built" sh -c "'$root/scripts/fetch-run.sh' 7 '$d/out' v0.1.0 | grep -qx version=0.1.0"
d=$(case_dir); api "$d" v0.1.0 workflow_dispatch 0.1.1
refuses "a rebuild on the tag with another version is refused" "built version" fetch "$d/out" v0.1.0

finish
