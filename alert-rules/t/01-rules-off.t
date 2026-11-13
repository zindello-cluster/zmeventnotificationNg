#!/usr/bin/env perl
# With the rules off (the default) nothing of ours runs, and nothing of ours
# can stop an alert; and what the hook found becomes the types the rules name.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../";
use lib "$FindBin::Bin/lib";

use Test::More;
use AlertRulesTest;

use ZmEventNotification::Config qw(:all);
use ZmEventNotification::Constants qw(:all);

# FCM.pm's heavy imports, as upstream's t/12 stubs them
for my $pkg (qw(ZmEventNotification::MQTT ZmEventNotification::DB ZmEventNotification::WebSocketHandler LWP::UserAgent HTTP::Request)) {
  ( my $file = $pkg ) =~ s{::}{/}g;
  $INC{"$file.pm"} = 1;
  no strict 'refs';
  *{"${pkg}::import"} = sub {1};
}

use_ok('ZmEventNotification::AlertRules');

# A connection that fails the test if it is used at all.
{
  package NoDatabase;
  sub new { bless {}, shift }
  our $AUTOLOAD;
  sub AUTOLOAD { return if $AUTOLOAD =~ /DESTROY$/; die "the database was used: $AUTOLOAD\n" }
}
# One that is there, and fails.
{
  package DeadDatabase;
  sub new     { bless {}, shift }
  sub prepare {undef}
  sub do      {undef}
  sub errstr  {'Lost connection to server'}
}

my $alarm = { MonitorId => 3, Name => 'Driveway', EventId => 9, DetectionJson => { labels => ['person'] } };
my $phone = { type => FCM, state => INVALID_CONNECTION, token => 'tok', user => 'alice' };

subtest 'no alert_rules section: off' => sub {
  AlertRulesTest::config();
  local $main::dbh = NoDatabase->new();
  local $fcm_config{enabled} = 1;
  ok( !ZmEventNotification::AlertRules::enabled(), 'off' );
  is( ZmEventNotification::AlertRules::allows( $alarm, $phone ), 1, 'every alert is allowed' );
  is( eval { ZmEventNotification::AlertRules::tick(); ZmEventNotification::AlertRules::pushed('tok'); 'lived' },
    'lived', 'the tick and a reported push do nothing' );
  is( scalar @AlertRulesTest::log, 0, 'and say nothing' );
};

subtest 'enable: "no": off' => sub {
  AlertRulesTest::config( { enable => 'no', database => 'detector' } );
  local $main::dbh = NoDatabase->new();
  ok( !ZmEventNotification::AlertRules::enabled(), 'off' );
  is( ZmEventNotification::AlertRules::allows( $alarm, $phone ), 1, 'every alert is allowed' );
};

subtest 'a database name that isn\'t one: off, and said' => sub {
  AlertRulesTest::config( { enable => 'yes', database => 'detector`; DROP TABLE Users; --' } );
  local $main::dbh = NoDatabase->new();
  ok( !ZmEventNotification::AlertRules::enabled(), 'off' );
  ok( AlertRulesTest::logged( error => qr/isn't a database's name/ ), 'an error says why' );
  is( ZmEventNotification::AlertRules::allows( $alarm, $phone ), 1, 'every alert is allowed' );
};

subtest 'on, and the database fails: the alert is sent as before' => sub {
  AlertRulesTest::config( { enable => 'yes', database => 'detector' } );
  local $main::dbh = DeadDatabase->new();
  ok( ZmEventNotification::AlertRules::enabled(), 'on' );
  ok( AlertRulesTest::logged( info => qr/Alert rules are on, kept in the detector database/ ), 'and said so' );
  is( ZmEventNotification::AlertRules::allows( $alarm, $phone ), 1, 'allowed' );
  ok( AlertRulesTest::logged( error => qr/couldn't be read, so this alert is sent as it was before them: Lost connection/ ),
    'an error says the rules were not read' );

  local $main::dbh = undef;
  is( ZmEventNotification::AlertRules::allows( $alarm, { %$phone, user => 'bob' } ), 1, 'allowed with no connection at all' );

  local $fcm_config{enabled} = 1;
  local $fcm_config{token_file} = '/nonexistent/tokens.txt';
  is( eval { ZmEventNotification::AlertRules::tick(); 'lived' }, 'lived', 'the tick lives through it' );
};

subtest 'the types the hook found' => sub {
  my $labels = sub { [ ZmEventNotification::AlertRules::labels( { DetectionJson => shift } ) ] };
  is_deeply( $labels->( { labels => [ 'person', 'car' ] } ), [ 'person', 'car' ], 'zm_detect\'s answer' );
  is_deeply( $labels->( [ { label => 'dog' }, { label => 'person' } ] ), [ 'dog', 'person' ], 'a list of objects' );
  is_deeply( $labels->( { labels => [ 'Person', ' car ', 'person' ] } ), [ 'person', 'car' ], 'lower case, trimmed, once each' );
  is_deeply( $labels->( { labels => ['motorbike'] } ), ['motorcycle'], 'motorbike is motorcycle' );
  is_deeply( $labels->( { labels => [ 'motorbike', 'motorcycle' ] } ), ['motorcycle'], 'and only once' );
  is_deeply( $labels->( { labels => [ undef, '', {}, 'bus' ] } ), ['bus'], 'what isn\'t a name is left out' );
  is_deeply( $labels->( [] ),         [], 'none' );
  is_deeply( $labels->( {} ),         [], 'none, no list' );
  is_deeply( $labels->(undef),        [], 'no answer' );
  is_deeply( $labels->('not json'), [], 'not an answer' );
};

done_testing();
