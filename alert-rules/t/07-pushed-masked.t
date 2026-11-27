#!/usr/bin/env perl
# The fcm_notification job (processJobs, zmeventnotification.pl) with upstream's
# token masking backported (upstream #87): the alert rules are still told the
# whole token a push went to, and the job's log lines carry only its last ten
# characters. The real sub is pulled from the script source and run against a
# real pipe, as upstream's t/23 does.
use strict;
use warnings;
no warnings 'once';
use FindBin;
use lib "$FindBin::Bin/../../";
use lib "$FindBin::Bin/../../t/lib";

use Test::More;
use IO::Handle;
use IO::Select;
use Symbol qw(qualify_to_ref);
require StubZM;
use PlSource;

use ZmEventNotification::Constants qw(:all);
use ZmEventNotification::Config qw(:all);
use ZmEventNotification::Util qw(parse_job_line);

our ( $rin, $rout, %active_events, $child_forks, $parallel_hooks, @active_connections );
sub updateEventinZmDB { }

# The rules' hook, standing in for AlertRules::pushed.
my @pushed;
{ no warnings 'redefine'; *ZmEventNotification::AlertRules::pushed = sub { push @pushed, $_[0] }; }

pipe( READER, WRITER ) or die "pipe: $!";
WRITER->autoflush(1);
$rin = '';
vec( $rin, fileno(READER), 1 ) = 1;

# PlSource reads ../zmeventnotification.pl from the test's directory, one
# level up from upstream's t/; ours is two.
my $code = do {
  local $FindBin::Bin = "$FindBin::Bin/..";
  PlSource::extract( 'sub sysreadline', 'sub at_eol' )
    . PlSource::extract( 'sub processJobs', '} # end sub processJobs' );
};
eval "$code; 1" or die "compile processJobs: $@";

my $token  = 'tokA_0123456789abcdefghij';
my $suffix = substr( $token, -10 );
@active_connections = ( { id => 'f1', token => $token, badge => 3, invocations => { count => 7, at => 4 } } );
my @debug;
{
  no warnings 'redefine';
  local *main::Debug = sub { push @debug, $_[1] };
  print WRITER "fcm_notification--TYPE--$token--SPLIT--4--SPLIT--8--SPLIT--4\n";
  processJobs();
}
my $log = join "\n", @debug;

is_deeply( \@pushed, [$token], 'the alert rules are told the whole token the push went to' );
is( $active_connections[0]{badge}, 4, 'the badge is still updated' );
like( $log, qr/\Q$suffix\E/, 'the log carries the token\'s last ten characters' );
unlike( $log, qr/\Q$token\E/, 'the log never carries the whole token' );

done_testing();
