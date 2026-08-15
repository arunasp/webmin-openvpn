# Webmin OpenVPN, rebuilt for easy-rsa 3

A Webmin module and two shell tools for running an OpenVPN server whose PKI is
**easy-rsa 3 with EC keys**.

## Why not the existing module

The Webmin OpenVPN module in wide circulation (`openvpn/` here, vendored for
reference) was last touched in 2021. Its `openvpn-lib.pl` is a self-contained
certificate authority built on raw `openssl` shell-outs across 27 call sites,
RSA only, with configuration defaults naming OpenVPN 2.0-rc and OpenSSL 0.9.7,
and 177 hard-coded references to a directory layout of its own. It also drives
`openvpn@NAME`, while current Debian and Ubuntu ship `openvpn-server@NAME`.

The Webmin API it uses is *not* the problem: every UI function it calls still
exists in Webmin 2.6. What is obsolete is precisely the part that would be
unique to it - the PKI engine. So this is a fresh module rather than a fork,
and it looks familiar because the look comes from Webmin's own widgets.

## Shape

    tools/vpn-client    client lifecycle: list, add, revoke, show, regen
    tools/vpn-server    server side: status, show-config, apply-config, set-port
    openvpn-server/        the Webmin module (in progress)
    tests/              fixture-backed suite, no real PKI required
    openvpn/            the legacy module, reference only - do not build on it

The module is deliberately thin. It renders `vpn-client list --json` and calls
the tools for everything else, so every path the UI can take is a path that can
be taken, and tested, from a shell. Anything the UI needs that the tools cannot
do is added to the tools.

## Design decisions worth knowing

**The listening port is one operation, not an editable field.** It appears in
`server.conf`, in the UPnP mapping, and in the `remote` line of every issued
profile. Changing one leaves a server that starts cleanly, reports itself
healthy, and is unreachable from every existing client. `vpn-server set-port`
changes all of them or none.

**A config is validated by starting the server, not by parsing it.** OpenVPN
has no dry-run mode, so `apply-config` backs up, installs, restarts, asks
systemd whether the unit came up, and restores the backup if it did not.

**Revocation restarts the server.** `openvpn-server@.service` has no
`ExecReload`, so `reload-or-restart` is a restart: every session drops, not
only the revoked one. The tool says so rather than implying otherwise.

**No site identity in the repository.** Host names, networks and paths live in
`/etc/default/vpn-tools` on the target machine. See `DEPLOY.md`. `make scan`
fails the pipeline on any address outside a short declared list, any real host
name, a local filesystem path, or key material. Private addresses are not
exempt: RFC 1918 space describes the topology of a specific site just as
surely as a public address does.

## Running the pipeline

    make help     # targets
    make lint     # the leak scan, ShellCheck, and perl -c
    make test     # the suite, against a throwaway PKI
    make all

The suite builds a real EC PKI in a temporary directory, so certificate
handling is exercised against real certificates. Only what cannot exist in a
container is faked: `easyrsa`, `systemctl`, and `id`. Mocking `id` is what
keeps the results identical whether the suite runs as root or unprivileged.
