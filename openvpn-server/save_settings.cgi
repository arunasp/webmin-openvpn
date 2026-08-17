#!/usr/bin/perl

# Write back what settings.cgi collected.
#
# Every field is validated here rather than trusted from the form, because a
# form is only a suggestion about what arrives. What passes validation is
# written into the existing configuration in place: directives this page
# manages are replaced, everything else - comments, ordering, directives it
# knows nothing about - is carried across untouched.
#
# The result goes through vpn-server apply-config, which backs up the current
# file, installs the candidate, restarts the unit, and puts the backup back if
# the server refuses to start. That is the only check that means anything,
# since OpenVPN has no dry-run mode.
#
# It cannot catch a configuration that starts and is wrong: a pushed route to
# the wrong network leaves a server running and clients unable to reach
# anything. Nothing here can tell the difference, and the confirmation says so.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %in, %config);

&ReadParse();
&error_setup($text{'save_err'});

my $ipv4 = qr/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;

$in{'net'} =~ $ipv4 || &error(&text('save_enet', &html_escape($in{'net'})));
$in{'mask'} =~ $ipv4 || &error(&text('save_emask', &html_escape($in{'mask'})));

my @routes;
foreach my $l (split(/\r?\n/, $in{'routes'})) {
	$l =~ s/^\s+//; $l =~ s/\s+$//;
	next if ($l eq '');
	# A route is a network and a mask. Anything else would be pushed to
	# every client and rejected by each of them at connect time.
	$l =~ /^(\S+)\s+(\S+)$/ && $1 =~ $ipv4 && $2 =~ $ipv4 ||
	    &error(&text('save_eroute', &html_escape($l)));
	push(@routes, $l);
	}

my @dns;
foreach my $l (split(/\r?\n/, $in{'dns'})) {
	$l =~ s/^\s+//; $l =~ s/\s+$//;
	next if ($l eq '');
	$l =~ $ipv4 || &error(&text('save_edns', &html_escape($l)));
	push(@dns, $l);
	}

my $domain = $in{'domain'};
$domain =~ s/^\s+//; $domain =~ s/\s+$//;
$domain eq '' || $domain =~ /^[A-Za-z0-9][A-Za-z0-9.-]*$/ ||
    &error(&text('save_edomain', &html_escape($domain)));

$in{'keepalive'} =~ /^\d+\s+\d+$/ ||
    &error(&text('save_ekeepalive', &html_escape($in{'keepalive'})));
$in{'verb'} =~ /^\d+$/ && $in{'verb'} <= 11 ||
    &error(&text('save_everb', &html_escape($in{'verb'})));
$in{'ciphers'} =~ /^[A-Za-z0-9:_-]+$/ ||
    &error(&text('save_eciphers', &html_escape($in{'ciphers'})));
$in{'auth'} =~ /^[A-Za-z0-9-]+$/ ||
    &error(&text('save_eauth', &html_escape($in{'auth'})));
$in{'tlsmin'} =~ /^1\.[0-3]$/ ||
    &error(&text('save_etls', &html_escape($in{'tlsmin'})));

my $r = &run_tool(&tool_path($config{'vpn_server'}), 'show-config');
$r->{'status'} == 0 || &error($text{'save_eread'});
my @lines = split(/\n/, $r->{'out'});
my $lines = \@lines;

# Everything pushed is one directive, so it is rebuilt as a set rather than
# edited line by line.
my @push;
push(@push, "\"route $_\"") foreach (@routes);
push(@push, "\"dhcp-option DNS $_\"") foreach (@dns);
push(@push, "\"dhcp-option DOMAIN $domain\"") if ($domain ne '');
push(@push, "\"redirect-gateway def1 bypass-dhcp\"") if ($in{'redirect'});

$lines = &conf_replace($lines, 'server', "$in{'net'} $in{'mask'}");
$lines = &conf_replace($lines, 'push', @push);
$lines = &conf_replace($lines, 'keepalive', $in{'keepalive'});
$lines = &conf_replace($lines, 'data-ciphers', $in{'ciphers'});
$lines = &conf_replace($lines, 'auth', $in{'auth'});
$lines = &conf_replace($lines, 'tls-version-min', $in{'tlsmin'});
$lines = &conf_replace($lines, 'verb', $in{'verb'});
$lines = &conf_replace($lines, 'explicit-exit-notify',
			$in{'exitnotify'} ? '1' : ());

my $body = join("\n", @$lines)."\n";

if (!$in{'confirm'}) {
	&ui_print_header(undef, $text{'save_title'}, "", "settings", 1, 1);
	print &ui_confirmation_form("save_settings.cgi",
		"<b>".$text{'save_warn'}."</b><br>".$text{'save_sessions'}."<br>".
		$text{'save_rollback'},
		[ map { [ $_, $in{$_} ] } qw(net mask routes dns domain redirect
					     keepalive ciphers auth tlsmin verb
					     exitnotify) ],
		[ [ "confirm", $text{'save_button'} ] ]);
	print "<pre>".&html_escape($body)."</pre>\n";
	&ui_print_footer("settings.cgi", $text{'set_return'});
	exit;
	}

my $tmp = &transname("openvpn-server.conf");
open(my $fh, '>', $tmp) || &error($text{'apply_etmp'});
print $fh $body;
close($fh);

my $ar = &run_tool(&tool_path($config{'vpn_server'}), 'apply-config', $tmp);
unlink($tmp);
if ($ar->{'status'} != 0) {
	my $msg = $ar->{'err'} || $ar->{'out'} || "exit status $ar->{'status'}";
	$msg =~ s/\s+$//;
	&error(&html_escape($msg));
	}

&webmin_log("settings", "server", undef);
&redirect("settings.cgi");
