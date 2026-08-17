#!/bin/bash
# Install the built package into an installed Webmin and exercise the module through
# HTTP: the client list, the download page, the download itself, and the
# refusals.
#
# Every other stage stops at the boundary of Webmin. perl -cw proves the CGIs
# compile, apicheck proves the functions they call exist, and the compile-time
# stub in tests/stubs implements nothing at all - so none of them can
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
# If the source configuration already grants the module, the copy inherits
# that and the grant below is never exercised - which is how a
# broken grant survived every local run while failing in CI, where the
# install is always fresh. Say so rather than reporting a pass that covers
# less than it appears to.
if grep -q "^root:.*$module" "$WEBMIN_ETC/webmin.acl" 2>/dev/null; then
    echo "[note] $WEBMIN_ETC already grants $module, so this run does not"
    echo "       exercise the grant step. A fresh install does."
fi
# If the source configuration already grants the module, the copy inherits
# that and the grant below is never exercised - which is how a
# broken grant survived every local run while failing in CI, where the
# install is always fresh. Say so rather than reporting a pass that covers
# less than it appears to.
if grep -q "^root:.*$module" "$WEBMIN_ETC/webmin.acl" 2>/dev/null; then
    echo "[note] $WEBMIN_ETC already grants $module, so this run does not"
    echo "       exercise the grant step. A fresh install does."
fi
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

# miniserv.conf names the configuration directory the CGIs will read, in
# env_WEBMIN_CONFIG, and every other path in it is absolute too. Copying the
# directory is therefore not enough: without repointing those, miniserv runs
# from the copy while the module reads its ACL and configuration from the
# original, and the module answers "user root is not allowed to use" no matter
# what the copy says. Repoint them all at the copy.
# Repoint whatever directory the file itself names, not whatever WEBMIN_ETC
# happens to be: a configuration copied from elsewhere still carries the
# original absolute paths, and keying off WEBMIN_ETC would replace nothing.
old_etc=$(sed -n 's/^env_WEBMIN_CONFIG=//p' "$tmp/etc/miniserv.conf" | head -1)
[ -n "$old_etc" ] || old_etc=$WEBMIN_ETC
sed -i "s|$old_etc|$tmp/etc|g" "$tmp/etc/miniserv.conf"

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
echo "== where the tools came from"
# The package installs into /usr/sbin while the module configuration names
# /usr/local/sbin. If both existed the module would read the configured path
# and this would prove nothing, so check the configured one is absent: the
# page above rendered because the module resolved the path itself.
configured=$(sed -n 's/^vpn_client=//p' "$WEBMIN_ROOT/$module/config")
if [ -x "$configured" ]; then
    echo "[note] $configured exists, so resolution was not exercised"
else
    pass "the module resolved the tools away from the configured path"
    assert_eq "they came from the package" "/usr/sbin/vpn-client" \
        "$(command -v vpn-client)"
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
echo "== the server page"
fetch -o "$tmp/server.html" "$base/server.cgi"
srv=$(cat "$tmp/server.html")
assert_contains "it names the unit" "$srv" "openvpn-server@"
assert_contains "it offers the port form" "$srv" "set_port.cgi"
assert_contains "it shows the configuration" "$srv" "tls-crypt"
assert_not_contains "and no tool failure" "$srv" "could not parse"
# systemctl is faked as active in this container, so the configuration must
# be read-only: the editing form appears only while the server is down.
assert_not_contains "a running server offers no configuration editor" \
    "$srv" "apply_config.cgi"
# And the guard is server-side: posting to it anyway is refused.
fetch -o "$tmp/apply.html" --data "config=ca pki/ca.crt&confirm=1" \
    "$base/apply_config.cgi"
assert_contains "and refuses a post while it is running" \
    "$(cat "$tmp/apply.html")" "The server is running"

echo
echo "== adding a client through the module"
fetch -o "$tmp/add.html" -w '%{http_code}' \
    --data "name=webui-client" "$base/add.cgi" > "$tmp/add.code"
if vpn-client list --json | grep -q '"name":"webui-client"'; then
    pass "the client the page created exists in the PKI"
else
    fail "the client the page created exists in the PKI" \
         "$(tail -3 "$tmp/add.html" 2>/dev/null | tr '\n' ' ')"
fi
fetch -o "$tmp/idx2.html" "$base/"
assert_contains "and appears on the page" "$(cat "$tmp/idx2.html")" "webui-client"

echo
echo "== revoking asks first, then revokes"
fetch -o "$tmp/rev1.html" "$base/revoke.cgi?name=webui-client"
rev=$(cat "$tmp/rev1.html")
assert_contains "the confirmation warns every session drops" "$rev" \
    "disconnects every client currently connected"
assert_contains "and that it cannot be undone" "$rev" "cannot be undone"
if vpn-client list --json | grep -q '"name":"webui-client","state":"valid"'; then
    pass "asking did not revoke anything"
else
    fail "asking did not revoke anything" "the client is no longer valid"
fi
fetch -o "$tmp/rev2.html" --data "name=webui-client&confirm=1" "$base/revoke.cgi"
if vpn-client list --json | grep -q '"name":"webui-client","state":"REVOKED"'; then
    pass "confirming revoked it"
else
    fail "confirming revoked it" "$(tail -3 "$tmp/rev2.html" | tr '\n' ' ')"
fi

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

echo
echo "== the smoke checks, against this installation"
# The container is an installation: tools from the package, the module
# unpacked and granted, a server built by init. The same read-only checks
# that will run on a server run here, so they are exercised before anyone
# depends on them - and a stale or half-installed container fails the same
# way a stale or half-installed server would.
#
# WEBMIN_ETC points at the copy this stage granted the module in, since the
# system configuration was left alone.
if WEBMIN_ETC="$tmp/etc" MODULE="$module" bash "$here/smoke.sh" \
        > "$tmp/smoke.log" 2>&1; then
    pass "the smoke checks pass against this installation"
else
    fail "the smoke checks pass against this installation" \
         "$(grep '^\[FAIL\]' "$tmp/smoke.log" | head -4 | tr '\n' ' ')"
fi

report
