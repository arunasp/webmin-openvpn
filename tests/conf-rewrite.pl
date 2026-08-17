#!/usr/bin/perl

# The configuration rewrite, on its own.
#
# This is the riskiest code in the module: it edits a file a running server
# depends on. What makes it safe is not the fields in front of it but the
# promise underneath - a directive the form does not manage is carried across
# exactly as it was found, comments included. That promise is what this
# checks, because a rewrite that quietly dropped a line would produce a server
# that starts and behaves differently.
#
# Run from tests/run.sh. Needs no Webmin: init_config is stubbed, and the
# functions under test touch nothing but the array they are given.

use strict;
use warnings;
use Cwd qw(abs_path);

# An absolute path: require searches @INC even for a path with slashes in it,
# unless the path is absolute.
my $here = abs_path($0);
$here =~ s{/[^/]+$}{};
push(@INC, "$here/stubs", "$here/../openvpn-server");

sub init_config { }
require "$here/../openvpn-server/openvpn-server-lib.pl";

my $failed = 0;
sub check
{
my ($what, $ok, $detail) = @_;
if ($ok) {
	print "[PASS] $what\n";
	}
else {
	print "[FAIL] $what: $detail\n";
	$failed++;
	}
}

my $original = <<'CONF';
# A comment that explains why the next line is there.
port 1194
proto udp
dev tun
server 10.8.0.0 255.255.255.0
push "route 192.0.2.0 255.255.255.0"
push "dhcp-option DNS 192.0.2.1"
# Managed by nothing in the form.
ifconfig-pool-persist /var/log/openvpn/ipp.txt
tls-crypt tls-crypt.key
verb 3
explicit-exit-notify 1
CONF

my @lines = split(/\n/, $original);
my $l = \@lines;

my @push = &conf_values($l, 'push');
check("both pushed options are read", scalar(@push) == 2, scalar(@push)." found");

$l = &conf_replace($l, 'push', '"route 198.51.100.0 255.255.255.0"');
$l = &conf_replace($l, 'verb', '4');
$l = &conf_replace($l, 'keepalive', '10 60');
$l = &conf_replace($l, 'explicit-exit-notify');
my $out = join("\n", @$l);

check("the comment survives",
      $out =~ /# A comment that explains why the next line is there\./,
      "it was dropped");
check("a comment in the middle survives",
      $out =~ /# Managed by nothing in the form\./, "it was dropped");
check("an unmanaged directive survives untouched",
      $out =~ m{^ifconfig-pool-persist /var/log/openvpn/ipp\.txt$}m,
      "it was changed or dropped");
check("identity directives are left alone",
      $out =~ /^tls-crypt tls-crypt\.key$/m, "tls-crypt was touched");
check("the replaced directive holds the new value",
      $out =~ /^push "route 198\.51\.100\.0 255\.255\.255\.0"$/m,
      "the new route is missing");
check("the value it replaced is gone",
      $out !~ /192\.0\.2\.0/, "the old route is still there");
check("a second occurrence is not left behind",
      scalar(() = $out =~ /^push /mg) == 1,
      "there are ".scalar(() = $out =~ /^push /mg)." push lines");
check("an edited directive keeps its position",
      $out =~ /dev tun\nserver 10\.8\.0\.0/, "the order changed");
check("a directive that was absent is appended",
      $out =~ /^keepalive 10 60$/m, "keepalive is missing");
check("a directive set to nothing is removed",
      $out !~ /explicit-exit-notify/, "it is still there");
check("verb was updated in place, not appended",
      $out =~ /^verb 4$/m && $out !~ /^verb 3$/m, "verb is wrong");

print $failed ? "\nFAILED $failed\n" : "\nall rewrite checks passed\n";
exit($failed ? 1 : 0);
