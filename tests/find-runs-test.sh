#!/bin/bash
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

conf=$scratch/conf
make_conf "$conf"
export GH_TOKEN=test

# A live archive serving desktop 0.1.0, browser 153.6.0esr-1+bande1 and
# repository packages 1.0.
for p in bande-desktop bande-compositor; do make_deb "$scratch/desktop/forky" $p 0.1.0 all; done
for a in amd64 arm64; do make_deb "$scratch/web/forky" bande-browser 153.6.0esr-1+bande1 $a; done
REPOSITORY_VERSION=1.0 "$root/scripts/build-repository-packages.sh" "$scratch/apt" > /dev/null
empty=$(mktemp -d -p "$scratch")
"$root/scripts/rebuild.sh" --conf "$conf" --live "$(serve "$empty")" \
    --add desktop:main="$scratch/desktop" --add web:main="$scratch/web" \
    --add-each apt:main="$scratch/apt" \
    --out "$scratch/site" > /dev/null
live=$(serve "$scratch/site")

# api DIR: the GitHub API of the source repositories. $desktop_runs lists the
# desktop's release runs as ID:TAG:CONCLUSION, newest first; $web_runs web's
# runs with a version artifact as ID:VERSION:CONCLUSION[:EVENT].
api() {
    local d=$1 run id tag version conclusion event base=$1/repos/bande-linux
    mkdir -p "$base/desktop/actions/workflows/release.yml" "$base/web/actions/runs" "$base/web/actions/artifacts"
    echo '{"workflow_runs": []}' > "$base/desktop/actions/workflows/release.yml/runs"
    for run in ${desktop_runs:-}; do
        IFS=: read -r id tag conclusion <<< "$run"
        jq --argjson i "$id" --arg t "$tag" --arg c "$conclusion" \
            '.workflow_runs += [{id: $i, event: "push", head_branch: $t, conclusion: $c}]' \
            "$base/desktop/actions/workflows/release.yml/runs" > "$d/x" && mv "$d/x" "$base/desktop/actions/workflows/release.yml/runs"
    done
    echo '{"artifacts": [{"name": "bande-debs-forky-arm64", "expired": false, "workflow_run": {"id": 1}}]}' \
        > "$base/web/actions/artifacts/index.html"
    for run in ${web_runs:-}; do
        IFS=: read -r id version conclusion event <<< "$run"
        jq --argjson i "$id" --arg n "bande-version-$version" '.artifacts += [{name: $n, expired: false, workflow_run: {id: $i}}]' \
            "$base/web/actions/artifacts/index.html" > "$d/x" && mv "$d/x" "$base/web/actions/artifacts/index.html"
        jq -n --arg c "$conclusion" --arg e "${event:-schedule}" \
            '{path: ".github/workflows/follow-debian.yml", head_branch: "main", event: $e, conclusion: $c}' \
            > "$base/web/actions/runs/$id"
    done
    mkdir -p "$base/desktop/actions/workflows/dict.yml"
    echo '{"workflow_runs": []}' > "$base/desktop/actions/workflows/dict.yml/runs"
    for run in ${dict_runs:-}; do
        IFS=: read -r id tag conclusion <<< "$run"
        jq --argjson i "$id" --arg t "$tag" --arg c "$conclusion" \
            '.workflow_runs += [{id: $i, event: "push", head_branch: $t, conclusion: $c}]' \
            "$base/desktop/actions/workflows/dict.yml/runs" > "$d/x" && mv "$d/x" "$base/desktop/actions/workflows/dict.yml/runs"
    done
    local l10n=$base/desktop/actions/workflows/l10n.yml/runs status
    mkdir -p "$(dirname "$l10n")" "$base/desktop/git/matching-refs/tags" "$base/desktop/compare"
    echo '{"workflow_runs": []}' > "$l10n"
    for run in ${l10n_runs:-}; do
        IFS=: read -r id tag conclusion <<< "$run"
        jq --argjson i "$id" --arg t "$tag" --arg c "$conclusion" \
            '.workflow_runs += [{id: $i, event: "push", head_branch: $t, head_sha: "cafe", conclusion: $c}]' \
            "$l10n" > "$d/x" && mv "$d/x" "$l10n"
    done
    tr ' ' '\n' <<< "${desktop_tags:-} l10n-20261101" | grep . | jq -R '{ref: ("refs/tags/" + .)}' | jq -s . \
        > "$base/desktop/git/matching-refs/tags/index.html"
    for tag in ${desktop_tags:-}; do
        if [[ " ${on_history:-} " == *" $tag "* ]]; then status=ahead; else status=behind; fi
        jq -n --arg s "$status" '{status: $s}' > "$base/desktop/compare/$tag...cafe"
    done
    export GITHUB_API_URL
    GITHUB_API_URL=$(serve "$d")
}
find_runs() { "$root/scripts/find-runs.sh" "${2:-$live}" "$conf" > "$1"; }

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" web_runs="40:153.6.0esr-1+bande1:success" api "$d"
check "nothing new finds nothing" find_runs "$d/out"
check "it prints no run" test ! -s "$d/out"
check "it says what is published" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q 'desktop 0.1.0 (run 30) is published'"

d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success 30:v0.1.0:success" web_runs="40:153.6.0esr-1+bande1:success" api "$d"
check "a new desktop tag is found" find_runs "$d/out"
check "only the desktop run is printed" diff <(echo "desktop 31") "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" web_runs="41:153.7.0esr-1+bande1:success 40:153.6.0esr-1+bande1:success" api "$d"
check "a new browser is found" find_runs "$d/out"
check "only the web run is printed" diff <(echo "web 41") "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" web_runs="41:153.7.0esr-1+bande1:success:workflow_dispatch" api "$d"
check "both new are found" find_runs "$d/out"
check "both runs are printed" diff <(printf 'desktop 31\nweb 41\n') "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="32:v0.3.0:failure 30:v0.1.0:success" web_runs="42:153.8.0esr-1+bande1:failure 40:153.6.0esr-1+bande1:success" api "$d"
check "red runs are ignored" find_runs "$d/out"
check "nothing is printed for them" test ! -s "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="33:main:success 34:v0.4:success 30:v0.1.0:success" web_runs="43:153.8.0esr-1+bande1:success:push" api "$d"
check "runs that are not releases are ignored" find_runs "$d/out"
check "nothing is printed for those" test ! -s "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success 35:v0.0.9:success" api "$d"
check "an older tag is not published again" find_runs "$d/out"
check "the highest tag decides" test ! -s "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" web_runs="40:153.6.0esr-1+bande1:success" api "$d"
check "an empty site takes every release" find_runs "$d/out" "$(serve "$empty")"
check "both are printed for it" diff <(printf 'desktop 30\nweb 40\n') "$d/out"

d=$(mktemp -d -p "$scratch"); dict_runs="81:dict-20261108:success 80:dict-20261101:success 82:dict-2026:success 83:dict-20261201:failure" api "$d"
check "the highest green dictionary tag is found" find_runs "$d/out"
check "only that dictionary run is printed" diff <(echo "dict 81") "$d/out"

d=$(mktemp -d -p "$scratch")
l10n_runs="90:l10n-20261108:success 91:l10n-20261107:success 92:l10n-2026:success 93:l10n-20261109:failure" \
    desktop_tags="v0.1.0" on_history="v0.1.0" api "$d"
check "the desktop's highest green language pack tag is found" find_runs "$d/out"
check "only that run is printed" diff <(echo "l10n 90") "$d/out"
d=$(mktemp -d -p "$scratch"); l10n_runs="90:l10n-20261108:success 94:l10n-20261108.1:success" desktop_tags="v0.1.0" api "$d"
check "a second tag of a day is newer" find_runs "$d/out"
check "and printed" diff <(echo "l10n 94") "$d/out"
d=$(mktemp -d -p "$scratch"); l10n_runs="90:l10n-20261108:success" desktop_tags="v0.1.0 v0.2.0" on_history="v0.1.0 v0.2.0" api "$d"
check "packs built on a release not published yet wait" find_runs "$d/out"
check "nothing is printed for them" test ! -s "$d/out"
check "it says what they wait for" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q 'l10n-20261108 of the desktop (run 90) wait for v0.2.0'"
d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" l10n_runs="90:l10n-20261108:success" desktop_tags="v0.1.0 v0.2.0" \
    on_history="v0.1.0 v0.2.0" api "$d"
check "they go with that release when it is published" find_runs "$d/out"
check "both are printed" diff <(printf 'desktop 31\nl10n 90\n') "$d/out"
d=$(mktemp -d -p "$scratch"); l10n_runs="90:l10n-20261108:success" desktop_tags="v0.1.0 v0.2.0" on_history="v0.1.0" api "$d"
check "a newer release after the packs' commit does not hold them" find_runs "$d/out"
check "they are printed" diff <(echo "l10n 90") "$d/out"
"$root/scripts/rebuild.sh" --conf "$conf" --live "$live" --processed l10n=90,77 --out "$scratch/site-l10n" > /dev/null
d=$(mktemp -d -p "$scratch"); l10n_runs="90:l10n-20261108:success" desktop_tags="v0.1.0" \
    on_history="v0.1.0" api "$d"
check "taken language pack runs are not taken again" find_runs "$d/out" "$(serve "$scratch/site-l10n")"
check "nothing is printed for them" test ! -s "$d/out"
d=$(mktemp -d -p "$scratch"); mkdir -p "$d/repos/bande-linux/web/actions/runs" "$d/repos/bande-linux/web/actions/artifacts"
jq -n '{artifacts: [{name: "bande-version-153.7.0esr-1+bande1", expired: false, workflow_run: {id: 41}}]}' \
    > "$d/repos/bande-linux/web/actions/artifacts/index.html"
jq -n '{path: ".github/workflows/follow-debian.yml", head_branch: "main", event: "schedule", conclusion: "success"}' \
    > "$d/repos/bande-linux/web/actions/runs/41"
GITHUB_API_URL=$(serve "$d")
check "repositories that do not exist yet are nothing new" find_runs "$d/out"
check "the others are still found" diff <(echo "web 41") "$d/out"
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

for p in bande-desktop bande-compositor; do make_deb "$scratch/desktop-2/forky" $p 0.2.0 all; done
"$root/scripts/rebuild.sh" --conf "$conf" --live "$live" --add desktop:main="$scratch/desktop-2" --out "$scratch/site-2" > /dev/null
stale=$(mktemp -d -p "$scratch")
cp -r "$scratch/site-2/." "$stale/"
cp "$scratch/site/dists/forky/main/binary-arm64/Packages.xz" "$stale/dists/forky/main/binary-arm64/Packages.xz"
d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" api "$d"
check "a stale Packages.xz beside a new InRelease resolves by hash" find_runs "$d/out" "$(serve "$stale")"
check "the published desktop is not found again" test ! -s "$d/out"

d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" api "$d"
check "a fresh InRelease is no re-sign" find_runs "$d/out"
check "nothing is printed for it" test ! -s "$d/out"
check "it says how long it is valid" sh -c "'$root/scripts/find-runs.sh' '$live' '$conf' 2>&1 | grep -q 'forky/InRelease is valid until'"
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
check "it warns" sh -c "'$root/scripts/find-runs.sh' '$(serve "$expiring")' '$conf' 2>&1 | grep -q 'warning: forky/InRelease expired at'"

# Suites: a live version is compared without its suite's ~debNN, and a new
# suite lacks the repository packages until they are published to it.
two=$scratch/two-conf
cp -r "$conf" "$two" && printf 'forky\nduke\n' > "$two/suites"
d=$(mktemp -d -p "$scratch"); desktop_runs="30:v0.1.0:success" api "$d"
check "a suite not served yet wants the repository packages" sh -c "APT_VERSION=1.0 '$root/scripts/find-runs.sh' '$live' '$two' > '$d/out'"
check "and only them, as the other suite has the desktop" diff <(echo "apt 1.0") "$d/out"
for p in bande-desktop bande-compositor; do make_deb "$scratch/desktop-3/forky" $p 0.2.0~deb14 all; done
"$root/scripts/rebuild.sh" --conf "$two" --live "$live" --add desktop:main="$scratch/desktop-3" --out "$scratch/site-3" > /dev/null
d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" api "$d"
check "a tag served with the suite suffix is published" sh -c "'$root/scripts/find-runs.sh' '$(serve "$scratch/site-3")' '$two' > '$d/out'"
check "nothing is printed for it" test ! -s "$d/out"
d=$(mktemp -d -p "$scratch"); desktop_runs="32:v0.2.1:success 31:v0.2.0:success" api "$d"
check "a newer tag is found over it" find_runs "$d/out" "$(serve "$scratch/site-3")"
check "and printed" diff <(echo "desktop 32") "$d/out"
expiring=$(mktemp -d -p "$scratch")
cp -r "$scratch/site-3/." "$expiring/"
suite=duke set_valid_until "$expiring" "$conf" '+2 days'
d=$(mktemp -d -p "$scratch"); desktop_runs="31:v0.2.0:success" api "$d"
check "one suite near its Valid-Until starts a re-sign" sh -c "'$root/scripts/find-runs.sh' '$(serve "$expiring")' '$two' > '$d/out'"
check "a re-sign is printed for it" grep -qx 'resign [0-9T:-]*Z' "$d/out"

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
