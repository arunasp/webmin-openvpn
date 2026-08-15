#!/bin/bash
# Suite for tools/vpn-client and tools/vpn-server.
#
# Everything runs against a fixture site built by fixture.sh, with systemctl,
# id and openvpn mocked on PATH. Each scenario gets a fresh fixture, so a test
# that mutates the PKI cannot change what a later test sees.
#
# The failure scenarios matter more than the happy paths here: a rollback that
# has never been observed rolling back is not a rollback.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

VPN_CLIENT_BIN=$repo/tools/vpn-client
VPN_SERVER_BIN=$repo/tools/vpn-server

FIXTURES=()
cleanup() {
    local f
    for f in "${FIXTURES[@]:-}"; do
        [ -n "$f" ] && rm -rf "$f"
    done
}
trap cleanup EXIT

# new_fixture <uid> <systemctl-mode> -- prints the fixture root.
# systemctl mode "ok" behaves like a unit that starts; "fail" like one that
# refuses the config it was just given.
new_fixture() {
    local uid=$1 mode=$2 root
    root=$(bash "$here/fixture.sh")
    FIXTURES+=("$root")

    mock_bin "$root/bin" id "
if [ \"\${1:-}\" = -u ]; then echo $uid; exit 0; fi
exec /usr/bin/id \"\$@\"
"
    mock_bin "$root/bin" systemctl "
echo \"systemctl \$*\" >> $root/systemctl.log
case \"\${1:-}\" in
is-active)
    if [ \"$mode\" = fail ]; then echo failed; exit 3; fi
    echo active; exit 0 ;;
restart|reload-or-restart)
    if [ \"$mode\" = fail ]; then
        echo 'Job for \$2 failed. See systemctl status for details.' >&2
        exit 1
    fi
    exit 0 ;;
*) exit 0 ;;
esac
"
    printf '%s\n' "$root"
}

# new_bare_fixture <genkey-syntax> -- a host with easy-rsa and nothing else.
# genkey syntax "modern" accepts `--genkey secret FILE` (OpenVPN 2.6),
# "legacy" only `--genkey --secret FILE` (2.4 and earlier), "none" neither.
new_bare_fixture() {
    local syntax=$1 root
    root=$(bash "$here/fixture.sh" --bare)
    FIXTURES+=("$root")

    mock_bin "$root/bin" id "
if [ \"\${1:-}\" = -u ]; then echo 0; exit 0; fi
exec /usr/bin/id \"\$@\"
"
    mock_bin "$root/bin" systemctl "
echo \"systemctl \$*\" >> $root/systemctl.log
case \"\${1:-}\" in
is-active) echo active; exit 0 ;;
*) exit 0 ;;
esac
"
    mock_bin "$root/bin" openvpn "
if [ \"\${1:-}\" != --genkey ]; then exit 1; fi
case \"$syntax\" in
modern)
    [ \"\${2:-}\" = secret ] || { echo 'Options error: unknown option' >&2; exit 1; }
    printf 'fixture-tls-crypt-key\\n' > \"\$3\"; exit 0 ;;
legacy)
    [ \"\${2:-}\" = --secret ] || { echo 'Options error: unknown option' >&2; exit 1; }
    printf 'fixture-tls-crypt-key\\n' > \"\$3\"; exit 0 ;;
*)
    echo 'Options error: unknown option' >&2; exit 1 ;;
esac
"
    printf '%s\n' "$root"
}

# run_init <root> <args...> ; init writes a site file, so unlike the other
# runners this one points SITE_CONF at the fixture rather than /dev/null.
run_init() {
    local root=$1
    shift
    OUT=$(PATH="$root/bin:$PATH" \
        SITE_CONF="$root/default/vpn-tools" \
        SERVER_DIR="$root/server" \
        CLIENT_DIR="$root/clients" \
        EASYRSA_DIR="$root/easyrsa" \
        STATUS_FILE="$root/log/status.log" \
        UPNP_DEFAULTS="$root/default/upnp-port-forward" \
        VPN_CLIENT="$root/bin/vpn-client-wrapper" \
        bash "$VPN_SERVER_BIN" init "$@" 2>&1)
    RC=$?
}

# run_client <root> <args...> ; sets OUT and RC
run_client() {
    local root=$1
    shift
    OUT=$(PATH="$root/bin:$PATH" \
        SITE_CONF=/dev/null \
        EASYRSA_DIR="$root/easyrsa" \
        CLIENT_DIR="$root/clients" \
        SERVER_DIR="$root/server" \
        STATUS_FILE="$root/log/status.log" \
        bash "$VPN_CLIENT_BIN" "$@" 2>&1)
    RC=$?
}

run_server() {
    local root=$1
    shift
    OUT=$(PATH="$root/bin:$PATH" \
        SITE_CONF=/dev/null \
        SERVER_DIR="$root/server" \
        CLIENT_DIR="$root/clients" \
        STATUS_FILE="$root/log/status.log" \
        UPNP_DEFAULTS="$root/default/upnp-port-forward" \
        VPN_CLIENT="$root/bin/vpn-client-wrapper" \
        bash "$VPN_SERVER_BIN" "$@" 2>&1)
    RC=$?
}

# vpn-server shells out to vpn-client for regeneration; the wrapper carries
# the fixture's environment across that boundary.
install_client_wrapper() {
    local root=$1
    mock_bin "$root/bin" vpn-client-wrapper "
export EASYRSA_DIR=$root/easyrsa
export CLIENT_DIR=$root/clients
export SERVER_DIR=$root/server
export STATUS_FILE=$root/log/status.log
export SITE_CONF=/dev/null
exec bash $VPN_CLIENT_BIN \"\$@\"
"
}

json_field() {
    python3 -c '
import json,sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)
' "$1"
}

echo "== vpn-client: reading an existing site"
root=$(new_fixture 1000 ok)
run_client "$root" list
assert_exit "list" 0 "$RC"
assert_contains "list shows a valid client" "$OUT" "alice-phone"
assert_contains "list shows the revoked client" "$OUT" "retired-laptop     REVOKED"
assert_not_contains "list hides the server certificate" "$OUT" "gateway-server"
assert_contains "list shows who is connected" "$OUT" "bob-laptop"

run_client "$root" list --json
assert_exit "list --json" 0 "$RC"
if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass "list --json emits parseable JSON"
    assert_eq "json: client count" "3" "$(printf '%s' "$OUT" | json_field clients | python3 -c 'import sys; print(sys.stdin.read().count("name"))')"
    assert_eq "json: port comes from server.conf" "1194" \
        "$(printf '%s' "$OUT" | json_field server.port)"
    assert_eq "json: revoked state" "REVOKED" \
        "$(printf '%s' "$OUT" | json_field clients.2.state)"
    assert_eq "json: connected client" "True" \
        "$(printf '%s' "$OUT" | json_field clients.1.connected)"
    assert_eq "json: idle client" "False" \
        "$(printf '%s' "$OUT" | json_field clients.0.connected)"
else
    fail "list --json emits parseable JSON" "python could not parse it"
fi

echo
echo "== vpn-client: the root gate"
run_client "$root" regen --all
assert_exit "regen refused as non-root" 1 "$RC"
assert_contains "regen says why" "$OUT" "must run as root"
run_client "$root" list
assert_exit "list still works as non-root" 0 "$RC"

echo
echo "== vpn-client: regen, add, revoke as root"
root=$(new_fixture 0 ok)
run_client "$root" regen --all
assert_exit "regen --all" 0 "$RC"
assert_contains "regen skips the revoked client" "$OUT" "skipping retired-laptop"
assert_file_contains "profile names the configured port" \
    "$root/clients/alice-phone.ovpn" "remote vpn.example.com 1194"
assert_file_contains "profile inlines the tls-crypt key" \
    "$root/clients/alice-phone.ovpn" "<tls-crypt>"
assert_file_contains "profile inlines the private key" \
    "$root/clients/alice-phone.ovpn" "PRIVATE KEY"
assert_eq "profile is not world readable" "600" \
    "$(stat -c %a "$root/clients/alice-phone.ovpn")"
assert_file_absent "no profile for the revoked client" "$root/clients/retired-laptop.ovpn"

assert_file_contains "profile describes the routes the server pushes" \
    "$root/clients/alice-phone.ovpn" "192.168.50.0/255.255.255.0"

printf 'REMOTE_HOST=vpn.example.org\n' > "$root/site.conf"
OUT=$(PATH="$root/bin:$PATH" SITE_CONF="$root/site.conf" \
    EASYRSA_DIR="$root/easyrsa" CLIENT_DIR="$root/clients" \
    SERVER_DIR="$root/server" STATUS_FILE="$root/log/status.log" \
    bash "$VPN_CLIENT_BIN" regen alice-phone 2>&1)
RC=$?
assert_exit "regen honours a site config file" 0 "$RC"
assert_file_contains "site config supplies the remote host" \
    "$root/clients/alice-phone.ovpn" "remote vpn.example.org 1194"
run_client "$root" regen alice-phone >/dev/null

run_client "$root" add 'bad name'
assert_exit "add rejects an unsafe name" 1 "$RC"
assert_contains "add says which names are allowed" "$OUT" "letters, digits"

run_client "$root" add alice-phone
assert_exit "add refuses a duplicate" 1 "$RC"
assert_contains "add names the conflict" "$OUT" "already exists"

run_client "$root" add zz-test
assert_exit "add a new client" 0 "$RC"
assert_file_contains "new profile exists" "$root/clients/zz-test.ovpn" "remote vpn.example.com"
run_client "$root" list --json
assert_eq "json: the new client is listed" "zz-test" \
    "$(printf '%s' "$OUT" | json_field clients.3.name)"

run_client "$root" revoke zz-test
assert_exit "revoke" 0 "$RC"
assert_contains "revoke is honest about dropping every session" "$OUT" "all sessions dropped"
assert_file_absent "revoke removes the profile" "$root/clients/zz-test.ovpn"
assert_file_contains "revoke restarted the server unit" "$root/systemctl.log" \
    "reload-or-restart openvpn-server@server"
run_client "$root" list
assert_contains "revoked client is now listed REVOKED" "$OUT" "zz-test            REVOKED"

run_client "$root" show nosuchclient
assert_exit "show refuses an unknown client" 1 "$RC"

echo
echo "== vpn-server: status"
root=$(new_fixture 0 ok)
install_client_wrapper "$root"
run_server "$root" status --json
assert_exit "status --json" 0 "$RC"
assert_eq "status: port" "1194" "$(printf '%s' "$OUT" | json_field port)"
assert_eq "status: proto" "udp" "$(printf '%s' "$OUT" | json_field proto)"
assert_eq "status: connected count" "1" "$(printf '%s' "$OUT" | json_field connected)"

echo
echo "== vpn-server: set-port refusals"
run_server "$root" set-port abc
assert_exit "set-port rejects a non-numeric port" 1 "$RC"
run_server "$root" set-port 70000
assert_exit "set-port rejects an out-of-range port" 1 "$RC"
run_server "$root" set-port 1195 sctp
assert_exit "set-port rejects an unknown protocol" 1 "$RC"
assert_file_contains "refusals leave server.conf alone" "$root/server/server.conf" "^port 1194"
run_server "$root" set-port 1194 udp
assert_exit "set-port is a no-op when nothing changes" 0 "$RC"
assert_contains "no-op says so" "$OUT" "nothing to do"

echo
echo "== vpn-server: set-port succeeds and takes the profiles with it"
root=$(new_fixture 0 ok)
install_client_wrapper "$root"
run_client "$root" regen --all >/dev/null
run_server "$root" set-port 1195 udp
assert_exit "set-port" 0 "$RC"
assert_file_contains "server.conf carries the new port" "$root/server/server.conf" "^port 1195"
assert_file_contains "UPnP mapping carries the new port" \
    "$root/default/upnp-port-forward" "^PORT=1195"
assert_file_contains "profiles were regenerated with the new port" \
    "$root/clients/alice-phone.ovpn" "remote vpn.example.com 1195"
assert_file_contains "a backup of the old config was kept" \
    "$(find "$root/server" -name 'server.conf.bak-*' | head -1)" "^port 1194"
assert_file_absent "no rollback file left behind" "$root/default/upnp-port-forward.rollback"

echo
echo "== vpn-server: a config the daemon refuses is rolled back"
root=$(new_fixture 0 fail)
install_client_wrapper "$root"
run_client "$root" regen --all >/dev/null
run_server "$root" set-port 1196 tcp
assert_exit "set-port fails when the unit does not come up" 1 "$RC"
assert_contains "failure is reported as a rollback" "$OUT" "ROLLED BACK"
assert_file_contains "server.conf is back to the old port" \
    "$root/server/server.conf" "^port 1194"
assert_file_contains "server.conf is back to the old protocol" \
    "$root/server/server.conf" "^proto udp"
assert_file_contains "UPnP mapping is back to the old port" \
    "$root/default/upnp-port-forward" "^PORT=1194"
assert_file_contains "profiles were left on the working port" \
    "$root/clients/alice-phone.ovpn" "remote vpn.example.com 1194"
assert_file_absent "no rollback file left behind" "$root/default/upnp-port-forward.rollback"

echo
echo "== vpn-server: apply-config refuses an unrelated file"
root=$(new_fixture 0 ok)
install_client_wrapper "$root"
printf 'this is not an openvpn config\n' > "$root/junk.conf"
run_server "$root" apply-config "$root/junk.conf"
assert_exit "apply-config rejects a file with no directives" 1 "$RC"
assert_file_contains "the running config was not touched" \
    "$root/server/server.conf" "^port 1194"
assert_not_contains "systemctl was never called" "$(cat "$root/systemctl.log" 2>/dev/null)" "restart"

echo
echo "== vpn-server: init on a bare host"
root=$(new_bare_fixture modern)
run_init "$root" --host vpn.example.com --push "192.168.50.0 255.255.255.0" \
    --dns 192.168.50.1
assert_exit "init" 0 "$RC"
assert_contains "init reports the listening port" "$OUT" "1194/udp"
assert_file_contains "server.conf has the port" "$root/server/server.conf" "^port 1194"
assert_file_contains "server.conf pushes the route" \
    "$root/server/server.conf" 'push "route 192.168.50.0 255.255.255.0"'
assert_file_contains "server.conf names the server certificate" \
    "$root/server/server.conf" "^cert pki/server.crt"
assert_file_contains "the CA was built" "$root/easyrsa/pki/ca.crt" "BEGIN CERTIFICATE"
assert_file_contains "the server certificate was issued" \
    "$root/server/pki/server.crt" "BEGIN CERTIFICATE"
assert_file_contains "a CRL exists" "$root/server/pki/crl.pem" "X509 CRL"
assert_file_contains "the tls-crypt key was generated" \
    "$root/server/tls-crypt.key" "fixture-tls-crypt-key"
assert_eq "the server key is not world readable" "600" \
    "$(stat -c %a "$root/server/pki/server.key")"
assert_file_contains "the site file records the host" \
    "$root/default/vpn-tools" "REMOTE_HOST=vpn.example.com"
assert_eq "the site file is private" "600" \
    "$(stat -c %a "$root/default/vpn-tools")"
assert_file_contains "the unit was enabled and started" "$root/systemctl.log" \
    "enable --now"

# easy-rsa defaults to RSA 2048. Everything else in this project is EC, so
# init has to say so explicitly - and this asserts that it did, on every
# certificate it had built, not just the first.
assert_file_contains "init asked easy-rsa for EC" \
    "$root/easyrsa-env.log" "algo=ec"
assert_file_contains "init named the curve" \
    "$root/easyrsa-env.log" "curve=secp384r1"
assert_not_contains "no certificate was built with the default algorithm" \
    "$(cat "$root/easyrsa-env.log")" "algo=unset"
assert_eq "the CA key really is EC" "id-ecPublicKey" \
    "$(openssl x509 -in "$root/easyrsa/pki/ca.crt" -noout -text |
       sed -n 's/.*Public Key Algorithm: //p' | head -1)"
assert_eq "the server key really is EC" "id-ecPublicKey" \
    "$(openssl x509 -in "$root/server/pki/server.crt" -noout -text |
       sed -n 's/.*Public Key Algorithm: //p' | head -1)"

root=$(new_bare_fixture modern)
run_init "$root" --host vpn.example.com --curve prime256v1
assert_exit "init accepts another curve" 0 "$RC"
assert_file_contains "and passes it through" "$root/easyrsa-env.log" "curve=prime256v1"

echo
echo "== the new server is immediately usable by vpn-client"
OUT=$(PATH="$root/bin:$PATH" SITE_CONF=/dev/null EASYRSA_DIR="$root/easyrsa" \
    CLIENT_DIR="$root/clients" SERVER_DIR="$root/server" \
    STATUS_FILE="$root/log/status.log" \
    bash "$VPN_CLIENT_BIN" add first-client 2>&1)
RC=$?
assert_exit "add a client to the new server" 0 "$RC"
assert_file_contains "its profile names the host from server.conf" \
    "$root/clients/first-client.ovpn" "remote vpn.example.com 1194"
OUT=$(PATH="$root/bin:$PATH" SITE_CONF=/dev/null EASYRSA_DIR="$root/easyrsa" \
    CLIENT_DIR="$root/clients" SERVER_DIR="$root/server" \
    STATUS_FILE="$root/log/status.log" \
    bash "$VPN_CLIENT_BIN" list 2>&1)
assert_contains "the client is listed" "$OUT" "first-client"
assert_not_contains "the server certificate is not listed as a client" \
    "$OUT" "gateway"

echo
echo "== init: refusals"
run_init "$root" --host vpn.example.com
assert_exit "init refuses to overwrite an existing server" 1 "$RC"
assert_contains "and says why" "$OUT" "already exists"

root=$(new_bare_fixture modern)
run_init "$root"
assert_exit "init requires a host name" 1 "$RC"
run_init "$root" --host 'not a host'
assert_exit "init rejects an unsafe host name" 1 "$RC"
run_init "$root" --host vpn.example.com --port 70000
assert_exit "init rejects an out-of-range port" 1 "$RC"
run_init "$root" --host vpn.example.com --proto sctp
assert_exit "init rejects an unknown protocol" 1 "$RC"
assert_file_absent "a refused init leaves no config" "$root/server/server.conf"

echo
echo "== init: the openvpn --genkey syntax is detected, not assumed"
root=$(new_bare_fixture legacy)
run_init "$root" --host vpn.example.com
assert_exit "init works against the older --genkey --secret form" 0 "$RC"
assert_file_contains "the key was still generated" \
    "$root/server/tls-crypt.key" "fixture-tls-crypt-key"

root=$(new_bare_fixture none)
run_init "$root" --host vpn.example.com
assert_exit "init fails loudly when neither form works" 1 "$RC"
assert_contains "and names the step that failed" "$OUT" "tls-crypt"

echo
echo "== init: easy-rsa must be found, not guessed"
root=$(new_bare_fixture modern)
rm -f "$root/easyrsa/easyrsa"
run_init "$root" --host vpn.example.com
assert_exit "init fails when easy-rsa is absent" 1 "$RC"
assert_contains "and says how to fix it" "$OUT" "EASYRSA_BIN"

report
