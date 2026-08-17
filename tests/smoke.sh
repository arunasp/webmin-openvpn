#!/bin/bash
# Read-only checks against a live installation.
#
# Run this on the server after installing, before trusting the module with
# anything. Everything here reads: no client is issued, nothing is revoked,
# no service is restarted, no file is written. It can be run on a working
# production server at any time without consequence.
#
# What it establishes is that the parts agree with each other: the tools are
# where the module will look, the server the tools describe is the one
# systemd is running, the profiles on disk match the clients the PKI knows
# about, and the module's own files are installed and granted.
#
# It does not prove a client can connect. Only a client connecting proves
# that.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

WEBMIN_ROOT=${WEBMIN_ROOT:-/usr/share/webmin}
WEBMIN_ETC=${WEBMIN_ETC:-/etc/webmin}
MODULE=${MODULE:-openvpn-server}
SITE_CONF=${SITE_CONF:-/etc/default/vpn-tools}

echo "== the tools"
client=$(command -v vpn-client 2>/dev/null)
server=$(command -v vpn-server 2>/dev/null)
if [ -n "$client" ] && [ -n "$server" ]; then
    pass "both tools are on PATH ($client, $server)"
else
    fail "both tools are on PATH" "vpn-client='$client' vpn-server='$server'"
    report
    exit 1
fi
# They call each other, so a split install is a problem waiting for set-port.
assert_eq "and in the same directory" "$(dirname "$client")" "$(dirname "$server")"

if [ -r "$SITE_CONF" ]; then
    pass "site configuration is readable at $SITE_CONF"
    # REMOTE_HOST is the one setting with no sensible default: without it,
    # every profile issued names the documentation placeholder.
    if grep -qE '^[[:space:]]*REMOTE_HOST=' "$SITE_CONF"; then
        pass "it sets REMOTE_HOST"
    else
        fail "it sets REMOTE_HOST" "profiles would name the default placeholder"
    fi
else
    fail "site configuration is readable at $SITE_CONF" "not found"
fi

echo
echo "== what the server reports"
status=$(vpn-server status --json 2>/dev/null)
if printf '%s' "$status" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass "status --json parses"
else
    fail "status --json parses" "$(printf '%s' "$status" | head -c 200)"
    report
    exit 1
fi

field() { printf '%s' "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"; }
unit=$(field unit)
active=$(field active)
port=$(field port)
proto=$(field proto)
crl=$(field crl_next_update)

assert_eq "the unit is running" "active" "$active"
echo "   $unit on $port/$proto"

# systemd is the authority on which unit is up; the tool reads a name from
# configuration and could be pointed at the wrong one.
if systemctl is-active --quiet "$unit" 2>/dev/null; then
    pass "systemd agrees that $unit is the running unit"
else
    fail "systemd agrees that $unit is the running unit" \
         "the tools would restart a unit that is not serving the VPN"
fi

# A listening socket on the port the tool reported, whichever family.
if command -v ss >/dev/null 2>&1; then
    if ss -lnu "sport = :$port" 2>/dev/null | grep -q ":$port" ||
       ss -lnt "sport = :$port" 2>/dev/null | grep -q ":$port"; then
        pass "something is listening on $port"
    else
        fail "something is listening on $port" "no socket bound"
    fi
fi

echo
echo "== the clients"
list=$(vpn-client list --json 2>/dev/null)
if printf '%s' "$list" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass "list --json parses"
else
    fail "list --json parses" "$(printf '%s' "$list" | head -c 200)"
    report
    exit 1
fi

summary=$(printf '%s' "$list" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d["clients"]
valid = [x for x in c if x["state"] == "valid"]
revoked = [x for x in c if x["state"] == "REVOKED"]
missing = [x["name"] for x in valid if not x["profile"]]
print(len(c), len(valid), len(revoked), ",".join(missing) or "-")
')
total=$(echo "$summary" | cut -d" " -f1)
valid=$(echo "$summary" | cut -d" " -f2)
revoked=$(echo "$summary" | cut -d" " -f3)
missing=$(echo "$summary" | cut -d" " -f4)
echo "   $total clients: $valid valid, $revoked revoked"

# A valid client with no profile cannot be given to anyone until regen runs.
if [ "$missing" = "-" ]; then
    pass "every valid client has a profile on disk"
else
    fail "every valid client has a profile on disk" \
         "$missing - run vpn-client regen --all"
fi

# The profiles carry private keys.
clients_dir=${CLIENT_DIR:-/etc/openvpn/clients}
if [ -d "$clients_dir" ]; then
    loose=$(find "$clients_dir" -name '*.ovpn' ! -perm 600 2>/dev/null)
    if [ -z "$loose" ]; then
        pass "no profile is readable beyond its owner"
    else
        fail "no profile is readable beyond its owner" "$loose"
    fi
fi

# A CRL that has expired stops the server verifying anyone at all.
if [ -n "$crl" ]; then
    crl_epoch=$(date -d "$crl" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$crl_epoch" -gt "$now" ]; then
        days=$(( (crl_epoch - now) / 86400 ))
        pass "the revocation list is valid for another $days days"
    else
        fail "the revocation list is still valid" "expired at $crl"
    fi
fi

echo
echo "== the module"
if [ -d "$WEBMIN_ROOT/$MODULE" ]; then
    pass "installed at $WEBMIN_ROOT/$MODULE"
    for f in index.cgi add.cgi revoke.cgi download.cgi server.cgi \
             set_port.cgi apply_config.cgi openvpn-server-lib.pl lang/en; do
        if [ -e "$WEBMIN_ROOT/$MODULE/$f" ]; then
            pass "  $f"
        else
            fail "  $f" "missing from the installed module"
        fi
    done
    installed=$(sed -n 's/^version=//p' "$WEBMIN_ROOT/$MODULE/module.info")
    echo "   version $installed"

    # Installed but not granted is the failure that reads as "not allowed to
    # use this module" on every page.
    if grep -qE "^[a-z0-9_-]+:.*\b$MODULE\b" "$WEBMIN_ETC/webmin.acl" 2>/dev/null; then
        pass "granted to at least one Webmin user"
    else
        fail "granted to at least one Webmin user" \
             "install through Webmin Modules rather than by unpacking"
    fi
else
    fail "installed at $WEBMIN_ROOT/$MODULE" "not found"
fi

report
