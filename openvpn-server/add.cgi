#!/usr/bin/perl

# Issue a new client.
#
# The work is one call to vpn-client add. Everything this page could do
# instead - generating a key, writing a profile, choosing an expiry - is
# already the tool's, and doing any of it here would give the module a second
# opinion about what a client is.
#
# On success it returns to the index, where the new client appears with a
# Download link. A page saying "done" would only stand between the operator
# and the thing they came for.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %in, %config);

&ReadParse();
&error_setup($text{'add_err'});

my $name = $in{'name'};
defined($name) or &error($text{'add_ename'});
$name =~ s/^\s+//;
$name =~ s/\s+$//;

# Validated here as well as in the tool. The tool refuses the same names, but
# an operator who mistypes should be told by the page they are looking at.
&valid_client_name($name) ||
    &error(&text('add_einvalid', &html_escape($name)));

my $r = &run_tool(&tool_path($config{'vpn_client'}), 'add', $name);
if ($r->{'status'} != 0) {
	my $msg = $r->{'err'} || $r->{'out'} || "exit status $r->{'status'}";
	$msg =~ s/\s+$//;
	&error(&html_escape($msg));
	}

&webmin_log("add", "client", $name);
&redirect("");
