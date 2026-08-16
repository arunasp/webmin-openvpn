#!/usr/bin/perl

# Serve one client profile as a file download.
#
# The profile is the deliverable: a single self-contained .ovpn that every
# current client imports unaided - OpenVPN GUI on Windows through Import File,
# Import from URL or a command-line --import, OpenVPN Connect on iOS and
# Android through the share sheet, Tunnelblick on macOS by opening it. The
# legacy module shipped a zip of ca.crt, client.crt, client.key and ta.key
# because its configuration referenced them as separate files; an inline
# profile needs no such packaging, and an archive would be something none of
# those clients could import.
#
# This file contains the client's private key. It is served over whatever
# transport Webmin is configured with and to whoever Webmin has authenticated,
# and nothing here weakens either: the name is validated before it reaches the
# filesystem, and the response is marked as an attachment so a browser saves
# it rather than rendering a private key into a tab.

use strict;
use warnings;

require './openvpn-server-lib.pl';

our (%text, %in, %config);

&ReadParse();

my $name = $in{'name'};
&valid_client_name($name) ||
    &error(&text('down_ename', &html_escape($name || '')));

my $path = &profile_path($name);
$path && -f $path || &error(&text('down_emissing', &html_escape($name)));

open(my $fh, '<', $path) || &error(&text('down_eread', &html_escape($name)));
my $profile = do { local $/; <$fh> };
close($fh);

# text/plain rather than an invented type: the file is text, and a browser
# that ignores the disposition should still show something readable rather
# than offering to run it.
print "Content-Type: text/plain; charset=utf-8\n";
print "Content-Disposition: attachment; filename=\"$name.ovpn\"\n";
print "Content-Length: ", length($profile), "\n";
print "\n";
print $profile;
