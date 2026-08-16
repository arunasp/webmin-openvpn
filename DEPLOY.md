# Deploying

The pipeline stops at `make all`. Installation happens on the target host,
because it needs credentials and privileges no CI worker has, and pretending
otherwise would make `make deploy` a target that can only ever be run by hand.

## Site identity

**Nothing in this repository names a real host, network or client.** The
defaults in `tools/vpn-client` and `tools/vpn-server` are placeholders. Real
values live in one file on the target host:

    /etc/default/vpn-tools     root:root, 0600

It is sourced by both tools when readable, before their own defaults apply.
It is a shell fragment, so quote anything with spaces:

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
    VPN_CLIENT=/usr/local/sbin/vpn-client

Only `REMOTE_HOST` has no sensible default. Everything else matches a stock
easy-rsa 3 layout on Debian or Ubuntu. The server's own certificate name is
derived from the `cert` directive in `server.conf`, so it needs no setting;
`SERVER_CN` overrides that derivation if a site needs it to.

`SERVER_UNIT` matters more than it looks. Distributions ship both
`openvpn@NAME` and `openvpn-server@NAME`; the tools restart whichever is
named here, and naming the wrong one produces a revocation that reports
success while the revoked client stays connected.

## Requirements

- **easy-rsa 3.1 or newer.** 3.0.x prompts for a PEM passphrase even when told
  `nopass`, so it cannot be driven unattended; the tools fail immediately
  against it rather than hanging. Verified against 3.1.7 and 3.2.6.
- **OpenVPN 2.4 or newer**, for either `--genkey secret` or `--genkey
  --secret`; the tools detect which form is understood.
- On Debian and Ubuntu both are packages: `apt install openvpn easy-rsa`.
  `vpn-server init` builds its own CA directory, so `make-cadir` is not
  needed beforehand.

## Installing the tools

    install -o root -g root -m 0755 tools/vpn-client  /usr/local/sbin/vpn-client
    install -o root -g root -m 0755 tools/vpn-server  /usr/local/sbin/vpn-server

Then confirm against the real site, in this order, before trusting anything:

    vpn-server status          # unit state, port, connections
    vpn-client list            # the same clients the PKI knows about
    vpn-client list --json     # parses, and agrees with the table

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

## What is not automated

- **Installing the Webmin module.** It is copied to `/usr/share/webmin/` and
  Webmin is restarted; there is no packaging step yet.
- **Removing any Custom Commands** that call `vpn-client` directly. They
  duplicate the module once it is installed.
- **Verification in a browser.** Webmin refuses to run its library-dependent
  Perl from outside `/usr/share/webmin` and needs `WEBMIN_CONFIG` set, so
  shell-side validation of module config does not work. Check it in the UI.
