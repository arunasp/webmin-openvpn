# RPM packaging for the two tools, plus the two optional ones.
#
# Built inside a Red Hat container, because rpmbuild is not present on the
# machines this repository is developed and tested on. That container is also
# the only place the tools meet a genuine Red Hat easy-rsa: the package there
# installs into /usr/share/easy-rsa/<version>/ with major symlinks beside it,
# a layout no Debian host reproduces.
#
# The version comes from the build rather than from this file, so a release
# stamps it the same way the deb does.

Name:           openvpn-server-tools
Version:        %{version}
Release:        1%{?dist}
Summary:        Command-line tools for an easy-rsa 3 OpenVPN server

License:        GPL-2.0-or-later
URL:            https://github.com/arunasp/webmin-openvpn
BuildArch:      noarch

Requires:       bash
Requires:       openvpn >= 2.4
Requires:       easy-rsa >= 3.1
Requires:       openssl
Recommends:     miniupnpc

%description
vpn-client manages the client lifecycle - list, add, revoke, show and
regenerate profiles - against an easy-rsa 3 certificate authority, issuing
unified .ovpn profiles that current OpenVPN clients import as a single file.

vpn-server owns the server side: status, configuration display, guarded
configuration changes that roll back if the daemon refuses them, and building
a server from nothing.

upnp-port-forward and vpn-extip are optional and inert unless configured: they
request an inbound port mapping from a router by UPnP and report the external
address for a dynamic DNS client. A site with a static address or a
hand-configured forward needs neither.

These are the tools the Webmin OpenVPN module drives. Installing them is
enough to manage a server from a shell; the module is installed through Webmin
itself.

%install
mkdir -p %{buildroot}%{_sbindir}
install -m 0755 %{_sourcedir}/vpn-client %{buildroot}%{_sbindir}/vpn-client
install -m 0755 %{_sourcedir}/vpn-server %{buildroot}%{_sbindir}/vpn-server
install -m 0755 %{_sourcedir}/upnp-port-forward %{buildroot}%{_sbindir}/upnp-port-forward
install -m 0755 %{_sourcedir}/vpn-extip %{buildroot}%{_sbindir}/vpn-extip

%files
%{_sbindir}/vpn-client
%{_sbindir}/vpn-server
%{_sbindir}/upnp-port-forward
%{_sbindir}/vpn-extip

%changelog
* Mon Aug 17 2026 openvpn-server-tools maintainers <noreply@users.noreply.github.com>
- Packaged from the repository; see the git history for changes.
