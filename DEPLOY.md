# Deployment

CI builds, checks and publishes a release. Installation happens on the target
server, because it needs credentials and privileges no CI runner has; a
`deploy` target that can only ever be run by hand would be a pretence.

## Requirements

- **easy-rsa 3.1 or newer.** 3.0.x prompts for a PEM passphrase even when told
  `nopass`, so it cannot be driven unattended; the tools fail immediately
  against it rather than hanging. Verified against 3.1.7 and 3.2.6.
- **OpenVPN 2.4 or newer**, for either `--genkey secret` or
  `--genkey --secret`; the tools detect which form is understood.
- On Debian and Ubuntu both are packages: `apt install openvpn easy-rsa`.
  `vpn-server init` builds its own CA directory, so `make-cadir` is not needed
  beforehand.

## Site identity

**Nothing in this repository names a live host, network or client.** The
defaults in `tools/vpn-client` and `tools/vpn-server` are placeholders. Site
values live in one file on the target server:

    /etc/default/vpn-tools     root:root, 0600

It is sourced by both tools when readable, before their own defaults apply. It
is a shell fragment, so quote anything containing spaces:

    REMOTE_HOST=vpn.example.com   # the name clients dial; a DDNS name is fine
    REMOTE_PORT=1194              # only as a fallback: the live value is read
    REMOTE_PROTO=udp              # from server.conf when that is readable
    EASYRSA_DIR=/etc/openvpn/easyrsa
    CLIENT_DIR=/etc/openvpn/clients
    SERVER_DIR=/etc/openvpn/server
    STATUS_FILE=/var/log/openvpn/status.log
    SERVER_UNIT=openvpn-server@server
    UPNP_UNIT=upnp-port-forward.service
    UPNP_DEFAULTS=/etc/default/upnp-port-forward
    VPN_CLIENT=/usr/local/sbin/vpn-client   # only if the tools are somewhere unusual

Only `REMOTE_HOST` has no sensible default. Everything else matches a stock
easy-rsa 3 layout on Debian or Ubuntu. The server's own certificate name is
derived from the `cert` directive in `server.conf`, so it needs no setting;
`SERVER_CN` overrides that derivation where a site needs it to.

`SERVER_UNIT` matters more than it appears to. Distributions ship both
`openvpn@NAME` and `openvpn-server@NAME`; the tools restart whichever is named
here, and naming the wrong one produces a revocation that reports success while
the revoked client stays connected.

## What gets deployed

A server runs released code, never a working copy. Releases are produced by
CI from `main` after every stage has passed, tagged `vMAJOR.MINOR.BUILD`, and
published with everything a server installs: the packaged module, a `.deb` of
the tools, both tools as plain files, the installer, and a `SHA256SUMS`
covering all of them.

Nothing on a server should come from a development branch. A checkout is for
building and testing; what a server installs is an artifact somebody can
point at, verify and reinstall identically later. The build is reproducible,
so the checksum is the whole guarantee: the same tag produces the same bytes.

The assets are plain files behind plain URLs. A server needs no git, no
GitHub CLI and no account. There are three ways in; pick one.

### The installer

Fetches every asset, verifies all of them against `SHA256SUMS`, installs the
tools and prints the URL to hand Webmin for the module:

```sh
REL=https://github.com/arunasp/webmin-openvpn/releases/download/vX.Y.Z
curl -fsSLO $REL/install.sh
curl -fsSLO $REL/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS   # check the installer first
sudo TAG=vX.Y.Z sh install.sh
```

Verify before running, rather than piping a URL into a shell. The installer
installs files and stops there. It creates no certificate authority, writes
no server configuration, and makes no decisions of its own.

### The package

On Debian or Ubuntu, the tools are also a `.deb`, which gives dependency
checking on openvpn and easy-rsa and a clean removal:

```sh
curl -fsSLO $REL/openvpn-server-tools_X.Y.Z_all.deb
curl -fsSLO $REL/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
sudo apt install ./openvpn-server-tools_X.Y.Z_all.deb
```

It installs into `/usr/sbin`, because Debian policy reserves `/usr/local`
for the administrator. The module looks in both, so nothing needs
reconfiguring either way. `apt remove openvpn-server-tools` takes it back
out; a certificate authority it created is left alone, as it should be.

### By hand

```sh
curl -fsSLO $REL/vpn-client
curl -fsSLO $REL/vpn-server
curl -fsSLO $REL/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
```

Then install them as below. `curl -f` matters in all three: without it a
missing asset is saved as an error page and installed as though it were a
program.

## Installing the tools

    install -o root -g root -m 0755 vpn-client /usr/local/sbin/vpn-client
    install -o root -g root -m 0755 vpn-server /usr/local/sbin/vpn-server

`vpn-server` calls the `vpn-client` installed beside it, so both belong in the
same directory. Then confirm against the installed site, in this order, before
trusting anything:

    vpn-server status          # unit state, port, connections
    vpn-client list            # the same clients the PKI knows about
    vpn-client list --json     # parses, and agrees with the table

## Installing the module

Webmin can fetch the package itself, which saves downloading it twice:
**Webmin Configuration -> Webmin Modules -> Install Module -> From ftp or
http URL**, given the release asset URL. Verify the checksum first if the
file is downloaded by hand instead.

Or install the downloaded and verified `openvpn-server-<version>.wbm.gz` through **Webmin
→ Webmin Configuration → Webmin Modules → Install Module → From uploaded
file**, then open **Servers → OpenVPN**.

Verifying in a browser is not optional. Webmin refuses to run its
library-dependent Perl from outside its own directory and requires
`WEBMIN_CONFIG` to be set, so module configuration cannot be validated from a
shell. `make apicheck` proves the functions the module calls exist in the
target Webmin release; only the browser proves the page renders.

## Creating a server

On a host with no OpenVPN configuration:

    vpn-server init --host vpn.example.com \
        --push "192.168.50.0 255.255.255.0" --dns 192.168.50.1

`init` refuses to touch an existing server. A PKI is not reproducible: every
profile ever issued from it stops verifying the moment the CA is replaced, so
starting over has to be a deliberate act with the old directory removed by
hand.

Two things `init` does not do, and which remain manual: opening the listening
port inbound, and enabling IP forwarding if clients should reach anything
beyond the server itself.

## Upgrading an existing installation

`vpn-client` reads the listening port from `server.conf` rather than carrying
its own copy. Profiles issued by an older version may name a port that is no
longer correct, so after installing:

    vpn-client regen --all

This rewrites every valid client's profile from its existing certificate. It
issues nothing and revokes nothing, so it is safe to run at any time; revoked
and expired clients are skipped.

## Changing the listening port

Use the operation, not an editor:

    vpn-server set-port 1195 udp

It updates `server.conf`, the UPnP mapping in `/etc/default/upnp-port-forward`
and every issued profile, restarts the server, and restores all of it if the
server does not come back up. Editing `server.conf` by hand leaves a server
that starts cleanly and is unreachable from every existing client.

## Removing duplicate entry points

Where Webmin Custom Commands already call `vpn-client`, delete them once the
module is installed. Two interfaces to the same operation drift, and the one
nobody is looking at drifts first.
