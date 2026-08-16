#!/bin/bash
# Build a throwaway OpenVPN site in a temporary directory.
#
# The PKI is real, not stubbed: certificates are generated with openssl using
# the same EC curve as a real installation, so the code paths that read
# index.txt, call openssl x509 and inline certificates into a profile run
# for real. Only the pieces that cannot exist here are faked - easyrsa, which
# would otherwise need a full easy-rsa 3 install, and systemctl.
#
# Prints the fixture root on stdout.
#
# With --bare it stops after creating the directory skeleton and the fake
# easyrsa, so `vpn-server init` has the same starting point a real unconfigured
# host gives it: a tool and nowhere to put anything yet.
set -euo pipefail

CURVE=${CURVE:-secp384r1}
BARE=0
[ "${1:-}" = "--bare" ] && BARE=1

root=$(mktemp -d)
mkdir -p "$root/easyrsa/pki/issued" "$root/easyrsa/pki/private" \
         "$root/server/pki" "$root/clients" "$root/log" "$root/bin" \
         "$root/default"
chmod 700 "$root/clients"

# --- fake easyrsa ---------------------------------------------------------
# Reproduces the observable behaviour the tools depend on and nothing else:
# init-pki, build-ca, build-server-full, build-client-full, revoke, gen-crl.
cat > "$root/easyrsa/easyrsa" <<EOF
#!/bin/bash
set -eu
cd "\$(dirname "\$0")"
args=()
for a in "\$@"; do [ "\$a" = "--batch" ] || args+=("\$a"); done
issue() {
    local name=\$1
    printf 'algo=%s curve=%s\\n' "\${EASYRSA_ALGO:-unset}" "\${EASYRSA_CURVE:-unset}" \\
        >> ../easyrsa-env.log
    openssl ecparam -genkey -name "\${EASYRSA_CURVE:-$CURVE}" \\
        -out "pki/private/\$name.key" 2>/dev/null
    openssl req -new -key "pki/private/\$name.key" -subj "/CN=\$name" \\
        -out "/tmp/\$name.csr" 2>/dev/null
    openssl x509 -req -in "/tmp/\$name.csr" -CA pki/ca.crt -CAkey pki/ca.key \\
        -CAcreateserial -days 1080 -sha256 -out "pki/issued/\$name.crt" 2>/dev/null
    rm -f "/tmp/\$name.csr"
    printf 'V\t290730185650Z\t\t%02d\tunknown\t/CN=%s\n' \\
        "\$(( \$(wc -l < pki/index.txt) + 1 ))" "\$name" >> pki/index.txt
}
case "\${args[0]}" in
init-pki)
    rm -rf pki
    mkdir -p pki/issued pki/private
    : > pki/index.txt
    ;;
build-ca)
    printf 'algo=%s curve=%s\\n' "\${EASYRSA_ALGO:-unset}" "\${EASYRSA_CURVE:-unset}" \\
        >> ../easyrsa-env.log
    openssl ecparam -genkey -name "\${EASYRSA_CURVE:-$CURVE}" -out pki/ca.key 2>/dev/null
    openssl req -x509 -new -key pki/ca.key -sha256 -days 3650 \\
        -subj "/CN=\${EASYRSA_REQ_CN:-fixture-ca}" -out pki/ca.crt 2>/dev/null
    ;;
build-server-full|build-client-full)
    issue "\${args[1]}"
    ;;
revoke)
    sed -i "s|^V\(.*\)/CN=\${args[1]}\\\$|R\1/CN=\${args[1]}|" pki/index.txt
    ;;
gen-crl)
    printf -- '-----BEGIN X509 CRL-----\nfixture\n-----END X509 CRL-----\n' > pki/crl.pem
    ;;
*)
    echo "fixture easyrsa: unsupported \${args[0]}" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$root/easyrsa/easyrsa"

if [ "$BARE" = 1 ]; then
    rm -rf "$root/easyrsa/pki" "$root/server/pki"
    printf '%s\n' "$root"
    exit 0
fi

# --- CA ------------------------------------------------------------------
openssl ecparam -genkey -name "$CURVE" -out "$root/easyrsa/pki/ca.key" 2>/dev/null
openssl req -x509 -new -key "$root/easyrsa/pki/ca.key" -sha256 -days 3650 \
    -subj "/CN=fixture-ca" -out "$root/easyrsa/pki/ca.crt" 2>/dev/null

issue() {
    local name=$1 days=$2
    openssl ecparam -genkey -name "$CURVE" \
        -out "$root/easyrsa/pki/private/$name.key" 2>/dev/null
    openssl req -new -key "$root/easyrsa/pki/private/$name.key" \
        -subj "/CN=$name" -out "$root/tmp.csr" 2>/dev/null
    openssl x509 -req -in "$root/tmp.csr" -CA "$root/easyrsa/pki/ca.crt" \
        -CAkey "$root/easyrsa/pki/ca.key" -CAcreateserial -days "$days" \
        -sha256 -out "$root/easyrsa/pki/issued/$name.crt" 2>/dev/null
    rm -f "$root/tmp.csr"
}

issue gateway-server 3000
issue alice-phone 1080
issue bob-laptop 1080
issue retired-laptop 1080

# --- index.txt, in the format easy-rsa 3 actually writes ------------------
# V/R/E, expiry, revocation date (R only), serial, filename, subject DN.
{
    printf 'V\t290730185650Z\t\t01\tunknown\t/CN=gateway-server\n'
    printf 'V\t290730185650Z\t\t02\tunknown\t/CN=alice-phone\n'
    printf 'V\t290730185650Z\t\t03\tunknown\t/CN=bob-laptop\n'
    printf 'R\t290730185650Z\t260815195600Z\t04\tunknown\t/CN=retired-laptop\n'
} > "$root/easyrsa/pki/index.txt"

# --- server side ----------------------------------------------------------
cp "$root/easyrsa/pki/ca.crt" "$root/server/pki/ca.crt"
cp "$root/easyrsa/pki/issued/gateway-server.crt" "$root/server/pki/gateway-server.crt"
cp "$root/easyrsa/pki/private/gateway-server.key" "$root/server/pki/gateway-server.key"
openssl rand -hex 128 > "$root/server/tls-crypt.key"

cat > "$root/server/server.conf" <<'EOF'
port 1194
proto udp
dev tun
topology subnet

server 10.8.0.0 255.255.255.0
push "route 192.168.50.0 255.255.255.0"
push "dhcp-option DNS 192.168.50.1"

ca   pki/ca.crt
cert pki/gateway-server.crt
key  pki/gateway-server.key
crl-verify pki/crl.pem
tls-crypt tls-crypt.key

keepalive 10 60
verb 3
EOF

cat > "$root/default/upnp-port-forward" <<'EOF'
WAN_IF=eth0
PORT=1194
PROTO=UDP
LEASE=3600
DESC=openvpn
EOF

# --- status file, --status-version 2 with one client connected ------------
{
    printf 'TITLE,OpenVPN 2.6.19\n'
    printf 'HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,'
    printf 'Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,'
    printf 'Connected Since (time_t),Username,Client ID,Peer ID,Data Channel Cipher\n'
    printf 'CLIENT_LIST,bob-laptop,203.0.113.9:51820,10.8.0.4,,12345,67890,'
    printf '2026-08-15 20:10:00,1786000200,UNDEF,1,0,AES-256-GCM\n'
    printf 'GLOBAL_STATS,Max bcast/mcast queue length,0\n'
    printf 'END\n'
} > "$root/log/status.log"

printf '%s\n' "$root"
