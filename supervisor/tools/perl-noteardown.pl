# Runs a Perl script, then exits without Perl's global teardown.
# Strawberry Perl's XML::LibXML segfaults during teardown after DFHack's
# codegen.pl has already written every header, which fails the build.
use strict;
use POSIX ();
BEGIN {
    *CORE::GLOBAL::exit = sub { my $c = shift // 0; $| = 1; close STDOUT; close STDERR; POSIX::_exit($c) };
}
my $script = shift @ARGV;
if ($script =~ /^-/) { exec $^X, $script, @ARGV }   # perl switches (CMake asks -V:version): pass straight through
$0 = $script;
$script = "./$script" unless $script =~ m{^([A-Za-z]:)?[/\\]|^\./};   # 'do' skips @INC only for explicit paths
my $ok = do $script;
if ($@) { print STDERR $@; POSIX::_exit(1) }
$| = 1; close STDOUT; close STDERR;
POSIX::_exit(0);
