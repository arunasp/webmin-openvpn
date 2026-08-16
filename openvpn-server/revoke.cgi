#!/usr/bin/perl

# Revoke a client, after saying plainly what that costs.
#
# Two things make the confirmation worth a page of its own rather than a
# JavaScript prompt. Revocation cannot be undone: the certificate is in the
# CRL from then on, and the only way back is issuing a new client with a new
# key. And openvpn-server@.service defines no ExecReload, so refreshing the
# CRL restarts the server and drops EVERY connected session, not only this
# client's. An operator who revokes one laptop at a busy moment should know
# that before they click, not afterwards.
#
# Without a confirm parameter this asks. With one, it revokes.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %in, %config);

&ReadParse();
&error_setup($text{'revoke_err'});

my $name = $in{'name'};
&valid_client_name($name) ||
    &error(&text('revoke_ename', &html_escape($name || '')));

my $safe = &html_escape($name);

if (!$in{'confirm'}) {
	&ui_print_header(undef, &text('revoke_title', $safe), "", "revoke",
			 1, 1);

	print &ui_confirmation_form("revoke.cgi",
		"<b>".&text('revoke_warn', $safe)."</b><br>".
		$text{'revoke_sessions'}."<br>".
		$text{'revoke_permanent'},
		[ [ "name", $name ] ],
		[ [ "confirm", $text{'revoke_button'} ] ]);

	&ui_print_footer("", $text{'index_return2'}, "/", $text{'index_return'});
	exit;
	}

my $r = &run_tool(&tool_path($config{'vpn_client'}), 'revoke', $name);
if ($r->{'status'} != 0) {
	my $msg = $r->{'err'} || $r->{'out'} || "exit status $r->{'status'}";
	$msg =~ s/\s+$//;
	&error(&html_escape($msg));
	}

&webmin_log("revoke", "client", $name);
&redirect("");
