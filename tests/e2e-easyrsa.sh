#!/bin/bash
# Run vpn-server init against easy-rsa itself, not the fixture's fake.
#
# This stage exists because of a defect the mocked suite could not see. The
# fake easyrsa was handed a curve by the fixture and produced EC certificates
# no matter what init asked for, so 94 passing assertions said nothing about
# key algorithm - while init was in fact inheriting easy-rsa's RSA 2048
# default. A mock that supplies the value under test validates nothing about
# it.
#
# What is not faked here: easy-rsa, openssl, the PKI, the certificates.
# What is still faked: systemctl (no init system in a container), id (the
# worker is unprivileged), and openvpn (not installed, and not what this
# stage is testing - the tls-crypt branch is covered by the mocked suite).
#
# Takes the path to an easyrsa checkout as its first argument.
set -uo pipefail

easyrsa_bin=${1:?usage: e2e-easyrsa.sh <path-to-easyrsa>}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

if [ ! -x "$easyrsa_bin" ]; then
    fail "easyrsa is executable" "$easyrsa_bin is not"
    report
    exit 1
fi

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/server" "$root/clients" "$root/log" "$root/default"

mock_bin "$root/bin" id "
if [ \"\${1:-}\" = -u ]; then echo 0; exit 0; fi
exec /usr/bin/id \"\$@\"
"
mock_bin "$root/bin" systemctl "
echo \"systemctl \$*\" >> $root/systemctl.log
case \"\${1:-}\" in is-active) echo active;; esac
exit 0
"
mock_bin "$root/bin" openvpn "
[ \"\${1:-}\" = --genkey ] || exit 1
[ \"\${2:-}\" = secret ] || exit 1
printf 'fake-tls-crypt\\n' > \"\$3\"
"

echo "== init against $("$easyrsa_bin" --version 2>/dev/null | sed -n 's/^Version: *//p' | head -1 || echo 'easy-rsa')"
out=$(PATH="$root/bin:$PATH" \
    SITE_CONF="$root/default/vpn-tools" \
    SERVER_DIR="$root/server" \
    CLIENT_DIR="$root/clients" \
    EASYRSA_DIR="$root/easyrsa" \
    EASYRSA_BIN="$easyrsa_bin" \
    STATUS_FILE="$root/log/status.log" \
    bash "$repo/tools/vpn-server" init --host vpn.example.com \
        --push "192.168.50.0 255.255.255.0" 2>&1)
rc=$?
assert_exit "init against easy-rsa itself" 0 "$rc"
if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    report
    exit 1
fi

key_algo() {
    openssl x509 -in "$1" -noout -text 2>/dev/null |
        sed -n 's/.*Public Key Algorithm: //p' | head -1
}
key_curve() {
    openssl x509 -in "$1" -noout -text 2>/dev/null |
        sed -n 's/.*NIST CURVE: //p' | head -1
}

echo
echo "== the certificates easy-rsa produced"
assert_eq "CA is EC" "id-ecPublicKey" "$(key_algo "$root/easyrsa/pki/ca.crt")"
assert_eq "CA is on the requested curve" "P-384" "$(key_curve "$root/easyrsa/pki/ca.crt")"
assert_eq "server certificate is EC" "id-ecPublicKey" \
    "$(key_algo "$root/server/pki/server.crt")"
assert_eq "server certificate is on the requested curve" "P-384" \
    "$(key_curve "$root/server/pki/server.crt")"

# x509-types/server is what gives the certificate this extension. Asserting it
# proves easy-rsa found its own scaffolding from wherever the binary lives,
# which is the thing make-cadir normally sets up by hand.
assert_contains "server certificate carries the server EKU" \
    "$(openssl x509 -in "$root/server/pki/server.crt" -noout -text 2>/dev/null)" \
    "TLS Web Server Authentication"

assert_contains "the CA names the host" \
    "$(openssl x509 -in "$root/easyrsa/pki/ca.crt" -noout -subject 2>/dev/null)" \
    "vpn.example.com CA"

echo
echo "== what init installed"
assert_file_contains "a CRL was generated" "$root/server/pki/crl.pem" "X509 CRL"
assert_eq "the server key is not world readable" "600" \
    "$(stat -c %a "$root/server/pki/server.key")"
assert_eq "the CA certificate is readable" "644" \
    "$(stat -c %a "$root/server/pki/ca.crt")"
assert_file_contains "server.conf names the generated certificate" \
    "$root/server/server.conf" "^cert pki/server.crt"
assert_file_contains "server.conf pushes the requested route" \
    "$root/server/server.conf" 'push "route 192.168.50.0 255.255.255.0"'

echo
echo "== the CA directory has the shape make-cadir produces"
# Without this, vpn-client cannot run ./easyrsa and the server can issue
# nothing - a server that builds cleanly and is useless.
if [ -x "$root/easyrsa/easyrsa" ]; then
    pass "easyrsa is reachable from the CA directory"
else
    fail "easyrsa is reachable from the CA directory" "no usable $root/easyrsa/easyrsa"
fi
if [ -e "$root/easyrsa/x509-types" ]; then
    pass "x509-types is in place"
else
    fail "x509-types is in place" "missing"
fi
assert_file_contains "vars carries the algorithm, not just this script's env" \
    "$root/easyrsa/vars" "set_var EASYRSA_ALGO           ec"
assert_file_contains "vars carries the curve" \
    "$root/easyrsa/vars" "set_var EASYRSA_CURVE          secp384r1"

echo
echo "== a client issued from that CA"
out=$(PATH="$root/bin:$PATH" SITE_CONF=/dev/null \
    EASYRSA_DIR="$root/easyrsa" CLIENT_DIR="$root/clients" \
    SERVER_DIR="$root/server" STATUS_FILE="$root/log/status.log" \
    bash "$repo/tools/vpn-client" add first-client 2>&1)
assert_exit "vpn-client add against that PKI" 0 "$?"
assert_file_contains "the profile inlines a certificate" \
    "$root/clients/first-client.ovpn" "BEGIN CERTIFICATE"
assert_file_contains "the profile inlines a private key" \
    "$root/clients/first-client.ovpn" "PRIVATE KEY"
assert_file_contains "the profile names the host from server.conf" \
    "$root/clients/first-client.ovpn" "remote vpn.example.com 1194"
assert_eq "the client key is EC too" "id-ecPublicKey" \
    "$(key_algo "$root/easyrsa/pki/issued/first-client.crt")"

# The client certificate must verify against the CA that issued it. This is
# the end-to-end property the whole PKI exists for, and no mock can assert it.
if openssl verify -CAfile "$root/easyrsa/pki/ca.crt" \
        "$root/easyrsa/pki/issued/first-client.crt" >/dev/null 2>&1; then
    pass "the client certificate verifies against the CA"
else
    fail "the client certificate verifies against the CA" "openssl verify failed"
fi

report
