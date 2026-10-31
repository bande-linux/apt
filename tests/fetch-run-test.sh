#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

sha=788731fba292303f508c4dddda080bafd65aba29
other=1111111111111111111111111111111111111111
desktop_version=0.1.0
kernel_version=7.2.12-1+bande1
kernel_abi=7.2.12-apple-arm64-16k
export GH_TOKEN=test FETCH_RUN_POLL=1

# Run 7 of a source repository, served as the GitHub API. Settings, all
# optional: event, ref, status, conclusion, compare, workflow, tagged (the
# commit tag v0.1.0 points at; v0.1.1 is annotated and points at the run's
# commit), named (the kernel's bande-version-NAMED artifact; empty: none). The
# run is the push of v0.1.0 for the desktop and a schedule on main
# for the kernel. Packages are
# made with the functions below into $d/art/ARCH, one artifact per directory.
desktop_debs() {
    local d=$1 version=${2:-$desktop_version} arch
    for arch in amd64 arm64; do
        make_deb "$d/art/$arch" bande-compositor "$version" $arch
        make_deb "$d/art/$arch" xdg-desktop-portal-bande "$version" $arch
    done
    make_deb "$d/art/all" bande-desktop "$version" all
    make_deb "$d/art/all" bande-apt-source 1.0 all
    make_deb "$d/art/all" bande-archive-keyring 1.0 all
}
kernel_debs() {
    local d=$1 version=${2:-$kernel_version}
    make_deb "$d/art/arm64" "linux-image-$kernel_abi" "$version" arm64
    make_deb "$d/art/arm64" linux-image-apple-arm64-16k "$version" arm64
    make_deb "$d/art/arm64" bande-os-apple "$version" arm64
}
apps_version=0.1.0+git20261101.3.788731f
apps_debs() {
    local d=$1 app=$2 version=${3:-$apps_version} arch
    for arch in amd64 arm64; do make_deb "$d/art/$arch" "bande-$app" "$version" $arch; done
}
api() {
    local d=$1 repo=bande-linux/$2 base id=20 arch workflow=${workflow:-} event=${event:-} ref=${ref:-}
    base=$d/repos/$repo
    case $2 in
        desktop) : "${workflow:=release.yml}" "${event:=push}" "${ref:=v0.1.0}" ;;
        apps) : "${workflow:=build.yml}" "${event:=push}" "${ref:=main}" ;;
        *) : "${workflow:=follow-debian.yml}" "${event:=schedule}" "${ref:=main}" ;;
    esac
    mkdir -p "$base/actions/runs/7" "$base/actions/artifacts" "$base/compare" "$base/git/ref/tags" "$base/git/tags" \
        "$base/contents" "$d/repos/bande-linux/desktop/contents"
    tr " " "\n" <<< "${app_dirs:-weather clock}" | jq -R '{name: ., type: "dir"}' | jq -s '. + [{name: "README.md", type: "file"}]' \
        > "$base/contents/apps"
    printf '%s\n' bande-desktop bande-apt-source bande-greeter | jq -R '{name: ., type: "dir"}' | jq -s . \
        > "$d/repos/bande-linux/desktop/contents/packaging"
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
        jq --arg n "bande-debs-$(basename "$arch")" --argjson i "$id" '.artifacts += [{id: $i, name: $n}]' \
            "$base/actions/runs/7/artifacts" > "$d/artifacts" && mv "$d/artifacts" "$base/actions/runs/7/artifacts"
    done
    if [ "$2" = kernel ] && [ -n "${named-$kernel_version}" ]; then
        jq --arg n "bande-version-${named-$kernel_version}" '.artifacts += [{id: 99, name: $n}]' \
            "$base/actions/runs/7/artifacts" > "$d/artifacts" && mv "$d/artifacts" "$base/actions/runs/7/artifacts"
    fi
    export GITHUB_API_URL
    GITHUB_API_URL=$(serve "$d")
}

case_dir() { mktemp -d -p "$scratch"; }
fetch() { "$root/scripts/fetch-run.sh" "$1" 7 "$2"; }

d=$(case_dir); desktop_debs "$d"; api "$d" desktop
check "a green desktop tag run feeds main" sh -c "'$root/scripts/fetch-run.sh' desktop 7 '$d/out' | grep -qx component=main"
check "it brings both architectures" test -e "$d/out/bande-compositor_${desktop_version}_amd64.deb" -a \
    -e "$d/out/bande-compositor_${desktop_version}_arm64.deb"
check "it brings the architecture-independent packages" test -e "$d/out/bande-desktop_${desktop_version}_all.deb"
check "repository packages keep their own version" test -e "$d/out/bande-apt-source_1.0_all.deb"
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
(sleep 2; jq '.status = "completed" | .conclusion = "success"' "$d/repos/bande-linux/desktop/actions/runs/7/index.html" \
    > "$d/run" && mv "$d/run" "$d/repos/bande-linux/desktop/actions/runs/7/index.html") &
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
d=$(case_dir); kernel_debs "$d" 7.2.12-1; named=7.2.12-1 api "$d" kernel
refuses "a kernel without the +bande suffix is refused" "not <debian-version>+bandeN" fetch kernel "$d/out"
d=$(case_dir); kernel_debs "$d" 7.2.12-1+bande2; api "$d" kernel
refuses "kernel packages of another version than named are refused" "the run publishes 7.2.12-1+bande1" fetch kernel "$d/out"
d=$(case_dir); kernel_debs "$d"; named='' api "$d" kernel
refuses "a kernel run without its version artifact is refused" "names 0 versions" fetch kernel "$d/out"
d=$(case_dir); desktop_debs "$d"; make_deb "$d/art/arm64" libc6 9.9 arm64; api "$d" desktop
refuses "a package outside the archive's names is refused" "desktop does not publish" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; rm -r "$d/art/amd64"; api "$d" desktop
refuses "a missing architecture is refused" "no single bande-debs-amd64" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; rm "$d/art/amd64/xdg-desktop-portal-bande_"*; api "$d" desktop
refuses "an incomplete architecture is refused" "incomplete architecture" fetch desktop "$d/out"
d=$(case_dir); desktop_debs "$d"; mv "$d/art/amd64/xdg-desktop-portal-bande_"* "$d/art/arm64/"; api "$d" desktop
refuses "a package in another architecture's artifact is refused" "bande-debs-arm64 holds xdg-desktop-portal-bande for amd64" \
    fetch desktop "$d/out"

d=$(case_dir); apps_debs "$d" weather; api "$d" apps
check "an apps run with one app feeds main" sh -c "'$root/scripts/fetch-run.sh' apps 7 '$d/out' | grep -qx component=main"
check "it brings the app for amd64 and arm64" test -e "$d/out/bande-weather_${apps_version}_amd64.deb" -a \
    -e "$d/out/bande-weather_${apps_version}_arm64.deb"
d=$(case_dir); apps_debs "$d" weather; apps_debs "$d" clock 0.2.0+git20261101.5.788731f; event=workflow_dispatch api "$d" apps
check "a dispatched run with two apps of their own versions is taken" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" desktop; app_dirs=desktop api "$d" apps
refuses "an app named like the desktop is refused" "bande-desktop is the desktop's" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" greeter; app_dirs=greeter api "$d" apps
refuses "an app named like a desktop package directory is refused" "bande-greeter is the desktop's" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" portal-bande; make_deb "$d/art/amd64" xdg-desktop-portal-bande "$apps_version" amd64; app_dirs=portal-bande api "$d" apps
refuses "a desktop name outside bande-* is refused" "xdg-desktop-portal-bande, which apps does not publish" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" radio; api "$d" apps
refuses "a package without an apps/ directory is refused" "bande-radio, which apps does not publish" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" weather; apps_debs "$d" clock; rm "$d/art/amd64/bande-clock_"*; api "$d" apps
refuses "an app missing one architecture is refused" "incomplete architecture" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" weather; rm -r "$d/art/amd64"; api "$d" apps
refuses "an apps run without amd64 is refused" "no single bande-debs-amd64" fetch apps "$d/out"
d=$(case_dir); make_deb "$d/art/amd64" bande-weather "$apps_version" amd64
make_deb "$d/art/arm64" bande-weather 0.1.0+git20261101.4.aaaaaaa arm64; api "$d" apps
refuses "an app of two versions is refused" "different versions per architecture: bande-weather" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" weather 0.1.0; api "$d" apps
refuses "an app version without +git is refused" "not <cargo>+gitDATE.COUNT.SHA" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" template; ref=ci-test app_dirs=template api "$d" apps
refuses "a branch run of apps is refused" "the apps publishes main" fetch apps "$d/out"
d=$(case_dir); apps_debs "$d" weather; event=schedule api "$d" apps
refuses "a scheduled apps run is refused" "started by schedule" fetch apps "$d/out"

merged=$(case_dir)/out
d=$(case_dir); apps_debs "$d" weather 0.1.0+git20261101.4.aaaaaaa; apps_debs "$d" clock; api "$d" apps
check "a newer run merges" fetch apps "$merged"
d=$(case_dir); apps_debs "$d" weather; api "$d" apps
check "an older run merges" fetch apps "$merged"
check "the newer weather is kept" test -e "$merged/bande-weather_0.1.0+git20261101.4.aaaaaaa_arm64.deb"
check "the older weather is not added" test ! -e "$merged/bande-weather_${apps_version}_arm64.deb"
check "clock from the first run stays" test -e "$merged/bande-clock_${apps_version}_amd64.deb"
d=$(case_dir); apps_debs "$d" weather 0.1.0+git20261102.5.bbbbbbb; api "$d" apps
check "a still newer run merges" fetch apps "$merged"
check "it replaces the weather" sh -c "ls '$merged' | grep bande-weather | tr '\n' ' ' | grep -qx 'bande-weather_0.1.0+git20261102.5.bbbbbbb_amd64.deb bande-weather_0.1.0+git20261102.5.bbbbbbb_arm64.deb '"
d=$(case_dir); apps_debs "$d" weather 0.1.0+git20261103.6.ccccccc; apps_debs "$d" radio; api "$d" apps
refuses "a refused run adds nothing" "apps does not publish" fetch apps "$merged"
check "nothing of it reached the merge" sh -c "! ls '$merged' | grep -q 'ccccccc\|radio'"

finish
