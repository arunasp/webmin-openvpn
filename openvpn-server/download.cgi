#!/usr/bin/perl

# The client download page, and the download itself.
#
# Without ?file=1 this renders a page: what the file is, what it contains, and
# how each platform imports it. With ?file=1 it sends the profile.
#
# The page exists because the format is the thing worth saying. A profile
# issued here is the unified format - configuration, CA, client certificate,
# private key and tls-crypt key in one file - and that is what every current
# client imports: OpenVPN GUI copies a single file into its configuration
# directory and collects nothing referenced by name, OpenVPN Connect requires
# UTF-8 under 256 KB and recommends the unified form, and iOS cannot import a
# private key as a separate file at all. Someone handed a bare download has no
# way to know any of that.
#
# The file contains the client's private key, which is why the page says so
# where it cannot be missed, and why the download is marked as an attachment
# rather than rendered into a browser tab.

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

if ($in{'file'}) {
	open(my $fh, '<', $path) ||
	    &error(&text('down_eread', &html_escape($name)));
	my $profile = do { local $/; <$fh> };
	close($fh);

	# text/plain rather than an invented type: the file is text, and a
	# browser that ignores the disposition should show something readable
	# rather than offer to run it.
	print "Content-Type: text/plain; charset=utf-8\n";
	print "Content-Disposition: attachment; filename=\"$name.ovpn\"\n";
	print "Content-Length: ", length($profile), "\n";
	print "\n";
	print $profile;
	exit;
	}

my $safe = &html_escape($name);
my @st = stat($path);

&ui_print_header(undef, &text('down_title', $safe), "", "download", 1, 1);

print &ui_alert_box($text{'down_keywarn'}, 'warn');

print &ui_form_start("download.cgi", "get");
print &ui_hidden("name", $name);
print &ui_hidden("file", 1);
print &ui_table_start($text{'down_file'}, "width=100%", 2);
print &ui_table_row($text{'down_filename'}, "<tt>$safe.ovpn</tt>");
print &ui_table_row($text{'down_format'}, $text{'down_formatdesc'});
print &ui_table_row($text{'down_contains'}, $text{'down_containsdesc'});
print &ui_table_row($text{'down_size'}, ($st[7] || 0)." bytes");
print &ui_table_end();
print &ui_form_end([ [ undef, $text{'down_button'} ] ]);

print &ui_hr();
print "<h3>$text{'down_howto'}</h3>\n";
print "<p>$text{'down_howtointro'}</p>\n";

# One row per platform: the client to install, and what to do with the file.
# Kept in the interface rather than only in the documentation, because this is
# the page someone reaches when they are about to hand a profile to a user.
my @rows;
foreach my $p ('windows', 'android', 'ios', 'macos', 'linux') {
	push(@rows, [ $text{"down_${p}_os"},
		      $text{"down_${p}_client"},
		      $text{"down_${p}_how"} ]);
	}
print &ui_columns_table([ $text{'down_col_os'}, $text{'down_col_client'},
			  $text{'down_col_how'} ], 100, \@rows);

print "<p>$text{'down_revokenote'}</p>\n";

&ui_print_footer("", $text{'index_return2'}, "/", $text{'index_return'});
