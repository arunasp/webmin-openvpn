# Design notes

Why this module is built the way it is. Operational instructions are in
[DEPLOY.md](../DEPLOY.md); development workflow is in
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Replacing the PKI engine, not the interface

The third-party Webmin OpenVPN module kept in `openvpn/` for reference was last
updated in 2021. Its library is a self-contained certificate authority built on
raw `openssl` invocations across 27 call sites, RSA only, with configuration
defaults naming OpenVPN 2.0-rc and OpenSSL 0.9.7, and 177 references to a
directory layout of its own. It drives `openvpn@NAME`, while current Debian and
Ubuntu ship `openvpn-server@NAME`.

Every `ui_*` function it calls still exists in Webmin 2.6, so the interface API
is not what aged. The PKI engine is. This module therefore replaces that part
and leaves presentation to Webmin's own widgets, which is also why it looks
like the rest of Webmin without imitating anything.

## The module holds no logic

`index.cgi` renders `vpn-client list --json` and `vpn-server status --json`.
Nothing in the module reads the PKI directly. Anything that changes state is a
call to one of the tools.

The consequence worth having: every path the interface can take is a path that
can be taken from a shell, so it can be covered by a suite that needs no web
server, no browser and no Webmin installation.

Tools are invoked in list form through `IPC::Open3`. No shell is involved, so a
form field is a single argument whatever it contains. Names are validated in
the module as well as in the tools — two cheap checks in different places beat
one clever one.

## The listening port is an operation, not a field

The port appears in three places that must agree: `server.conf`, the UPnP
mapping in `/etc/default/upnp-port-forward`, and the `remote` line inside every
issued `.ovpn` profile. Changing one of them produces a server that starts
cleanly, reports itself healthy, and is unreachable from every existing client.

`vpn-server set-port` therefore updates all three or none, regenerates the
profiles once the new configuration is proven to run, and restores everything
if it does not.

`vpn-server init` takes the port as an ordinary option, which is not an
exception to this rule. At creation there are no copies of the port anywhere,
so one option decides all of them at once. The invariant is the same; only the
situation differs.

## Configuration is validated by starting the server

OpenVPN has no dry-run mode. A configuration parser here would be a second,
weaker opinion about what the daemon accepts, so `apply-config` backs up the
current configuration, installs the candidate, restarts the unit, asks systemd
whether it came up, and restores the backup when it did not.

This is safe because the server is administered over SSH rather than through
the tunnel: a refused configuration costs the VPN, not access to the machine.

## Revocation restarts the server

`openvpn-server@.service` defines no `ExecReload`, so `systemctl
reload-or-restart` is a restart. Every session drops, not only the revoked
one. The tool says so plainly rather than implying otherwise, because an
operator who believes only one client was affected will be wrong at the worst
possible moment.

## Elliptic curve by default, recorded where it survives

easy-rsa defaults to RSA 2048. `vpn-server init` writes `EASYRSA_ALGO` and
`EASYRSA_CURVE` into the CA directory's `vars` file rather than only exporting
them for its own run, so every later invocation inherits the setting — from
`vpn-client`, or from an administrator running `./easyrsa` by hand. The
algorithm is then a property of the CA directory rather than of whoever
happened to create it.

`init` also gives the CA directory the shape `make-cadir` produces: the
`easyrsa` entry point and `x509-types` symlinked in, `openssl-easyrsa.cnf`
copied. Without that, `vpn-client` cannot run `./easyrsa` and the server can
issue nothing — a server that builds cleanly and is useless.

## Site identity lives on the server

No host name, network, path or key material belonging to a real installation
appears in this repository. The tools read `/etc/default/vpn-tools` when it is
readable; the defaults in the code are RFC 2606 documentation placeholders.

This is enforced by `make scan` rather than left to discipline, and extended to
every unpushed commit by `make preflight`. Its limits are documented in
[CONTRIBUTING.md](../CONTRIBUTING.md#repository-hygiene).

## What the checks can and cannot prove

The suite runs against a fixture site with a real EC PKI, so certificate
handling is exercised against real certificates. What it cannot establish is
how the genuine dependencies behave: a fake that is handed its answers by the
fixture proves nothing about the tool it stands in for.

That gap is covered separately. `make e2e` runs `init` against a real easy-rsa
checkout across several releases, and `make apicheck` verifies every Webmin
function the module calls against the Webmin release being targeted. Neither
proves a page renders, which remains a browser's job.
