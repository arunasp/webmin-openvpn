#!/usr/bin/perl

# Library for the OpenVPN module.
#
# The module holds no OpenVPN logic of its own. It renders what vpn-client
# and vpn-server report, and calls them for anything that changes state, so
# every path the UI can take is a path that can also be taken from a shell
# and covered by the tools' own suite. If the UI needs something the tools
# cannot do, the tools grow it - this file does not.
#
# Tools are invoked in list form through open3. A form field is never
# interpolated into a shell string, and no shell is involved at all, so a
# client name is a single argument no matter what it contains. Names are
# validated here as well as in the tools: two cheap checks in different
# places beat one clever one.

use strict;
use warnings;

# Webmin lives one directory up from every module. This has to run at compile
# time, before use WebminCore, but after strictures so that nothing in this
# file is compiled without them.
BEGIN { push(@INC, ".."); }

use WebminCore;
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP ();

our (%text, %config, %in);

&init_config();

# run_tool(@argv) -> hashref { status, out, err }
#
# stderr is captured separately rather than merged: the tools put their
# diagnostics there, and showing the operator the underlying message beats a
# generic "command failed".
sub run_tool
{
my (@argv) = @_;
my $err = gensym();
my ($in_fh, $out_fh);
my $pid = eval { open3($in_fh, $out_fh, $err, @argv) };
if ($@ || !$pid) {
	return { 'status' => -1, 'out' => '',
		 'err' => "could not run $argv[0]: $@" };
	}
close($in_fh);
my $out = join('', <$out_fh>);
my $errout = join('', <$err>);
close($out_fh);
close($err);
waitpid($pid, 0);
return { 'status' => $? >> 8, 'out' => $out, 'err' => $errout };
}

# tool_json(@argv) -> (data, error)
#
# Always returns a two-element list. Callers render the error rather than
# dying, because a broken tool should produce a page that says so, not a
# Webmin stack trace.
sub tool_json
{
my (@argv) = @_;
my $r = &run_tool(@argv);
if ($r->{'status'} != 0) {
	my $msg = $r->{'err'} || "exit status $r->{'status'}";
	$msg =~ s/\s+$//;
	return (undef, $msg);
	}
my $data = eval { JSON::PP->new()->decode($r->{'out'}) };
if ($@ || !$data) {
	return (undef, "could not parse the output of $argv[0]");
	}
return ($data, undef);
}

# A packaged install puts the tools in /usr/sbin, because Debian policy
# forbids a package writing to /usr/local; a manual install conventionally
# uses /usr/local/sbin. Rather than make the operator correct the module
# configuration after choosing one, take the configured path when it is there
# and look in the usual places when it is not.
sub tool_path
{
my ($configured) = @_;
return $configured if ($configured && -x $configured);
my ($name) = $configured =~ m{([^/]+)$};
$name ||= $configured;
foreach my $dir ('/usr/sbin', '/usr/local/sbin', '/sbin', '/usr/bin') {
	return "$dir/$name" if (-x "$dir/$name");
	}
return $configured;
}

# A directive's values, in the order they appear. Returns a list, since push
# and route legitimately repeat.
sub conf_values
{
my ($lines, $directive) = @_;
my @out;
foreach my $l (@$lines) {
	next if ($l =~ /^\s*#/);
	if ($l =~ /^\s*\Q$directive\E\s+(.*?)\s*$/) {
		my $v = $1;
		$v =~ s/\s+#.*$//;
		push(@out, $v);
		}
	elsif ($l =~ /^\s*\Q$directive\E\s*$/) {
		push(@out, '');
		}
	}
return @out;
}

# Replace every occurrence of a directive with the given values, in place,
# leaving the rest of the file untouched.
#
# WHY IN PLACE RATHER THAN REGENERATED: a server configuration accumulates
# comments explaining why a line is there, and directives this module does not
# manage. Rewriting the file from a template would discard both, and the
# operator would have no way to know what had gone. Lines this form does not
# manage are never read, never parsed and never written.
#
# A directive with no existing occurrence is appended. One whose new value
# list is empty is removed.
sub conf_replace
{
my ($lines, $directive, @values) = @_;
my @out;
my $done = 0;
foreach my $l (@$lines) {
	if ($l !~ /^\s*#/ && $l =~ /^\s*\Q$directive\E(\s|$)/) {
		next if ($done);	# later occurrences drop out
		$done = 1;
		foreach my $v (@values) {
			push(@out, $v eq '' ? $directive : "$directive $v");
			}
		next;
		}
	push(@out, $l);
	}
if (!$done && @values) {
	push(@out, map { $_ eq '' ? $directive : "$directive $_" } @values);
	}
return \@out;
}

sub client_list
{
return &tool_json(&tool_path($config{'vpn_client'}), 'list', '--json');
}

sub server_status
{
return &tool_json(&tool_path($config{'vpn_server'}), 'status', '--json');
}

# A name that reaches a certificate, a filename and a URL. Anything outside
# this set is refused before it reaches any of them.
sub valid_client_name
{
my ($name) = @_;
return 0 if (!defined($name) || $name eq '');
return $name =~ /^[A-Za-z0-9_-]+$/ ? 1 : 0;
}

sub profile_path
{
my ($name) = @_;
# A bare return, not return undef: in list context the latter yields a
# one-element list containing undef, which is true.
return if (!&valid_client_name($name));
return "$config{'clients_dir'}/$name.ovpn";
}

1;
