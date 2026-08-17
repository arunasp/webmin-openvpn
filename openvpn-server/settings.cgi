#!/usr/bin/perl

# The settings an operator changes, as fields rather than as a file.
#
# WHY THIS AND NOT A TEXTAREA: a form knows what each value means. It can
# refuse a netmask that is not one, keep the pushed routes as a list, and
# leave every directive it does not manage exactly as it found it. A textarea
# over server.conf accepts anything, including a file that starts a daemon
# nobody can reach.
#
# What it manages is the tunnel's own shape: the network handed to clients,
# what they are told to route through it, and the parameters of the control
# and data channels. What it will not touch:
#
#   port and protocol   set-port owns those, because they also live in the
#                       UPnP mapping and in every issued profile
#   ca, cert, key       identity, not settings; changing them by hand is how
#                       a server stops verifying anybody
#   tls-crypt, crl      the same
#
# Saving goes through vpn-server apply-config, which backs up, installs,
# restarts, and restores the backup if the server refuses to come up.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %config);

&ui_print_header(undef, $text{'set_title'}, "", "settings", 1, 1);

my ($server, $err) = &server_status();
if ($err) {
	print &ui_alert_box(&text('index_toolerr',
				  &tool_path($config{'vpn_server'}), $err),
			    'danger');
	&ui_print_footer("", $text{'index_return2'}, "/", $text{'index_return'});
	exit;
	}

my $r = &run_tool(&tool_path($config{'vpn_server'}), 'show-config');
if ($r->{'status'} != 0) {
	print &ui_alert_box(&html_escape($r->{'err'} || 'cannot read the configuration'),
			    'danger');
	&ui_print_footer("", $text{'index_return2'}, "/", $text{'index_return'});
	exit;
	}
my @lines = split(/\n/, $r->{'out'});

# The pushed options are one directive with several shapes, so they are pulled
# apart here and put back together on save.
my (@routes, @dns, $domain, $redirect);
foreach my $p (&conf_values(\@lines, 'push')) {
	my $v = $p;
	$v =~ s/^"//; $v =~ s/"$//;
	if ($v =~ /^route\s+(.*)/) { push(@routes, $1); }
	elsif ($v =~ /^dhcp-option\s+DNS\s+(\S+)/) { push(@dns, $1); }
	elsif ($v =~ /^dhcp-option\s+DOMAIN\s+(\S+)/) { $domain = $1; }
	elsif ($v =~ /^redirect-gateway/) { $redirect = $v; }
	}

my ($net) = &conf_values(\@lines, 'server');
my ($mask) = $net && $net =~ /^(\S+)\s+(\S+)/ ? ($2) : ('');
my ($netaddr) = $net && $net =~ /^(\S+)/ ? ($1) : ('');
my ($keepalive) = &conf_values(\@lines, 'keepalive');
my ($ciphers) = &conf_values(\@lines, 'data-ciphers');
my ($auth) = &conf_values(\@lines, 'auth');
my ($tlsmin) = &conf_values(\@lines, 'tls-version-min');
my ($verb) = &conf_values(\@lines, 'verb');
my @exitnotify = &conf_values(\@lines, 'explicit-exit-notify');

print &ui_form_start("save_settings.cgi", "post");

print &ui_table_start($text{'set_tunnel'}, "width=100%", 2);
print &ui_table_row($text{'set_net'},
	&ui_textbox("net", $netaddr, 18)." / ".&ui_textbox("mask", $mask, 18).
	"<br>".$text{'set_nethelp'});
print &ui_table_row($text{'set_mode'},
	&ui_select("redirect", $redirect ? 1 : 0,
		   [ [ 0, $text{'set_split'} ], [ 1, $text{'set_full'} ] ]).
	"<br>".$text{'set_modehelp'});
print &ui_table_row($text{'set_routes'},
	&ui_textarea("routes", join("\n", @routes), 4, 40).
	"<br>".$text{'set_routeshelp'});
print &ui_table_row($text{'set_dns'},
	&ui_textarea("dns", join("\n", @dns), 2, 40).
	"<br>".$text{'set_dnshelp'});
print &ui_table_row($text{'set_domain'}, &ui_textbox("domain", $domain, 24));
print &ui_table_end();

print &ui_table_start($text{'set_channel'}, "width=100%", 2);
print &ui_table_row($text{'set_ciphers'}, &ui_textbox("ciphers", $ciphers, 40));
print &ui_table_row($text{'set_auth'}, &ui_textbox("auth", $auth, 12));
print &ui_table_row($text{'set_tlsmin'}, &ui_textbox("tlsmin", $tlsmin, 6));
print &ui_table_row($text{'set_keepalive'},
	&ui_textbox("keepalive", $keepalive, 12)."<br>".$text{'set_keepalivehelp'});
print &ui_table_row($text{'set_verb'}, &ui_textbox("verb", $verb, 4));
print &ui_table_row($text{'set_exit'},
	&ui_yesno_radio("exitnotify", scalar(@exitnotify) ? 1 : 0));
print &ui_table_end();

print &ui_form_end([ [ undef, $text{'set_save'} ] ]);

print &ui_hr();
print "<p>".&text('set_elsewhere', "$server->{'port'}/$server->{'proto'}")."</p>\n";

&ui_print_footer("server.cgi", $text{'srvpage_return'},
		 "", $text{'index_return2'}, "/", $text{'index_return'});
