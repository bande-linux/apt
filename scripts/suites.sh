# shellcheck shell=bash
# Sourced by the scripts. conf/suites lists the archive's suites, one Debian
# codename per line. Every package built for a suite carries ~debNN, NN being
# that Debian release's version number in distro-info-data's debian.csv.
debian_csv=${DEBIAN_CSV:-/usr/share/distro-info/debian.csv}

# suite_number SUITE: its Debian version number.
suite_number() {
    local n
    n=$(awk -F, -v c="$1" '$3 == c { print $1; exit }' "$debian_csv")
    [[ $n =~ ^[0-9]+$ ]] || { echo "$debian_csv gives $1 no Debian version number" >&2; return 1; }
    echo "$n"
}

# suite_list CONF: the suites CONF/suites lists, checked, one per line.
suite_list() {
    local suite listed=''
    [ -f "$1/suites" ] || { echo "$1/suites is missing" >&2; return 1; }
    while read -r suite; do
        [[ $suite =~ ^[a-z]+$ ]] || { echo "$1/suites lists \"$suite\", not a codename" >&2; return 1; }
        [[ " $listed " != *" $suite "* ]] || { echo "$1/suites lists $suite twice" >&2; return 1; }
        suite_number "$suite" > /dev/null || return 1
        listed+=" $suite"
        echo "$suite"
    done < "$1/suites"
    [ -n "$listed" ] || { echo "$1/suites lists no suite" >&2; return 1; }
}

# release_part SUITE VERSION: VERSION without SUITE's ~debNN, which stands
# right after the release and before any +l10n stamp; as it is without one.
release_part() {
    local n
    n=$(suite_number "$1") || return 1
    if [[ $2 =~ ^(.+)~deb$n(\+l10n[0-9.]+)?$ ]]; then
        echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    else
        echo "$2"
    fi
}
