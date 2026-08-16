#!/usr/bin/perl

# Replace the server configuration, while the server is down.
#
# WHY THIS IS GATED ON STATE RATHER THAN FORBIDDEN: what makes editing
# server.conf from a browser dangerous is losing a VPN that people are
# currently using. Before the server runs there is nothing to lose, and
# editing is exactly what is needed - a first configuration that will not
# start has to be fixable from the same place it was created. Once the daemon
# is up and clients depend on it, the page stops offering this and set-port
# remains the guarded way to change the setting anyone actually changes.
#
# The state is checked here, not only in the page that links here. A form can
# be submitted after the server has come up, or from a stale tab.
#
# vpn-server apply-config does the work that makes this survivable: it backs
# up the current file, installs the candidate, restarts the unit, asks systemd
# whether it came up, and restores the backup when it did not. OpenVPN has no
# dry-run mode, so starting the daemon is the only opinion that counts.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %in, %config);

&ReadParse();
&error_setup($text{'apply_err'});

my ($server, $err) = &server_status();
$err && &error(&html_escape($err));
$server->{'active'} eq 'active' &&
    &error($text{'apply_erunning'});

my $body = $in{'config'};
defined($body) && $body =~ /\S/ || &error($text{'apply_eempty'});
$body =~ s/\r\n/\n/g;

# A configuration with no key material and no certificates is not one this
# tool can install: the daemon would start and refuse every client.
$body =~ /^\s*ca\s+\S/m || &error($text{'apply_eca'});

if (!$in{'confirm'}) {
	&ui_print_header(undef, $text{'apply_title'}, "", "server", 1, 1);
	print &ui_confirmation_form("apply_config.cgi",
		"<b>".$text{'apply_warn'}."</b><br>".$text{'apply_rollback'},
		[ [ "config", $body ], [ "confirm", 1 ] ],
		[ [ "confirm", $text{'apply_button'} ] ]);
	&ui_print_footer("server.cgi", $text{'srvpage_return'});
	exit;
	}

my $tmp = &transname("openvpn-server.conf");
open(my $fh, '>', $tmp) || &error($text{'apply_etmp'});
print $fh $body;
close($fh);

my $r = &run_tool(&tool_path($config{'vpn_server'}), 'apply-config', $tmp);
unlink($tmp);
if ($r->{'status'} != 0) {
	my $msg = $r->{'err'} || $r->{'out'} || "exit status $r->{'status'}";
	$msg =~ s/\s+$//;
	&error(&html_escape($msg));
	}

&webmin_log("apply-config", "server", undef);
&redirect("server.cgi");
