# webmin-openvpn-server

A Webmin module for managing an OpenVPN server whose certificate authority is
[easy-rsa 3](https://github.com/OpenVPN/easy-rsa), together with the two shell
tools it drives.

The module lists and issues client profiles, revokes them, and reports server
status from the Webmin interface. It can also build a server from nothing on a
host that has only `openvpn` and `easy-rsa` installed.

## Why this exists

The OpenVPN modules in circulation for Webmin embed their own certificate
authority, built on `openssl` invocations and RSA keys, and drive systemd units
named `openvpn@NAME`. Current Debian and Ubuntu releases ship
`openvpn-server@NAME`, and a PKI created by easy-rsa 3 with elliptic-curve keys
is not a layout those modules recognise: they either fail to see the
certificates or rewrite them into a form the server rejects.

Webmin's own interface API is not the obsolete part — every `ui_*` function
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

Build the module package, or download it from the workflow artifacts:

```sh
make build
```

This produces `build/openvpn-server-<version>.wbm.gz` and a matching
`.sha256`. Install it through **Webmin → Webmin Configuration → Webmin Modules
→ Install Module → From uploaded file**.

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
client — so this is one operation that updates all three, regenerates the
profiles, and rolls everything back if the server does not restart.

## Configuration

The module reads three settings, editable through Webmin's module
configuration page:

| Setting | Default |
| --- | --- |
| `vpn_client` | `/usr/local/sbin/vpn-client` |
| `vpn_server` | `/usr/local/sbin/vpn-server` |
| `clients_dir` | `/etc/openvpn/clients` |

Host names, paths and unit names live in `/etc/default/vpn-tools` on the
server, never in this repository. See [DEPLOY.md](DEPLOY.md) for the full list.

## Repository layout

```
openvpn-server/   the Webmin module
tools/            vpn-client and vpn-server
tests/            test suite, fixtures and repository checks
docs/             design notes
openvpn/          the legacy third-party module, kept for reference only
```

## Development

```sh
make help         # list targets
make all          # leak scan, lint, suite, package and verify
make e2e          # additionally test against real Webmin and easy-rsa
make preflight    # checks that must pass before pushing
```

[CONTRIBUTING.md](CONTRIBUTING.md) describes the stages, the coding standards
and how the test doubles are used.

## Licence

This repository does not currently carry a licence file. The `openvpn/`
directory contains a third-party module marked `Copyright: Open It S.r.l.`,
retained for reference; its terms are not restated here. The licence for the
remaining code has not been declared, and one should be added before the
project is relied on by anyone else.
