#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

conf=$scratch/conf
make_conf "$conf"
export GH_TOKEN=test

# A live archive serving desktop 0.1.0, kernel 7.2.12-1+bande1, bande-weather
# 0.1.0 and repository packages 1.0, which has refused apps run 60.
for p in bande-desktop bande-compositor; do make_deb "$scratch/desktop" $p 0.1.0 all; done
make_deb "$scratch/kernel" linux-image-7.2.12-apple-arm64-16k 7.2.12-1+bande1 arm64
make_deb "$scratch/kernel" bande-os-apple 7.2.12-1+bande1 arm64
for a in amd64 arm64; do make_deb "$scratch/apps" bande-weather 0.1.0 $a; done
REPOSITORY_VERSION=1.0 "$root/scripts/build-repository-packages.sh" "$scratch/apt" > /dev/null
empty=$(mktemp -d -p "$scratch")
"$root/scripts/rebuild.sh" --conf "$conf" --live "$(serve "$empty")" \
    --add desktop:main="$scratch/desktop" --add kernel:apple="$scratch/kernel" --processed apps=60 \
    --add-each apt:main="$scratch/apt" --add-each apps:main="$scratch/apps" \
    --out "$scratch/site" > /dev/null
live=$(serve "$scratch/site")

# api DIR: the GitHub API of both repositories. $desktop_runs lists the
# desktop's release runs as ID:TAG:CONCLUSION, newest first; $kernel_runs the
# kernel's runs with a version artifact as ID:VERSION:CONCLUSION[:EVENT];
# $apps_runs the apps' build runs as ID:CONCLUSION:EVENT:TAG.
api() {
    local d=$1 run id tag version conclusion event base=$1/repos/bande-linux
    mkdir -p "$base/desktop/actions/workflows/release.yml" "$base/kernel/actions/runs" "$base/kernel/actions/artifacts"
    echo '{"workflow_runs": []}' > "$base/desktop/actions/workflows/release.yml/runs"
    for run in ${desktop_runs:-}; do
        IFS=: read -r id tag conclusion <<< "$run"
        jq --argjson i "$id" --arg t "$tag" --arg c "$conclusion" \
            '.workflow_runs += [{id: $i, event: "push", head_branch: $t, conclusion: $c}]' \
            "$base/desktop/actions/workflows/release.yml/runs" > "$d/x" && mv "$d/x" "$base/desktop/actions/workflows/release.yml/runs"
    done
    echo '{"artifacts": [{"name": "bande-debs-arm64", "expired": false, "workflow_run": {"id": 1}}]}' \
        > "$base/kernel/actions/artifacts/index.html"
    for run in ${kernel_runs:-}; do
        IFS=: read -r id version conclusion event <<< "$run"
        jq --argjson i "$id" --arg n "bande-version-$version" '.artifacts += [{name: $n, expired: false, workflow_run: {id: $i}}]' \
            "$base/kernel/actions/artifacts/index.html" > "$d/x" && mv "$d/x" "$base/kernel/actions/artifacts/index.html"
        jq -n --arg c "$conclusion" --arg e "${event:-schedule}" \
            '{path: ".github/workflows/follow-debian.yml", head_branch: "main", event: $e, conclusion: $c}' \
            > "$base/kernel/actions/runs/$id"
    done
    mkdir -p "$base/apps/actions/workflows/build.yml"
    echo '{"workflow_runs": []}' > "$base/apps/actions/workflows/build.yml/runs"
    for run in ${apps_runs:-}; do
        IFS=: read -r id conclusion event tag <<< "$run"
        jq --argjson i "$id" --arg c "$conclusion" --arg e "$event" --arg t "$tag" \
            '.workflow_runs += [{id: $i, event: $e, head_branch: $t, conclusion: $c}]' \
            "$base/apps/actions/workflows/build.yml/runs" > "$d/x" && mv "$d/x" "$base/apps/actions/workflows/build.yml/runs"
    done
    export GITHUB_API_URL
    GITHUB_API_URL=$(serve "$d")
}
find_runs() { "$root/scripts/find-runs.sh" "${2:-$live}" "$conf" > "$1"; }

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" kernel_runs="40:7.2.12-1+bande1:success" api "$d"
check "nothing new finds nothing" find_runs "$d/out"
check "it prints no run" test ! -s "$d/out"
check "it says what is published" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q 'desktop 0.1.0 (run 30) is published'"

d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success 30:v0.1.0:success" kernel_runs="40:7.2.12-1+bande1:success" api "$d"
check "a new desktop tag is found" find_runs "$d/out"
check "only the desktop run is printed" diff <(echo "desktop 31") "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" kernel_runs="41:7.2.14-1+bande1:success 40:7.2.12-1+bande1:success" api "$d"
check "a new kernel is found" find_runs "$d/out"
check "only the kernel run is printed" diff <(echo "kernel 41") "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" kernel_runs="41:7.2.14-1+bande1:success:workflow_dispatch" api "$d"
check "both new are found" find_runs "$d/out"
check "both runs are printed" diff <(printf 'desktop 31\nkernel 41\n') "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="32:v0.3.0:failure 30:v0.1.0:success" kernel_runs="42:7.3.1-1+bande1:failure 40:7.2.12-1+bande1:success" api "$d"
check "red runs are ignored" find_runs "$d/out"
check "nothing is printed for them" test ! -s "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="33:main:success 34:v0.4:success 30:v0.1.0:success" kernel_runs="43:7.3.1-1+bande1:success:push" api "$d"
check "runs that are not releases are ignored" find_runs "$d/out"
check "nothing is printed for those" test ! -s "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success 35:v0.0.9:success" api "$d"
check "an older tag is not published again" find_runs "$d/out"
check "the highest tag decides" test ! -s "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" kernel_runs="40:7.2.12-1+bande1:success" api "$d"
check "an empty site takes every release" find_runs "$d/out" "$(serve "$empty")"
check "both are printed for it" diff <(printf 'desktop 30\nkernel 40\n') "$d/out"

d=$(mktemp -d -p "$scratch"); apps_runs="61:success:push:weather-v0.2.0 59:success:push:weather-v0.1.0" api "$d"
check "a new app tag is found" find_runs "$d/out"
check "only that apps run is printed" diff <(echo "apps 61") "$d/out"
d=$(mktemp -d -p "$scratch"); apps_runs="59:success:push:weather-v0.1.0" api "$d"
check "a published app tag is not found again" find_runs "$d/out"
check "nothing is printed for it" test ! -s "$d/out"
check "it says it is published" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q 'bande-weather 0.1.0 (run 59) is published'"
d=$(mktemp -d -p "$scratch")
apps_runs="63:success:push:weather-v0.2.0 62:success:push:weather-v0.10.0 64:success:push:clock-face-v0.1.0" api "$d"
check "the highest tag of each app is found" find_runs "$d/out"
check "one run per app, sorted by app" diff <(printf 'apps 64\napps 62\n') "$d/out"
d=$(mktemp -d -p "$scratch"); apps_runs="60:success:push:weather-v0.4.0 65:success:push:weather-v0.3.0" api "$d"
check "a refused apps run is not taken again" find_runs "$d/out"
check "nor is an older tag taken in its place" test ! -s "$d/out"
check "it says it was refused" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q 'run 60) was refused before'"
d=$(mktemp -d -p "$scratch")
apps_runs="66:failure:push:clock-v0.1.0 67:success:workflow_dispatch:clock-v0.1.0 68:success:push:main 69:success:push:ci-test 70:success:push:clock-v0.1 71:success:schedule:clock-v0.2.0" api "$d"
check "red, dispatched, branch, malformed and scheduled apps runs are ignored" find_runs "$d/out"
check "none of them is printed" test ! -s "$d/out"
d=$(mktemp -d -p "$scratch"); apps_runs="72:success:push:weather-v0.1.0" api "$d"
check "an empty site takes every app" find_runs "$d/out" "$(serve "$empty")"
check "the app is printed for it" diff <(echo "apps 72") "$d/out"

d=$(mktemp -d -p "$scratch"); mkdir -p "$d/repos/bande-linux/kernel/actions/runs" "$d/repos/bande-linux/kernel/actions/artifacts"
jq -n '{artifacts: [{name: "bande-version-7.2.14-1+bande1", expired: false, workflow_run: {id: 41}}]}' \
    > "$d/repos/bande-linux/kernel/actions/artifacts/index.html"
jq -n '{path: ".github/workflows/follow-debian.yml", head_branch: "main", event: "schedule", conclusion: "success"}' \
    > "$d/repos/bande-linux/kernel/actions/runs/41"
GITHUB_API_URL=$(serve "$d")
check "repositories that do not exist yet are nothing new" find_runs "$d/out"
check "the others are still found" diff <(echo "kernel 41") "$d/out"
check "it says which are missing" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q \"the desktop's release runs not found (HTTP 404)\""
broken=$(mktemp -d -p "$scratch")
cat > "$broken/server.py" <<'PY2'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(500); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY2
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$broken/server.py" "$port" &
echo $! >> "$scratch/servers"
sleep 0.5
GITHUB_API_URL=http://127.0.0.1:$port
refuses "a server error still fails" "answered HTTP 500" find_runs "$d/out"
GITHUB_API_URL=http://127.0.0.1:1
refuses "a network error still fails" "cannot list" find_runs "$d/out"

d=$(mktemp -d -p "$scratch"); api "$d"
check "new repository packages are found" sh -c "APT_VERSION=1.1 '$root/scripts/find-runs.sh' '$live' '$conf' | grep -qx 'apt 1.1'"
check "published repository packages are not" sh -c "APT_VERSION=1.0 '$root/scripts/find-runs.sh' '$live' '$conf' > '$d/out' && test ! -s '$d/out'"
check "an empty site takes the repository packages" sh -c "APT_VERSION=1.0 '$root/scripts/find-runs.sh' '$(serve "$empty")' '$conf' | grep -qx 'apt 1.0'"

# Right after a publish the Pages CDN can serve the new InRelease beside the
# old Packages.xz; the index is read by hash, so it still resolves.
for p in bande-desktop bande-compositor; do make_deb "$scratch/desktop-2" $p 0.2.0 all; done
"$root/scripts/rebuild.sh" --conf "$conf" --live "$live" --add desktop:main="$scratch/desktop-2" --out "$scratch/site-2" > /dev/null
stale=$(mktemp -d -p "$scratch")
cp -r "$scratch/site-2/." "$stale/"
cp "$scratch/site/dists/rolling/main/binary-arm64/Packages.xz" "$stale/dists/rolling/main/binary-arm64/Packages.xz"
d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" api "$d"
check "a stale Packages.xz beside a new InRelease resolves by hash" find_runs "$d/out" "$(serve "$stale")"
check "the published desktop is not found again" test ! -s "$d/out"

# Valid-Until: under 7 days left, or none, starts a re-sign; a past one is
# refused, since it may be an old InRelease replayed.
d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" api "$d"
check "a fresh InRelease is no re-sign" find_runs "$d/out"
check "nothing is printed for it" test ! -s "$d/out"
check "it says how long it is valid" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q 'rolling/InRelease is valid until'"
expiring=$(mktemp -d -p "$scratch")
cp -r "$scratch/site/." "$expiring/"
set_valid_until "$expiring" "$conf" '+3 days'
check "an InRelease expiring within 7 days starts a re-sign" find_runs "$d/out" "$(serve "$expiring")"
check "a re-sign is printed for it" grep -qx 'resign [0-9T:-]*Z' "$d/out"
check "and only that" test "$(wc -l < "$d/out")" = 1
set_valid_until "$expiring" "$conf"
check "an InRelease without Valid-Until is due a re-sign" find_runs "$d/out" "$(serve "$expiring")"
check "it is printed as resign none" diff <(echo "resign none") "$d/out"
set_valid_until "$expiring" "$conf" '-1 hour'
d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" api "$d"
check "an expired InRelease starts a re-sign" find_runs "$d/out" "$(serve "$expiring")"
check "and no new run is taken from it" diff <(echo "resign expired") "$d/out"
check "it warns" sh -c "'$root/scripts/find-runs.sh' '$(serve "$expiring")' '$conf' 2>&1 | grep -q 'warning: rolling/InRelease expired at'"

cached=$(mktemp -d -p "$scratch")
cat > "$cached/server.py" <<'PY2'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Age", "120"); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY2
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$cached/server.py" "$port" &
echo $! >> "$scratch/servers"
sleep 0.5
refuses "an InRelease the CDN answers from its cache is refused" "came from the CDN cache" find_runs "$d/out" "http://127.0.0.1:$port"

forged=$scratch/forged
(make_conf "$forged" && "$root/scripts/rebuild.sh" --conf "$forged" --live "$(serve "$empty")" \
    --add desktop:main="$scratch/desktop" --out "$scratch/forged-site") > /dev/null 2>&1
refuses "a forged archive is refused" "not signed by the archive key" find_runs "$d/out" "$(serve "$scratch/forged-site")"

finish
