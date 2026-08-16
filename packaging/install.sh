#!/bin/sh
# Install the OpenVPN server tools, and point Webmin at the module package.
#
# One command on a server that has nothing but curl: it downloads the release
# assets, verifies every one of them against SHA256SUMS, installs the tools,
# and tells you the URL to hand Webmin for the module.
#
# POSIX sh, not bash. A target host is assumed to have curl, sha256sum and a
# package manager - nothing else. bash, git and a GitHub account are all
# things a server should not need in order to install software.
#
# Reads, verifies, installs. It does not create a certificate authority, touch
# an existing server, or write any site configuration: those are decisions, and
# an installer should not be making them. See DEPLOY.md.
set -eu

REPO=${REPO:-arunasp/webmin-openvpn}
# Overridable so the installer can be exercised against a local directory
# rather than only against a live release.
BASE_URL=${BASE_URL:-}
TAG=${TAG:-}
PREFIX=${PREFIX:-/usr/sbin}
KEEP=${KEEP:-0}

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for cmd in curl sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
done

# Writability rather than uid: that is the condition that actually matters,
# and it lets the installer be exercised against a scratch prefix.
[ -d "$PREFIX" ] || die "$PREFIX does not exist"
[ -w "$PREFIX" ] || die "$PREFIX is not writable - run as root"

if [ -z "$BASE_URL" ]; then
    [ -n "$TAG" ] || die "set TAG to the release to install, for example TAG=v1.0.42"
    BASE_URL="https://github.com/$REPO/releases/download/$TAG"
fi

work=$(mktemp -d)
[ "$KEEP" = 1 ] || trap 'rm -rf "$work"' EXIT
cd "$work"

say "== fetching from $BASE_URL"
# -f so a missing asset is an error rather than a saved error page, which
# would otherwise be installed as though it were a program.
curl -fsSLO "$BASE_URL/SHA256SUMS" || die "no SHA256SUMS at $BASE_URL"

# Take the file list from SHA256SUMS itself: it is the release's own statement
# of what it contains, so this needs no update when an asset is added.
files=$(awk '{ print $2 }' SHA256SUMS)
[ -n "$files" ] || die "SHA256SUMS lists no files"

for f in $files; do
    say "   $f"
    curl -fsSLO "$BASE_URL/$f" || die "could not fetch $f"
done

say
say "== verifying"
sha256sum -c SHA256SUMS || die "checksum mismatch - nothing has been installed"

say
say "== installing the tools into $PREFIX"
for t in vpn-client vpn-server; do
    [ -f "$t" ] || die "$t is not in this release"
    # Ownership is only forced when this is running as root; a scratch
    # prefix under an ordinary account should still end up executable.
    if [ "$(id -u)" -eq 0 ]; then
        install -o root -g root -m 0755 "$t" "$PREFIX/$t"
    else
        install -m 0755 "$t" "$PREFIX/$t"
    fi
    say "   $PREFIX/$t"
done

deb=$(find . -maxdepth 1 -name "*.deb" | head -1)
if [ -n "$deb" ]; then
    say
    say "A package of the same tools is in this release: $deb"
    say "If you would rather have them tracked by the package manager, remove"
    say "the two files above and install it instead:"
    say "    apt install $deb"
fi

module=$(find . -maxdepth 1 -name "*.wbm.gz" | head -1)
say
say "== the Webmin module"
if [ -n "$module" ]; then
    say "Install it through Webmin, which can fetch it directly:"
    say "    Webmin Configuration -> Webmin Modules -> Install Module"
    say "    -> From ftp or http URL"
    say "    $BASE_URL/${module#./}"
else
    say "This release contains no module package."
fi

say
say "== before this does anything useful"
say "Create /etc/default/vpn-tools with at least REMOTE_HOST, and SERVER_UNIT"
say "if this host does not use openvpn-server@server. Then:"
say "    vpn-server status"
say "    vpn-client list"
say "Upgrading an existing install? Reissue the profiles: vpn-client regen --all"
