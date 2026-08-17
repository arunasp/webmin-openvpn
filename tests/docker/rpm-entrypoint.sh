#!/bin/bash
# Build the rpm, install it, and check the result on the distribution it
# targets.
#
# The package is only half of what this stage is for. The other half is the
# easy-rsa layout: Red Hat installs the script into a versioned subdirectory
# with major symlinks beside it, and until this ran, that path through
# find_easyrsa was covered by a fixture built to match the code. A fixture
# agreeing with the code proves they agree with each other.
#
# If /out is mounted, the finished rpm is copied there and given to the uid in
# TARGET_UID, so the file on the host belongs to whoever ran the build rather
# than to root.
set -euo pipefail

here=/src/tests
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

version=$(cat /src/VERSION)
build=${BUILD_NUMBER:-0}
release="$version.$build"

echo "== build"
mkdir -p /root/rpmbuild/SOURCES
install -m 0755 /src/tools/vpn-client /src/tools/vpn-server \
        /src/tools/upnp-port-forward /src/tools/vpn-extip \
        /root/rpmbuild/SOURCES/
rpmbuild -bb --define "version $release" \
         /src/packaging/rpm/openvpn-server-tools.spec > /tmp/rpmbuild.log 2>&1 || {
    tail -20 /tmp/rpmbuild.log
    fail "rpmbuild succeeds" "see the log above"
    report
    exit 1
}
rpm=$(find /root/rpmbuild/RPMS -name '*.rpm' | head -1)
[ -n "$rpm" ] || { fail "an rpm was produced" "none found"; report; exit 1; }
pass "rpmbuild produced $(basename "$rpm")"

echo
echo "== what it declares"
requires=$(rpm -qp --requires "$rpm" 2>/dev/null | tr '\n' ' ')
assert_contains "it requires openvpn" "$requires" "openvpn"
assert_contains "and easy-rsa" "$requires" "easy-rsa"
assert_eq "the version is the one the build stamped" "$release" \
    "$(rpm -qp --queryformat '%{VERSION}' "$rpm" 2>/dev/null)"

echo
echo "== install"
rpm -i "$rpm"
for t in vpn-client vpn-server upnp-port-forward vpn-extip; do
    if [ -x "/usr/sbin/$t" ]; then
        pass "$t is installed and executable"
    else
        fail "$t is installed and executable" "not at /usr/sbin/$t"
    fi
done

echo
echo "== the Red Hat easy-rsa layout, from the package rather than a fixture"
find /usr/share/easy-rsa -maxdepth 1 -mindepth 1 2>/dev/null | sed 's/^/   /'
found=$(bash -c '
    source <(sed -n "/^abs_path/,/^}/p;/^find_easyrsa/,/^}/p" /usr/sbin/vpn-server)
    EASYRSA_BIN=; EASYRSA_DIR=/nonexistent
    EASYRSA_SEARCH_PATH=/usr/share/easy-rsa:/usr/local/share/easy-rsa
    find_easyrsa')
if [ -n "$found" ] && [ -x "$found" ]; then
    pass "find_easyrsa resolves the packaged easy-rsa ($found)"
else
    fail "find_easyrsa resolves the packaged easy-rsa" "got '$found'"
fi
# What matters is that the resolved path is usable, not where it sits.
if "$found" --version 2>&1 | grep -qiE 'version|EasyRSA'; then
    pass "and the script it found runs"
else
    fail "and the script it found runs" "$("$found" --version 2>&1 | head -2 | tr '\n' ' ')"
fi

echo
echo "== the tools run on this distribution"
# Capture first, then match. Both tools exit non-zero when they print usage,
# and under pipefail a pipeline whose first command failed reports failure
# however well the grep went - which reported these as broken while the
# output being matched was right there in the failure detail.
out=$(vpn-server nosuchcommand 2>&1 || true)
assert_contains "vpn-server runs" "$out" "usage: vpn-server"
out=$(vpn-client nosuchcommand 2>&1 || true)
assert_contains "vpn-client runs" "$out" "usage: vpn-client"

# A host with the tools and no server yet is a normal state: the package
# installs before init runs. It should say so, not fail inside awk.
out=$(vpn-server status 2>&1 || true)
assert_contains "status explains a missing configuration" "$out" \
    "no server configuration at"
assert_not_contains "without an awk error" "$out" "awk:"

echo
echo "== removal"
rpm -e openvpn-server-tools
if [ -e /usr/sbin/vpn-client ]; then
    fail "removing the package takes the tools with it" "vpn-client is still there"
else
    pass "removing the package takes the tools with it"
fi

if [ -d /out ]; then
    cp "$rpm" /out/
    if [ -n "${TARGET_UID:-}" ]; then
        chown "${TARGET_UID}:${TARGET_GID:-$TARGET_UID}" "/out/$(basename "$rpm")"
    fi
    echo
    echo "   $(basename "$rpm") copied to the output directory"
fi

report
