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
the module as well as in the tools - two cheap checks in different places beat
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

## An existing authority is adopted, not replaced

A CA in another layout is in the wrong shape, not wrong. Rebuilding it
invalidates every certificate ever issued from it: every client needs a new
profile installed by hand, on every device, before it can connect again.
For a site with a handful of clients that is an afternoon; for one with
fifty it is a reason never to migrate.

So `import-ca` copies the CA key, the issued certificates, the keys and the
revocation list into the layout these tools expect, and `regen --all`
rebuilds the profiles around the certificates that already exist. Nothing is
reissued and no client is disturbed.

Two properties make it safe to run against a directory somebody depends on.
The source is only read, so a failed import costs nothing. And the new PKI
is assembled beside the target, verified certificate by certificate against
the CA, and moved into place only if all of them belong to it - a directory
holding certificates from two authorities looks fine until a client is
refused for a reason nobody can see.

The revocation list is copied rather than regenerated. Regenerating would
produce an equivalent file with a later nextUpdate, which quietly extends
how long the server trusts a list it was given rather than preserving what
was there.

## The configuration locks down once it works

What makes editing `server.conf` from a browser dangerous is losing a VPN
that people are using. That danger does not exist before the server runs,
and that is exactly when editing is needed: a first configuration that will
not start has to be fixable from the same place it was written.

So the server page follows the state. While the daemon is down it offers the
configuration for replacement, through `vpn-server apply-config` - which
backs up, installs, restarts, and puts the old file back if the server
refuses to come up. Once the daemon is up the same page shows the file and
nothing more, and `set-port` remains the guarded way to change the setting
anyone actually changes.

The check is on the server side, not only in the page that links to it. A
form submitted from a tab left open before the server started would
otherwise arrive after it, which is the moment the restriction exists for.

## Elliptic curve by default, recorded where it survives

easy-rsa defaults to RSA 2048. `vpn-server init` writes `EASYRSA_ALGO` and
`EASYRSA_CURVE` into the CA directory's `vars` file rather than only exporting
them for its own run, so every later invocation inherits the setting - from
`vpn-client`, or from an administrator running `./easyrsa` by hand. The
algorithm is then a property of the CA directory rather than of whoever
happened to create it.

`init` also gives the CA directory the shape `make-cadir` produces: the
`easyrsa` entry point and `x509-types` symlinked in, `openssl-easyrsa.cnf`
copied. Without that, `vpn-client` cannot run `./easyrsa` and the server can
issue nothing - a server that builds cleanly and is useless.

## The listener takes both address families

`proto udp` binds one family, in practice IPv4, and OpenVPN says so in its
own log: "Could not determine IPv4/IPv6 protocol. Using AF_INET". A phone on
an IPv6-only mobile network cannot reach that except through whatever
translation its carrier provides, which is not a property to leave to chance
in software whose clients are phones.

`udp6` opens a dual-stacked socket that accepts both: an AF_INET6 socket with
`IPV6_V6ONLY` unset receives IPv4 datagrams as `::ffff:` addresses. `init`
detects rather than assumes, because a host with IPv6 disabled in the kernel
cannot bind `udp6` at all and the server would fail to start.

The client profile keeps the plain form. `udp6` in a client configuration
forces the client onto IPv6 and fails wherever there is none; the profile
names the transport and lets the client choose the family from DNS.

## The tools are found, not configured

The package installs into `/usr/sbin`, because Debian policy reserves
`/usr/local` for the administrator. A manual install conventionally uses
`/usr/local/sbin`. Either would otherwise require correcting the module
configuration after the fact, so the module takes the configured path when it
exists and searches the usual directories when it does not.

`vpn-server` does the same for the `vpn-client` it calls, preferring the copy
beside itself. The two ship together, and hardcoding either location meant
`set-port` skipped regenerating profiles on the other - after it had already
changed the port those profiles name.

## Site identity lives on the server

No host name, network, path or key material belonging to a live installation
appears in this repository. The tools read `/etc/default/vpn-tools` when it is
readable; the defaults in the code are RFC 2606 documentation placeholders.

This is enforced by `make scan` rather than left to discipline, and extended to
every unpushed commit by `make preflight`. Its limits are documented in
[CONTRIBUTING.md](../CONTRIBUTING.md#repository-hygiene).

## What the checks can and cannot prove

The suite runs against a fixture site with an EC PKI, so certificate
handling is exercised against certificates openssl produced. What it cannot establish is
how the genuine dependencies behave: a fake that is handed its answers by the
fixture proves nothing about the tool it stands in for.

That gap is covered separately, by four stages that each remove one kind of
pretending:

- `make e2e` runs `init` against an easy-rsa checkout, across several releases.
- `make apicheck` verifies every Webmin function the module calls against the
  Webmin release being targeted.
- `make e2e-tunnel` builds a server, connects a client through it, revokes that
  client and confirms it is refused. Nothing above it establishes that a
  profile works or that revocation has any effect on a running server.
- `make e2e-webmin` installs the package into Webmin and drives the module over
  HTTP. It is the only stage that can tell whether a page renders, and the
  first time it ran by hand it found JSON that broke the server panel whenever
  nobody was connected.
