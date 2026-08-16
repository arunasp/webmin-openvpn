#!/bin/bash
# Install the built package into a real Webmin and exercise the module through
# HTTP: the client list, the download page, the download itself, and the
# refusals.
#
# Every other stage stops at the boundary of Webmin. perl -cw proves the CGIs
# compile, apicheck proves the functions they call exist, and the compile-time
# stub in tests/stubs deliberately implements nothing - so none of them can
# tell whether a page renders. Running the module by hand for the first time
# found a malformed JSON that broke the server panel whenever nobody was
# connected; this stage exists so the next one of those is found by CI.
#
# It needs Webmin installed and root. It does NOT touch the system
# configuration: /etc/webmin is copied, the copy is edited, and miniserv is
# started against the copy on a spare port. The module itself is installed
# into the shared module directory, because that is where Webmin loads
# modules from - run this in a container, not on a server you care about.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
module=${MODULE:-openvpn-server}
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

WEBMIN_ROOT=${WEBMIN_ROOT:-/usr/share/webmin}
WEBMIN_ETC=${WEBMIN_ETC:-/etc/webmin}
PORT=${PORT:-$(( 20000 + (RANDOM % 500) ))}
PASSWORD=e2e-$$-$RANDOM

if [ ! -f "$WEBMIN_ROOT/miniserv.pl" ]; then
    fail "Webmin is installed" "$WEBMIN_ROOT/miniserv.pl not found"
    report
    exit 1
fi
[ "$(id -u)" -eq 0 ] || { fail "running as root" "Webmin needs it"; report; exit 1; }

package=$(find "$repo/build" -name "$module-*.wbm.gz" 2>/dev/null | head -1)
[ -n "$package" ] || { fail "a built package exists" "run make build first"; report; exit 1; }

tmp=$(mktemp -d)
miniserv_pid=
cleanup() {
    [ -n "$miniserv_pid" ] && kill "$miniserv_pid" 2>/dev/null
    sleep 1
    rm -rf "$tmp"
}
trap cleanup EXIT

echo "== install the package the way Webmin would"
tar -xzf "$package" -C "$WEBMIN_ROOT"
if [ -d "$WEBMIN_ROOT/$module" ]; then
    pass "the module unpacked into the module directory"
else
    fail "the module unpacked into the module directory" "$WEBMIN_ROOT/$module missing"
fi

# Webmin's own installer copies the module's defaults into its configuration
# directory and grants the module to the installing user. A tar extraction
# does neither, which presents as "user root is not allowed to use" - so this
# does both, exactly as install_webmin_module does.
cp -a "$WEBMIN_ETC" "$tmp/etc"
mkdir -p "$tmp/etc/$module"
cp "$WEBMIN_ROOT/$module/config" "$tmp/etc/$module/config"
# The grant has to happen whether or not a root: line already exists. A
# fresh install may have none, and a sed that matches nothing leaves every
# page answering "user root is not allowed to use" - which is what the first
# CI run of this stage did.
acl=$tmp/etc/webmin.acl
if [ -f "$acl" ] && grep -q "^root:" "$acl"; then
    sed -i "s|^root:.*|& $module|" "$acl"
else
    echo "root: $module" >> "$acl"
fi
if grep -q "^root:.*$module" "$acl"; then
    pass "the module is granted to root"
else
    fail "the module is granted to root" "$(grep "^root:" "$acl" | cut -c1-120)"
fi

# Session authentication would need a login round trip; this asks for HTTP
# authentication instead, on a copy of the configuration.
# Its own port, its own pidfile and its own logs: miniserv refuses to start
# when the pidfile of the system instance is present, and a test must not
# adopt or overwrite the logs of a running one.
sed -i 's/^session=1/session=0/; s/^port=.*/port='"$PORT"'/; s/^listen=.*/listen='"$PORT"'/' \
    "$tmp/etc/miniserv.conf"
sed -i '/^pidfile=/d; /^logfile=/d; /^errorlog=/d' "$tmp/etc/miniserv.conf"
{
    echo "pidfile=$tmp/miniserv.pid"
    echo "logfile=$tmp/miniserv.log"
    echo "errorlog=$tmp/miniserv.error"
} >> "$tmp/etc/miniserv.conf"
"$WEBMIN_ROOT/changepass.pl" "$tmp/etc" root "$PASSWORD" >/dev/null 2>&1 ||
    { fail "set a test password" "changepass.pl failed"; report; exit 1; }

setsid "$WEBMIN_ROOT/miniserv.pl" "$tmp/etc/miniserv.conf" \
    </dev/null >"$tmp/miniserv.out" 2>&1 &
sleep 5
miniserv_pid=$(pgrep -f "miniserv.pl $tmp/etc/miniserv.conf" | head -1)

base="https://127.0.0.1:$PORT/$module"
fetch() {
    # Webmin rejects a request carrying no referer as a possible cross-site
    # attack, so one is always sent.
    curl -sk -u "root:$PASSWORD" -e "$base/" "$@"
}

if fetch -o "$tmp/index.html" -w '%{http_code}' "$base/" 2>/dev/null | grep -q '^200$'; then
    pass "the module index answers"
else
    fail "the module index answers" "$(tail -3 "$tmp/miniserv.out" 2>/dev/null | tr '\n' ' ')"
    report
    exit 1
fi

echo
echo "== the client list"
index=$(cat "$tmp/index.html")
if ! printf "%s" "$index" | grep -q "VPN clients"; then
    echo "---- what the page actually said ----"
    printf "%s" "$index" | sed -e "s/<[^>]*>/ /g" -e "s/  */ /g" |
        grep -viE "^ *$" | tail -5
    echo "---- webmin.acl root line ----"
    grep "^root:" "$acl" | cut -c1-200
    echo "-------------------------------------"
fi
assert_contains "the page is the module, not an error" "$index" "VPN clients"
assert_not_contains "no access denial" "$index" "not allowed to use"
assert_not_contains "no tool failure" "$index" "could not parse"

# Whatever clients exist on this host should be listed; at least one must be,
# or the rest of the stage is testing an empty page.
first=$(vpn-client list --json 2>/dev/null |
        python3 -c 'import json,sys
d = json.load(sys.stdin)
print(d["clients"][0]["name"] if d["clients"] else "")' 2>/dev/null)
if [ -n "$first" ]; then
    pass "there is a client to exercise ($first)"
    assert_contains "it appears in the list" "$index" "$first"
else
    fail "there is a client to exercise" "no clients on this host"
    report
    exit 1
fi

echo
echo "== the download page"
fetch -o "$tmp/page.html" "$base/download.cgi?name=$first"
page=$(cat "$tmp/page.html")
assert_contains "it names the format" "$page" "Unified OpenVPN profile"
assert_contains "it warns about the private key" "$page" "private key"
assert_contains "it tells Windows users what to install" "$page" "OpenVPN GUI"
assert_contains "and links the community installer" "$page" "openvpn.net/community-downloads"
assert_contains "it covers iOS" "$page" "OpenVPN Connect"
assert_contains "and links the App Store" "$page" "apps.apple.com"
assert_contains "it covers Android" "$page" "play.google.com"

echo
echo "== the download itself"
fetch -D "$tmp/hdr.txt" -o "$tmp/profile.ovpn" "$base/download.cgi?name=$first&file=1"
headers=$(cat "$tmp/hdr.txt")
assert_contains "served as an attachment" "$headers" "attachment; filename=\"$first.ovpn\""
assert_contains "as plain text" "$headers" "text/plain"
for block in ca cert key tls-crypt; do
    assert_file_contains "the profile inlines <$block>" "$tmp/profile.ovpn" "<$block>"
done
assert_file_contains "and names a remote" "$tmp/profile.ovpn" "^remote "

echo
echo "== refusals"
for bad in '../../../etc/passwd' 'no-such-client' 'bad name'; do
    fetch -o "$tmp/bad.html" "$base/download.cgi?name=$(printf '%s' "$bad" | sed 's/ /%20/g')"
    body=$(cat "$tmp/bad.html")
    if printf '%s' "$body" | grep -q 'BEGIN CERTIFICATE'; then
        fail "refused: $bad" "it returned key material"
    else
        pass "refused: $bad"
    fi
done

report
