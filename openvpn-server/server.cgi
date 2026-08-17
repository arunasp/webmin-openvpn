#!/usr/bin/perl

# The server side: what it is doing, what it is configured with, and the one
# configuration change that is safe to make from a form.
#
# Only the listening port is editable here. It is the setting an operator
# actually changes, and the only one where doing it by hand breaks something
# invisible: the port lives in server.conf, in the UPnP mapping and in the
# remote line of every issued profile, and changing one leaves a server that
# starts cleanly and is unreachable from every existing client. vpn-server
# set-port changes all of them or none.
#
# The rest of the configuration is editable only while the server is down.
# What makes a textarea over server.conf dangerous is losing a VPN people are
# using; before it runs there is nothing to lose, and a first configuration
# that will not start has to be fixable from the same place it was created.
# Once the daemon is up the page shows the file and stops offering to replace
# it, and set-port remains the guarded way to change the setting anyone
# actually changes.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %in, %config);

&ui_print_header(undef, $text{'srvpage_title'}, "", "server", 1, 1);

my ($server, $err) = &server_status();
if ($err) {
	print &ui_alert_box(&text('index_toolerr',
				  &tool_path($config{'vpn_server'}), $err),
			    'danger');
	&ui_print_footer("", $text{'index_return2'}, "/", $text{'index_return'});
	exit;
	}

my $state = $server->{'active'} eq 'active' ? $text{'srv_active'}
					    : $text{'srv_inactive'};

print &ui_table_start($text{'index_server'}, "width=100%", 2);
print &ui_table_row($text{'srv_unit'}, "$server->{'unit'} ($state)");
print &ui_table_row($text{'srv_listen'},
		    "$server->{'port'}/$server->{'proto'}");
print &ui_table_row($text{'srv_clients'}, $server->{'connected'});
print &ui_table_row($text{'srv_crl'}, $server->{'crl_next_update'} || '-');
print &ui_table_row($text{'srvpage_config'}, "<tt>$server->{'config'}</tt>");
print &ui_table_end();

print "<p><a href='settings.cgi'>$text{'srvpage_settings'}</a></p>\n";

print &ui_hr();
print "<h3>$text{'srvpage_port'}</h3>\n";
print "<p>$text{'srvpage_portwhy'}</p>\n";

print &ui_form_start("set_port.cgi", "post");
print &ui_table_start($text{'srvpage_portform'}, "width=100%", 2);
print &ui_table_row($text{'srvpage_portnum'},
		    &ui_textbox("port", $server->{'port'}, 6));
# udp6 and tcp6 accept both address families; the plain forms bind one. The
# profile always names the plain form, whichever is chosen here.
print &ui_table_row($text{'srvpage_proto'},
		    &ui_select("proto", $server->{'proto'},
			       [ [ "udp6", "udp6" ], [ "udp", "udp" ],
				 [ "tcp6", "tcp6" ], [ "tcp", "tcp" ] ]));
print &ui_table_end();
print &ui_form_end([ [ undef, $text{'srvpage_portbutton'} ] ]);

print &ui_hr();
print "<h3>$text{'srvpage_show'}</h3>\n";

my $r = &run_tool(&tool_path($config{'vpn_server'}), 'show-config');
if ($r->{'status'} != 0) {
	my $msg = $r->{'err'} || "exit status $r->{'status'}";
	$msg =~ s/\s+$//;
	print &ui_alert_box(&html_escape($msg), 'warn');
	}
elsif ($server->{'active'} eq 'active') {
	# Running, and clients may be on it: show, do not offer to replace.
	print "<pre>".&html_escape($r->{'out'})."</pre>\n";
	print "<p>$text{'srvpage_showwhy'}</p>\n";
	}
else {
	# Down: editing costs nothing that is not already lost, and a first
	# configuration that will not start has to be fixable from here.
	print "<p>$text{'srvpage_editwhy'}</p>\n";
	print &ui_form_start("apply_config.cgi", "post");
	print &ui_textarea("config", $r->{'out'}, 20, 80);
	print &ui_form_end([ [ undef, $text{'srvpage_applybutton'} ] ]);
	}

&ui_print_footer("", $text{'index_return2'}, "/", $text{'index_return'});
