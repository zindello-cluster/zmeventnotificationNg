#!/usr/bin/env perl
# The rule, line by line (docs/alert-rules.md, "The rule"), through sendEvent
# and against a real MariaDB: who is sent an alert, and who isn't.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../";
use lib "$FindBin::Bin/lib";

use Test::More;
use File::Temp qw(tempdir);
use JSON;
use AlertRulesTest;

use ZmEventNotification::Config qw(:all);
use ZmEventNotification::Constants qw(:all);

our %spy;

# The senders are spies, as in upstream's t/09.
BEGIN {
  %spy = ( fcm => 0, mqtt => 0 );
  for my $pkg (qw(ZmEventNotification::FCM ZmEventNotification::MQTT ZmEventNotification::DB ZmEventNotification::WebSocketHandler)) {
    ( my $file = $pkg ) =~ s{::}{/}g;
    $INC{"$file.pm"} = 1;
  }
  no strict 'refs';
  *{'ZmEventNotification::FCM::sendOverFCM'} = sub { $spy{fcm}++ };
  *{'ZmEventNotification::FCM::import'}      = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::sendOverFCM"} = \&ZmEventNotification::FCM::sendOverFCM;
  };
  *{'ZmEventNotification::MQTT::sendOverMQTTBroker'} = sub { $spy{mqtt}++ };
  *{'ZmEventNotification::MQTT::import'}             = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::sendOverMQTTBroker"} = \&ZmEventNotification::MQTT::sendOverMQTTBroker;
  };
  *{'ZmEventNotification::DB::updateEventinZmDB'}   = sub { };
  *{'ZmEventNotification::DB::getNotesFromEventDB'} = sub {''};
  *{'ZmEventNotification::DB::tagEventObjects'}     = sub { };
  *{'ZmEventNotification::DB::import'}              = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::$_"} = \&{"ZmEventNotification::DB::$_"} for qw(updateEventinZmDB getNotesFromEventDB tagEventObjects);
  };
  *{'ZmEventNotification::WebSocketHandler::getNotificationStatusEsControl'} = sub {0};
  *{'ZmEventNotification::WebSocketHandler::import'}                         = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::getNotificationStatusEsControl"} = \&ZmEventNotification::WebSocketHandler::getNotificationStatusEsControl;
  };
}

my ( $dbh, $zm, $ours ) = AlertRulesTest::database();
END { AlertRulesTest::drop_databases( $dbh, $zm, $ours ) if $dbh && $dbh->ping }

use_ok('ZmEventNotification::HookProcessor');
ZmEventNotification::HookProcessor->import(':all');

my $pipe = '';
open( my $writer, '>', \$pipe ) or die $!;
$writer->autoflush(1);
*main::WRITER = *$writer;

{
  package MockConn;
  sub new  { bless {}, shift }
  sub ip   {'10.0.0.1'}
  sub port {9000}
}

my $data = tempdir( CLEANUP => 1 );
mkdir "$data/push" or die $!;

sub rules_on {
  AlertRulesTest::config( { enable => 'yes', database => $ours } );
  $server_config{base_data_path}                 = $data;
  $hooks_config{enabled}                         = 1;
  $hooks_config{event_start_hook}                = '/usr/bin/detect';
  $hooks_config{event_end_hook}                  = '/usr/bin/detect_end';
  $hooks_config{event_start_notify_on_hook_success} = 'all';
  $hooks_config{event_end_notify_on_hook_success}   = 'all';
}
rules_on();
$main::dbh = $dbh;

$dbh->do("INSERT INTO Users (Id, Username) VALUES (1, 'alice'), (2, 'bob')") or die $dbh->errstr;

sub rule {    # user id, camera, on, types
  my ( $uid, $mid, $on, @types ) = @_;
  $dbh->do( "REPLACE INTO `$ours`.alert_rules (user_id, monitor_id, alerts, labels) VALUES (?, ?, ?, ?)", undef, $uid, $mid, $on, encode_json( \@types ) )
    or die $dbh->errstr;
  ZmEventNotification::AlertRules::_reset();
}

sub all_alerts {    # user id, on
  $dbh->do( "REPLACE INTO `$ours`.alert_users (user_id, alerts) VALUES (?, ?)", undef, @_ ) or die $dbh->errstr;
  ZmEventNotification::AlertRules::_reset();
}

sub clear {
  $dbh->do("DELETE FROM `$ours`.$_") for qw(alert_rules alert_users);
  ZmEventNotification::AlertRules::_reset();
}

my $n = 0;

# Is a phone of that user's sent an alert for these types on that camera?
sub pushed {
  my ( $user, $mid, $types, %more ) = @_;
  %spy = ( fcm => 0, mqtt => 0 );
  @AlertRulesTest::log = ();
  my $ac = { type => FCM, pushstate => 'enabled', state => INVALID_CONNECTION, id => ++$n, token => "token-$n-1234567890", %more };
  $ac->{user} = $user if defined $user;
  my $alarm = { MonitorId => "$mid", Name => "Camera $mid", EventId => 100 + $n, Cause => 'detected', DetectionJson => { labels => $types }, RulesObject => {} };
  sendEvent( $alarm, $ac, $more{event} // 'event_start', 0 );
  return $spy{fcm};
}

subtest 'no rules at all: as before the rules' => sub {
  clear();
  ok( pushed( 'alice', 1, ['person'] ), 'a user' );
  ok( pushed( undef,   1, ['zebra'] ),  'a phone with no user' );
};

subtest 'the default' => sub {
  clear();
  rule( 0, 0, 1, 'person', 'car', 'motorcycle' );
  ok( pushed( 'alice', 1, ['person'] ), 'a type it has' );
  ok( !pushed( 'alice', 1, ['dog'] ), 'a type it hasn\'t' );
  ok( AlertRulesTest::logged( info => qr/^Alert rules: no alert to alice's phone for Camera 1: dog isn't switched on for the camera$/ ), 'and the log says why' );
  ok( pushed( 'alice', 7, [ 'dog', 'car' ] ), 'one of two is enough' );
  ok( !pushed( 'alice', 7, [ 'dog', 'cat' ] ), 'neither of two' );
  ok( AlertRulesTest::logged( info => qr/dog, cat aren't switched on/ ), 'both named' );
  ok( pushed( 'bob', 1, ['Person'] ), 'whatever case the hook gives' );
  ok( pushed( 'bob', 1, ['motorbike'] ), 'motorbike counts as motorcycle' );
  ok( pushed( undef, 1, ['car'] ), 'a phone with no user: a type it has' );
  ok( !pushed( undef, 1, ['dog'] ), 'a phone with no user: a type it hasn\'t' );
  ok( AlertRulesTest::logged( info => qr/no alert to a phone with no user yet/ ), 'named as that' );
  ok( !pushed( '', 1, ['dog'] ), 'an empty user is no user' );
};

subtest 'a user\'s own row for a camera' => sub {
  clear();
  rule( 0, 0, 1, 'person', 'car' );
  rule( 1, 1, 1, 'dog' );
  ok( pushed( 'alice', 1, ['dog'] ), 'their type, on that camera' );
  ok( !pushed( 'alice', 1, ['person'] ), 'the default\'s type isn\'t theirs there' );
  ok( pushed( 'alice', 2, ['person'] ), 'another camera of theirs follows the default' );
  ok( !pushed( 'alice', 2, ['dog'] ), 'and only the default' );
  ok( !pushed( 'bob', 1, ['dog'] ), 'another user isn\'t touched by it' );
  ok( pushed( 'bob', 1, ['person'] ), 'and keeps the default' );
  ok( !pushed( undef, 1, ['dog'] ), 'nor is a phone with no user' );

  rule( 1, 3, 1 );
  ok( !pushed( 'alice', 3, ['person'] ), 'a camera on with no types: nothing found pushes' );

  rule( 1, 4, 1, 'Person' );
  ok( pushed( 'alice', 4, ['person'] ), 'a type stored in another case still counts' );
};

subtest 'a camera switched off' => sub {
  clear();
  rule( 0, 0, 1, 'person' );
  rule( 1, 2, 0, 'person' );
  ok( !pushed( 'alice', 2, ['person'] ), 'no alert from it' );
  ok( AlertRulesTest::logged( info => qr/the camera is switched off/ ), 'and the log says why' );
  ok( pushed( 'alice', 1, ['person'] ), 'their other cameras still alert' );
  ok( pushed( 'bob',   2, ['person'] ), 'and that camera still alerts everyone else' );
};

subtest 'all of a user\'s alerts switched off' => sub {
  clear();
  rule( 0, 0, 1, 'person' );
  rule( 1, 1, 1, 'person' );
  all_alerts( 1, 0 );
  ok( !pushed( 'alice', 1, ['person'] ), 'none from a camera they set' );
  ok( !pushed( 'alice', 2, ['person'] ), 'none from one they didn\'t' );
  ok( AlertRulesTest::logged( info => qr/all of their alerts are switched off/ ), 'and the log says why' );
  ok( pushed( 'bob', 1, ['person'] ), 'everyone else is as before' );
  all_alerts( 1, 1 );
  ok( pushed( 'alice', 1, ['person'] ), 'switched back on' );
};

subtest 'the default switched off' => sub {
  clear();
  rule( 0, 0, 0, 'person' );
  rule( 1, 1, 1, 'person' );
  ok( !pushed( 'bob', 1, ['person'] ), 'a user with no row gets nothing' );
  ok( !pushed( undef, 1, ['person'] ), 'nor a phone with no user' );
  ok( pushed( 'alice', 1, ['person'] ), 'a user who switched the camera on does' );
};

subtest 'a user removed from ZoneMinder' => sub {
  clear();
  ok( !pushed( 'zed', 1, ['person'] ), 'no alert, even with no rules at all' );
  ok( AlertRulesTest::logged( info => qr/no alert to zed's phone for Camera 1: that user is no longer in ZoneMinder/ ), 'and the log says why' );
  rule( 0, 0, 1, 'person' );
  ok( !pushed( 'zed', 1, ['person'] ), 'nor with the default' );
};

subtest 'an event with no types: the switches alone' => sub {
  clear();
  rule( 0, 0, 1, 'person' );
  rule( 1, 2, 0, 'person' );
  ok( pushed( 'alice', 1, [] ), 'a camera that is on' );
  ok( !pushed( 'alice', 2, [] ), 'a camera that is off' );
  all_alerts( 2, 0 );
  ok( !pushed( 'bob', 1, [] ), 'a user with all alerts off' );
};

subtest 'only pushes and the app\'s open connection' => sub {
  clear();
  rule( 0, 0, 0 );
  %spy = ( fcm => 0, mqtt => 0 );
  sendEvent( { MonitorId => '1', Name => 'Camera 1', EventId => 1, Cause => 'x', DetectionJson => { labels => ['person'] }, RulesObject => {} }, { type => MQTT, id => ++$n }, 'event_start', 0 );
  is( $spy{mqtt}, 1, 'MQTT is sent whatever the rules say' );

  my $alarm = { MonitorId => '1', Name => 'Camera 1', EventId => 2, Cause => 'x', DetectionJson => { labels => ['person'] }, RulesObject => {} };
  my $web   = { type => WEB, state => VALID_CONNECTION, id => ++$n, conn => MockConn->new(), user => 'alice' };
  $pipe = '';
  @AlertRulesTest::log = ();
  sendEvent( $alarm, $web, 'event_start', 0 );
  unlike( $pipe, qr/message--TYPE--$n--SPLIT--/, 'an open connection follows its user\'s rules' );
  ok( AlertRulesTest::logged( info => qr/no alert to alice's open connection for Camera 1/ ), 'named as that' );
  rule( 1, 1, 1, 'person' );
  $web->{id} = ++$n;
  sendEvent( $alarm, $web, 'event_start', 0 );
  like( $pipe, qr/message--TYPE--$n--SPLIT--/, 'and is sent what they switched on' );
};

subtest 'the end of an event goes through the rules too' => sub {
  clear();
  rule( 0, 0, 1, 'person' );
  ok( pushed( 'alice', 1, ['person'], event => 'event_end' ), 'sent' );
  ok( !pushed( 'alice', 1, ['dog'], event => 'event_end' ), 'not sent' );
};

subtest 'an alert the rules refuse doesn\'t count against the interval' => sub {
  clear();
  rule( 0, 0, 1, 'person' );
  my %phone = ( token => 'token-interval-1234567890', monlist => '1', intlist => '600' );
  ok( !pushed( 'alice', 1, ['dog'], %phone ), 'refused' );
  my $times = -s "$data/push/last_sent.json" ? decode_json( do { local ( @ARGV, $/ ) = "$data/push/last_sent.json"; <> } ) : {};
  ok( !exists $times->{ $phone{token} }, 'no send time recorded' );
  ok( pushed( 'alice', 1, ['person'], %phone ), 'so the next one, inside the interval, is sent' );
  ok( !pushed( 'alice', 1, ['person'], %phone ), 'and the one after that waits, as before the rules' );
};

subtest 'the app\'s own switches come first' => sub {
  clear();
  rule( 0, 0, 1, 'person' );
  ok( !pushed( 'alice', 1, ['person'], pushstate => 'disabled' ), 'pushes off in the app: none, whatever the rules' );
};

subtest 'a rule that can\'t be read' => sub {
  clear();
  $dbh->do("INSERT INTO `$ours`.alert_rules (user_id, monitor_id, alerts, labels) VALUES (0, 0, 1, '{\"person\": true}')") or die $dbh->errstr;
  ok( pushed( 'alice', 1, ['dog'] ), 'the alert is sent as before the rules' );
  ok( AlertRulesTest::logged( error => qr/couldn't be read, so this alert is sent as it was before them: a rule's types aren't a list/ ), 'and an error says so' );
};

subtest 'the database away' => sub {
  clear();
  rule( 0, 0, 0 );
  ok( !pushed( 'alice', 1, ['person'] ), 'refused while it is there' );
  ZmEventNotification::AlertRules::_reset();
  my $gone = $dbh->clone();
  $gone->disconnect();
  {
    local $main::dbh = $gone;
    ok( pushed( 'alice', 1, ['person'] ), 'sent as before the rules while it is away' );
    ok( AlertRulesTest::logged( error => qr/Alert rules: the rules couldn't be read, so this alert is sent as it was before them/ ), 'and an error says so' );
  }
  ok( !pushed( 'alice', 1, ['person'] ), 'refused again once it is back' );
};

subtest 'the rules switched off in the config' => sub {
  clear();
  rule( 0, 0, 0 );
  AlertRulesTest::config( { enable => 'no', database => $ours } );
  $server_config{base_data_path} = $data;
  ok( pushed( 'alice', 1, ['person'] ), 'everything is sent, whatever the tables hold' );
  rules_on();
};

done_testing();
