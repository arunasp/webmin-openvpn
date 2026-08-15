# Webmin calls this to decide whether the module has anything to manage. A
# non-zero return means "usable"; zero hides the module or marks it
# unavailable, depending on the theme.
#
# The test is the tools, not OpenVPN itself. This module drives a server
# through vpn-client and vpn-server, so a host with openvpn installed but
# without them has nothing this module can do. A host with the tools and no
# server yet is still worth showing: that is exactly what the setup page is
# for.

# Webmin loads this with do(), not as a program, and its own convention is a
# plain file: only 1 of the 69 install_check.pl files shipped with Webmin 2.653
# carries a shebang. Without one Perl::Critic treats the file as a module and
# asks for a package declaration, which would break how Webmin calls it.
## no critic (Modules::RequireExplicitPackage)

use strict;
use warnings;

our %config;

do 'openvpn-server-lib.pl';

sub is_installed
{
return -x $config{'vpn_client'} && -x $config{'vpn_server'} ? 2 : 0;
}

1;
