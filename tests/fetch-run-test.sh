#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

sha=788731fba292303f508c4dddda080bafd65aba29
other=1111111111111111111111111111111111111111
desktop_version=0.1.0
kernel_version=7.2.12-1+unbound1
kernel_abi=7.2.12-apple-arm64-16k
export GH_TOKEN=test FETCH_RUN_POLL=1

# Run 7 of a source repository, served as the GitHub API. Settings, all
# optional: event, ref, status, conclusion, compare, workflow, tagged (the
# commit tag v0.1.0 points at; v0.1.1 is annotated and points at the run's
# commit). The run is the push of v0.1.0 for the desktop and a schedule on main
# for the kernel. Packages are
# made with the functions below into $d/art/ARCH, one artifact per directory.
desktop_debs() {
    local d=$1 version=${2:-$desktop_version} arch
    for arch in amd64 arm64; do
        make_deb "$d/art/$arch" unbound-compositor "$version" $arch
        make_deb "$d/art/$arch" xdg-desktop-portal-unbound "$version" $arch
    done
    make_deb "$d/art/all" unbound-desktop "$version" all
    make_deb "$d/art/all" unbound-apt-source 1.0 all
    make_deb "$d/art/all" unbound-archive-keyring 1.0 all
}
kernel_debs() {
    local d=$1 version=${2:-$kernel_version}
    make_deb "$d/art/arm64" "linux-image-$kernel_abi" "$version" arm64
    make_deb "$d/art/arm64" linux-image-apple-arm64-16k "$version" arm64
    make_deb "$d/art/arm64" unbound-os-apple "$version" arm64
}
api() {
    local d=$1 repo=unbound-linux/$2 base id=20 arch workflow=${workflow:-} event=${event:-} ref=${ref:-}
    base=$d/repos/$repo
    case $2 in
        desktop) : "${workflow:=release.yml}" "${event:=push}" "${ref:=v0.1.0}" ;;
        *) : "${workflow:=follow-debian.yml}" "${event:=schedule}" "${ref:=main}" ;;
    esac
    mkdir -p "$base/actions/runs/7" "$base/actions/artifacts" "$base/compare" "$base/git/ref/tags" "$base/git/tags"
    jq -n --arg s "${tagged:-$sha}" '{object: {type: "commit", sha: $s}}' > "$base/git/ref/tags/v0.1.0"
    jq -n '{object: {type: "tag", sha: "abcd"}}' > "$base/git/ref/tags/v0.1.1"
    jq -n --arg s "$sha" '{object: {type: "commit", sha: $s}}' > "$base/git/tags/abcd"
    jq -n --arg e "$event" --arg r "$ref" --arg s "$sha" --arg o "$repo" --arg w "$workflow" \
        --arg st "${status:-completed}" --arg c "${conclusion:-success}" \
        '{event: $e, path: (".github/workflows/" + $w), head_branch: $r, head_sha: $s, head_repository: {full_name: $o},
          status: $st, conclusion: (if $st == "completed" then $c else null end)}' > "$base/actions/runs/7/index.html"
    jq -n --arg s "${compare:-ahead}" '{status: $s}' > "$base/compare/$sha...main"
    echo '{"artifacts": [{"id": 8, "name": "screendumps"}]}' > "$base/actions/runs/7/artifacts"
    for arch in "$d"/art/*; do
        id=$((id + 1))
        mkdir -p "$base/actions/artifacts/$id"
        (cd "$arch" && python3 -m zipfile -c "$base/actions/artifacts/$id/zip" ./*.deb)
        jq --arg n "unbound-debs-$(basename "$arch")" --argjson i "$id" '.artifacts += [{id: $i, name: $n}]' \
            "$base/actions/runs/7/artifacts" > "$d/artifacts" && mv "$d/artifacts" "$base/actions/runs/7/artifacts"
    done
    export GITHUB_API_URL
    GITHUB_API_URL=$(serve "$d")
}

case_dir() { mktemp -d -p "$scratch"; }
fetch() { "$root/scripts/fetch-run.sh" "$1" 7 "$2"; }

d=$(case_dir); desktop_debs "$d"; api "$d" desktop
check "a green desktop tag run feeds main" sh -c "'$root/scripts/fetch-run.sh' desktop 7 '$d/out' | grep -qx component=main"
check "it brings both architectures" test -e "$d/out/unbound-compositor_${desktop_version}_amd64.deb" -a \
    -e "$d/out/unbound-compositor_${desktop_version}_arm64.deb"
check "it brings the architecture-independent packages" test -e "$d/out/unbound-desktop_${desktop_version}_all.deb"
check "repository packages keep their own version" test -e "$d/out/unbound-apt-source_1.0_all.deb"
d=$(case_dir); kernel_debs "$d"; api "$d" kernel
check "a green kernel run feeds apple" sh -c "'$root/scripts/fetch-run.sh' kernel 7 '$d/out' | grep -qx component=apple"
check "it brings the kernel" test -e "$d/out/linux-image-${kernel_abi}_${kernel_version}_arm64.deb"
d=$(case_dir); kernel_debs "$d"; event=workflow_dispatch api "$d" kernel
check "a dispatched kernel run is taken" fetch kernel "$d/out"
d=$(case_dir); desktop_debs "$d" 0.1.1; ref=v0.1.1 api "$d" desktop
check "an annotated tag is followed to its commit" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; ref=refs/tags/v0.1.0 api "$d" desktop
check "a full tag ref is taken" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; status=in_progress api "$d" desktop
(sleep 2; jq '.status = "completed" | .conclusion = "success"' "$d/repos/unbound-linux/desktop/actions/runs/7/index.html" \
    > "$d/run" && mv "$d/run" "$d/repos/unbound-linux/desktop/actions/runs/7/index.html") &
check "a run still finishing is waited for" env FETCH_RUN_WAIT=20 "$root/scripts/fetch-run.sh" desktop 7 "$d/out"
wait

d=$(case_dir); desktop_debs "$d"; api "$d" desktop
refuses "an unknown repository is refused" "unknown repository" fetch images "$d/out"
d=$(case_dir); desktop_debs "$d"; workflow=ci.yml api "$d" desktop
refuses "another workflow is refused" "not .github/workflows/release.yml" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; api "$d" kernel
refuses "the desktop's packages are refused from the kernel" "kernel does not publish" fetch kernel "$d/out"
d=$(case_dir); desktop_debs "$d"; ref=main api "$d" desktop
refuses "a desktop push to main is refused" "publishes vX.Y.Z tags" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; ref=v0.1 api "$d" desktop
refuses "a tag that is not vX.Y.Z is refused" "publishes vX.Y.Z tags" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; ref=v0.2.0 api "$d" desktop
refuses "a tag that does not exist is refused" "tag v0.2.0 does not exist" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; tagged=$other api "$d" desktop
refuses "a tag on another commit is refused" "points at $other" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; event=workflow_dispatch api "$d" desktop
refuses "a dispatched desktop run is refused" "started by workflow_dispatch" fetch desktop "$d/out"
d=$(case_dir); kernel_debs "$d"; ref=feature api "$d" kernel
refuses "a kernel branch run is refused" "the kernel publishes main" fetch kernel "$d/out"
d=$(case_dir); kernel_debs "$d"; event=push api "$d" kernel
refuses "a kernel push run is refused" "started by push" fetch kernel "$d/out"
d=$(case_dir); kernel_debs "$d"; event=pull_request api "$d" kernel
refuses "a pull request run is refused" "started by pull_request" fetch kernel "$d/out"
d=$(case_dir); desktop_debs "$d"; conclusion=failure api "$d" desktop
refuses "a failed run is refused" "ended in failure" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; status=in_progress api "$d" desktop
refuses "a run that does not finish is refused" "still in_progress" env FETCH_RUN_WAIT=1 \
    "$root/scripts/fetch-run.sh" desktop 7 "$d/out"
d=$(case_dir); desktop_debs "$d"; compare=diverged api "$d" desktop
refuses "a commit off main is refused" "is not on main" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d" 0.1.1; api "$d" desktop
refuses "packages of another version than the tag are refused" "carries version 0.1.1" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d" 0.1.0+git20261029.35.788731f; api "$d" desktop
refuses "a main build's version under a tag is refused" "carries version" fetch desktop "$d/out"
d=$(case_dir); kernel_debs "$d" 7.2.12-1; api "$d" kernel
refuses "a kernel without the +unbound suffix is refused" "carries version" fetch kernel "$d/out"
d=$(case_dir); desktop_debs "$d"; make_deb "$d/art/arm64" libc6 9.9 arm64; api "$d" desktop
refuses "a package outside the archive's names is refused" "desktop does not publish" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; rm -r "$d/art/amd64"; api "$d" desktop
refuses "a missing architecture is refused" "no single unbound-debs-amd64" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; rm "$d/art/amd64/xdg-desktop-portal-unbound_"*; api "$d" desktop
refuses "an incomplete architecture is refused" "incomplete architecture" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; mv "$d/art/amd64/xdg-desktop-portal-unbound_"* "$d/art/arm64/"; api "$d" desktop
refuses "a package in another architecture's artifact is refused" "unbound-debs-arm64 holds xdg-desktop-portal-unbound for amd64" \
    fetch desktop "$d/out"

finish
