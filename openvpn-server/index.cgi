#!/usr/bin/perl

# The module's only listing page: what the server is doing, which clients
# exist, and a form to add one. Everything shown here comes from
# `vpn-client list --json` and `vpn-server status --json`; nothing on this
# page reads the PKI directly.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %config);

&ui_print_header(undef, $text{'index_title'}, "", "intro", 1, 1);

my ($server, $server_err) = &server_status();
if ($server_err) {
	print &ui_alert_box(&text('index_toolerr', &tool_path($config{'vpn_server'}),
				  $server_err), 'warn');
	}
else {
	my $state = $server->{'active'} eq 'active' ? $text{'srv_active'}
						    : $text{'srv_inactive'};
	print &ui_table_start($text{'index_server'}, "width=100%", 2);
	print &ui_table_row($text{'srv_unit'}, "$server->{'unit'} ($state)");
	print &ui_table_row($text{'srv_listen'},
			    "$server->{'port'}/$server->{'proto'}");
	print &ui_table_row($text{'srv_clients'}, $server->{'connected'});
	print &ui_table_row($text{'srv_crl'},
			    $server->{'crl_next_update'} || '-');
	print &ui_table_end();
	print "<p><a href='server.cgi'>$text{'index_server_link'}</a></p>\n";
	}

my ($data, $err) = &client_list();
if ($err) {
	print &ui_alert_box(&text('index_toolerr', &tool_path($config{'vpn_client'}), $err),
			    'danger');
	&ui_print_footer("/", $text{'index_return'});
	exit;
	}

my @clients = @{$data->{'clients'} || []};
print &ui_hr();
print "<h3>$text{'index_clients'}</h3>\n";

if (!@clients) {
	print "<p>$text{'index_none'}</p>\n";
	}
else {
	my @rows;
	foreach my $c (@clients) {
		my $name = $c->{'name'};
		my $state = $c->{'state'} eq 'valid'	? $text{'state_valid'}
			  : $c->{'state'} eq 'REVOKED'	? $text{'state_revoked'}
			  : $c->{'state'} eq 'expired'	? $text{'state_expired'}
			  :				  $c->{'state'};
		my $conn = $c->{'connected'}
			 ? &text('conn_yes', $c->{'since'} || '?')
			 : $text{'conn_no'};
		my @actions;
		if ($c->{'profile'}) {
			push(@actions, "<a href='download.cgi?name=".
			     &urlize($name)."'>$text{'act_download'}</a>");
			}
		if ($c->{'state'} eq 'valid') {
			push(@actions, "<a href='revoke.cgi?name=".
			     &urlize($name)."'>$text{'act_revoke'}</a>");
			}
		push(@rows, [ $name, $state, $c->{'expires'}, $conn,
			      $c->{'profile'} ? $text{'profile_yes'}
					      : $text{'profile_no'},
			      join(" | ", @actions) ]);
		}
	print &ui_columns_table([ $text{'col_name'}, $text{'col_state'},
				  $text{'col_expires'}, $text{'col_connected'},
				  $text{'col_profile'}, $text{'col_actions'} ],
				100, \@rows);
	print "<p>$text{'warn_key'}</p>\n";
	}

print &ui_hr();
print &ui_form_start("add.cgi", "post");
print &ui_table_start($text{'index_add'}, "width=100%", 2);
print &ui_table_row($text{'index_addname'},
		    &ui_textbox("name", undef, 20)." ".$text{'index_addhelp'});
print &ui_table_end();
print &ui_form_end([ [ undef, $text{'index_addbutton'} ] ]);

&ui_print_footer("/", $text{'index_return'});
