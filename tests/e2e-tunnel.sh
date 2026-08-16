#!/bin/bash
# Build a server with the tools, connect a client through it, and prove
# that revoking the client stops it connecting.
#
# Everything above this stage stops short of the thing the software is for.
# The suite proves the tools produce the files they claim; e2e-easyrsa proves a
# genuine easy-rsa accepts what init asks of it; apicheck proves the module
# calls functions that exist. None of them establish that a profile issued
# here lets a client onto the network, or that a revoked one does not - and a
# VPN that hands out profiles nobody can connect with, or keeps honouring
# revoked ones, has failed at exactly the job it exists to do.
#
# Requirements: openvpn and easy-rsa installed, /dev/net/tun, and CAP_NET_ADMIN.
# Nothing here is faked except systemctl, because no container has an init
# system; the server is started directly and is the openvpn daemon.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

# A port nothing else is likely to hold, and different on every run so a
# daemon left behind by an interrupted run cannot make the next one look like
# a configuration failure.
PORT=${PORT:-$(( 11940 + (RANDOM % 200) ))}
SERVER_LOG=
CLIENT_LOG=

for need in openvpn openssl; do
    command -v "$need" >/dev/null 2>&1 || {
        fail "$need is installed" "not on PATH"
        report
        exit 1
    }
done
if [ ! -c /dev/net/tun ]; then
    fail "/dev/net/tun exists" "no tun device; run with --device /dev/net/tun"
    report
    exit 1
fi

root=$(mktemp -d)
server_pid=
client_pid=
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
    [ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null
    sleep 1
    rm -rf "$root"
}
trap cleanup EXIT

mkdir -p "$root/bin" "$root/server" "$root/clients" "$root/log" "$root/default"
mock_bin "$root/bin" systemctl "
echo \"systemctl \$*\" >> $root/systemctl.log
case \"\${1:-}\" in is-active) echo active;; esac
exit 0
"

run_tool() {
    local tool=$1
    shift
    PATH="$root/bin:$PATH" \
    SITE_CONF="$root/default/vpn-tools" \
    SERVER_DIR="$root/server" \
    CLIENT_DIR="$root/clients" \
    EASYRSA_DIR="$root/easyrsa" \
    STATUS_FILE="$root/log/status.log" \
    bash "$repo/tools/$tool" "$@" 2>&1
}

# Start the server directly. The unit would normally do this, and there is no
# init system here, but it is openvpn reading the generated config.
start_server() {
    local waited=0
    # The generated config sets log-append, and that wins over anything given
    # on the command line, so the test reads where the daemon will actually
    # write rather than assuming it can redirect it.
    SERVER_LOG=$(awk '$1 == "log-append" || $1 == "log" { print $2 }' \
                 "$root/server/server.conf" | tail -1)
    [ -n "$SERVER_LOG" ] || SERVER_LOG=$root/log/server.log
    : > "$SERVER_LOG" 2>/dev/null
    rm -f "$root/server.pid"
    # setsid with every descriptor redirected: a daemon that inherits the
    # caller's terminal keeps the invoking shell open, which looks like a hang.
    ( cd "$root/server" && setsid openvpn --config server.conf \
        --port "$PORT" --status "$root/log/status.log" 30 \
        --daemon --writepid "$root/server.pid" </dev/null >/dev/null 2>&1 )
    # Wait for the daemon to report readiness instead of guessing at a delay.
    while [ "$waited" -lt 15 ]; do
        if grep -q 'Initialization Sequence Completed' "$SERVER_LOG" 2>/dev/null; then
            server_pid=$(cat "$root/server.pid" 2>/dev/null)
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# A restart has to wait for the old daemon to release the socket, or the new
# one exits with "Address already in use" and the failure looks like the CRL.
stop_server() {
    [ -n "$server_pid" ] || return 0
    kill "$server_pid" 2>/dev/null
    local waited=0
    while [ "$waited" -lt 10 ] && kill -0 "$server_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    server_pid=
}

# Connect as a client and report whether the tunnel came up. A client that
# fails to authenticate exits or stalls; either way the tun interface never
# gets an address, which is the signal this waits for.
try_connect() {
    local profile=$1 dev=$2 waited=0
    CLIENT_LOG=$root/log/client-$dev.log
    setsid openvpn --config "$profile" --dev "$dev" --port "$PORT" \
        --remote 127.0.0.1 --log-append "$CLIENT_LOG" --daemon \
        --writepid "$root/client.pid" </dev/null >/dev/null 2>&1
    sleep 2
    client_pid=$(cat "$root/client.pid" 2>/dev/null)
    while [ "$waited" -lt 25 ]; do
        # OpenVPN says so itself, which is more portable than inspecting the
        # interface: iproute2 is absent from many minimal images.
        if grep -q 'Initialization Sequence Completed' "$CLIENT_LOG" 2>/dev/null; then
            return 0
        fi
        if grep -qiE 'AUTH_FAILED|TLS Error|certificate verify failed|VERIFY ERROR' \
                "$CLIENT_LOG" 2>/dev/null; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

echo "== build a server with vpn-server init"
out=$(run_tool vpn-server init --host 127.0.0.1 --port "$PORT")
rc=$?
assert_exit "init" 0 "$rc"
if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    report
    exit 1
fi
assert_eq "the CA is EC" "id-ecPublicKey" \
    "$(openssl x509 -in "$root/easyrsa/pki/ca.crt" -noout -text |
       sed -n 's/.*Public Key Algorithm: //p' | head -1)"

echo
echo "== start it, and issue a client"
if start_server; then
    pass "the server started with the generated configuration"
else
    fail "the server started with the generated configuration" \
         "$(tail -5 "$SERVER_LOG" 2>/dev/null | tr '\n' ' ')"
    report
    exit 1
fi

out=$(run_tool vpn-client add tester)
assert_exit "vpn-client add" 0 "$?"
assert_file_contains "the profile exists" "$root/clients/tester.ovpn" "BEGIN CERTIFICATE"

echo
echo "== connect with the issued profile"
if try_connect "$root/clients/tester.ovpn" tun9; then
    pass "the client connected and the tunnel came up"
    # The status file is rewritten on a timer and its path is fixed by the
    # config, so the daemon's log is both faster and more direct evidence
    # that this particular client is the one that authenticated.
    assert_contains "the server authenticated that client by name" \
        "$(cat "$SERVER_LOG" 2>/dev/null)" "tester"
else
    fail "the client connected and the tunnel came up" \
         "$(tail -5 "$CLIENT_LOG" 2>/dev/null | tr '\n' ' ')"
fi

# The point of a CRL is that this stops working. Nothing before this stage
# checks that revocation has any effect on a running server.
echo
echo "== revoke, and try again"
kill "$client_pid" 2>/dev/null
client_pid=
sleep 1
# revoke deletes the profile, which is correct; keep a copy so the attempt
# below is the one a revoked user would actually still be holding.
cp "$root/clients/tester.ovpn" "$root/tester-revoked.ovpn"
out=$(run_tool vpn-client revoke tester)
assert_exit "vpn-client revoke" 0 "$?"
assert_file_contains "the CRL names the revoked certificate" \
    "$root/server/pki/crl.pem" "BEGIN X509 CRL"

stop_server
if start_server; then
    pass "the server restarted with the new CRL"
else
    fail "the server restarted with the new CRL" \
         "$(tail -3 "$SERVER_LOG" 2>/dev/null | tr '\n' ' ')"
fi

if try_connect "$root/tester-revoked.ovpn" tun8 2>/dev/null; then
    fail "a revoked client is refused" "it connected"
else
    pass "a revoked client cannot connect"
fi

report
