#!/bin/bash
# Prepare a server and a client inside the container, then run the Webmin
# stage against them.
#
# The stage needs something to display: a module page listing no clients would
# assert almost nothing. So this builds a server with the tools first, exactly
# as an operator would, and only then hands over to tests/e2e-webmin.sh.
set -euo pipefail

# No init system in a container. systemctl is faked for the duration; every
# other part of this - easy-rsa, openssl, openvpn, Webmin - is real.
mkdir -p /usr/local/testbin
cat > /usr/local/testbin/systemctl <<'EOF'
#!/bin/bash
case "${1:-}" in is-active) echo active ;; esac
exit 0
EOF
chmod 755 /usr/local/testbin/systemctl
export PATH=/usr/local/testbin:$PATH

cd /src

echo "== build a server and issue clients"
vpn-server init --host vpn.example.com --port 1194 >/dev/null
vpn-client add laptop >/dev/null
vpn-client add phone >/dev/null
vpn-client list

echo
echo "== package the module"
make build >/dev/null

echo
exec bash tests/e2e-webmin.sh
