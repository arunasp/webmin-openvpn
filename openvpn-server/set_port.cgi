#!/usr/bin/perl

# Change the listening port.
#
# Everything that makes this safe is in vpn-server set-port: it updates
# server.conf, the UPnP mapping and every issued profile, restarts the
# server, and puts all of it back if the server does not come up. This page
# validates the two fields and reports what the tool said.
#
# It can take a while - every profile is regenerated - and it restarts the
# server, so every connected client is dropped. The confirmation says so.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %in, %config);

&ReadParse();
&error_setup($text{'setport_err'});

my $port = $in{'port'};
my $proto = $in{'proto'};

$port =~ /^\d+$/ && $port >= 1 && $port <= 65535 ||
    &error(&text('setport_eport', &html_escape($port || '')));
$proto =~ /^(udp|tcp|udp6|tcp6)$/ ||
    &error(&text('setport_eproto', &html_escape($proto || '')));

if (!$in{'confirm'}) {
	&ui_print_header(undef, $text{'setport_title'}, "", "server", 1, 1);
	print &ui_confirmation_form("set_port.cgi",
		"<b>".&text('setport_warn', $port, $proto)."</b><br>".
		$text{'setport_sessions'}."<br>".
		$text{'setport_rollback'},
		[ [ "port", $port ], [ "proto", $proto ] ],
		[ [ "confirm", $text{'setport_button'} ] ]);
	&ui_print_footer("server.cgi", $text{'srvpage_return'},
			 "/", $text{'index_return'});
	exit;
	}

my $r = &run_tool(&tool_path($config{'vpn_server'}), 'set-port', $port, $proto);
if ($r->{'status'} != 0) {
	my $msg = $r->{'err'} || $r->{'out'} || "exit status $r->{'status'}";
	$msg =~ s/\s+$//;
	&error(&html_escape($msg));
	}

&webmin_log("set-port", "server", "$port/$proto");
&redirect("server.cgi");
