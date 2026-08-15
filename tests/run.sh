#!/bin/bash
# Suite for tools/vpn-client and tools/vpn-server.
#
# Everything runs against a fixture site built by fixture.sh, with systemctl
# and id mocked on PATH. Each scenario gets a fresh fixture, so a test that
# mutates the PKI cannot change what a later test sees.
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

report
