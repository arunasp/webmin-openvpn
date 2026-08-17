# webmin-openvpn-server

A Webmin module for managing an OpenVPN server whose certificate authority is
[easy-rsa 3](https://github.com/OpenVPN/easy-rsa), together with the two shell
tools it drives.

From the Webmin interface the module issues client profiles and hands them
over with per-platform installation notes, revokes them behind a
confirmation that says what revocation costs, reports server status, and
changes the listening port through the one operation that keeps the port
consistent everywhere it appears. While the server is down it can also
replace the configuration.

The tools go further than the interface does: `vpn-server init` builds a
server from nothing on a host that has only `openvpn` and `easy-rsa`
installed. That one is a shell command, not a page.

## Why this exists

The OpenVPN modules in circulation for Webmin embed their own certificate
authority, built on `openssl` invocations and RSA keys, and drive systemd units
named `openvpn@NAME`. Current Debian and Ubuntu releases ship
`openvpn-server@NAME`, and a PKI created by easy-rsa 3 with elliptic-curve keys
is not a layout those modules recognise: they either fail to see the
certificates or rewrite them into a form the server rejects.

Webmin's own interface API is not the obsolete part - every `ui_*` function
those modules call still exists in Webmin 2.6. What is obsolete is the PKI
engine, so this module replaces that and keeps the presentation layer thin.

## Requirements

| Component | Version | Notes |
| --- | --- | --- |
| Webmin | 2.6 or newer | verified against 2.653 |
| easy-rsa | 3.1 or newer | 3.0.x prompts for a passphrase despite `nopass` and cannot run unattended |
| OpenVPN | 2.4 or newer | both `--genkey secret` and `--genkey --secret` are supported |
| Perl | 5.36 or newer | `JSON::PP` and `IPC::Open3` are core modules |

On Debian and Ubuntu the dependencies are packaged:

```sh
apt install openvpn easy-rsa
```

## Installation

Download the packaged module from a release and check it - no git or GitHub
CLI needed on the target:

```sh
REL=https://github.com/arunasp/webmin-openvpn/releases/download/vX.Y.Z
curl -fsSLO $REL/openvpn-server-X.Y.Z.wbm.gz
curl -fsSLO $REL/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
```

Webmin can also fetch it directly, under **Install Module -> From ftp or
http URL**.

Install it through **Webmin → Webmin Configuration → Webmin Modules → Install
Module → From uploaded file**.

`make build` produces the same package from a checkout, for development. A
server should run a released artifact rather than a working copy - see
[DEPLOY.md](DEPLOY.md).

Client installation for Windows, Android, iOS, macOS and Linux is covered in
[docs/clients.md](docs/clients.md).

Install the two shell tools the module calls:

```sh
install -o root -g root -m 0755 tools/vpn-client /usr/local/sbin/vpn-client
install -o root -g root -m 0755 tools/vpn-server /usr/local/sbin/vpn-server
```

Create `/etc/default/vpn-tools` describing the site, then confirm the tools see
the server. Both steps are covered in [DEPLOY.md](DEPLOY.md).

## Usage

### Creating a server

On a host with no OpenVPN configuration:

```sh
vpn-server init --host vpn.example.com \
    --push "192.168.50.0 255.255.255.0" --dns 192.168.50.1
```

This builds the CA, issues the server certificate, generates the `tls-crypt`
key, writes `server.conf` and `/etc/default/vpn-tools`, and enables the unit.
It refuses to touch an existing server: replacing a CA invalidates every
profile ever issued from it, so that has to be a deliberate act.

### Managing clients

```sh
vpn-client list                 # names, states, expiry, who is connected
vpn-client list --json          # the same data as JSON, which the module reads
vpn-client add laptop           # new certificate and a ready-to-use profile
vpn-client show laptop          # print the profile
vpn-client revoke laptop        # revoke, refresh the CRL, remove the profile
vpn-client regen --all          # rebuild profiles from existing certificates
```

Profiles are written to `/etc/openvpn/clients/<name>.ovpn`, mode `0600`, with
the CA, certificate, private key and `tls-crypt` key inlined so a device can
import a single file.

### Changing the listening port

```sh
vpn-server set-port 1195 udp
```

The port appears in `server.conf`, in the UPnP mapping, and in the `remote`
line of every issued profile. Editing only the first leaves a server that
starts cleanly, reports itself healthy, and is unreachable from every existing
client - so this is one operation that updates all three, regenerates the
profiles, and rolls everything back if the server does not restart.

## Configuration

The module reads three settings, editable through Webmin's module
configuration page:

| Setting | Default |
| --- | --- |
| `vpn_client` | `/usr/local/sbin/vpn-client` |
| `vpn_server` | `/usr/local/sbin/vpn-server` |
| `clients_dir` | `/etc/openvpn/clients` |

The tool paths are a starting point rather than a requirement. If the
configured path does not exist, the module looks in `/usr/sbin`,
`/usr/local/sbin`, `/sbin` and `/usr/bin` for a tool of that name - so the
package, which installs into `/usr/sbin`, and a manual install into
`/usr/local/sbin` both work without editing anything here. Set the path
explicitly if the tools live somewhere else, or if both locations have a
copy and you need to say which one runs.

Host names, paths and unit names live in `/etc/default/vpn-tools` on the
server, never in this repository. See [DEPLOY.md](DEPLOY.md) for the full list.

## Repository layout

```
openvpn-server/   the Webmin module
tools/            vpn-client and vpn-server
tests/            test suite, fixtures, container images, repository checks
packaging/        the .deb control file and the release installer
docs/             design notes and client installation
VERSION           major.minor; CI adds the build number
openvpn/          the legacy third-party module, kept for reference only
```

## Development

```sh
make help         # every target, with a description
make all          # everything that needs no network
make e2e          # adds the stages that clone Webmin and easy-rsa
make e2e-tunnel   # a server, a client and a revoked certificate
make e2e-webmin   # the module driven over HTTP in an installed Webmin
make preflight    # what must pass before pushing
```

The last two need a container engine. [CONTRIBUTING.md](CONTRIBUTING.md)
describes the stages, the coding standards and how the test doubles are
used.

## Licence

This repository does not currently carry a licence file. The `openvpn/`
directory contains a third-party module marked `Copyright: Open It S.r.l.`,
retained for reference; its terms are not restated here. The licence for the
remaining code has not been declared, and one should be added before the
project is relied on by anyone else.
