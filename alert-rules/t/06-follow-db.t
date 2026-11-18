#!/usr/bin/env perl
# Following an event (ALERT-RULES.md, "Following an event"; cluster-docs O477,
# O481): while an event is on, a type that joins live detection's alarm is sent
# at once, alone, through the rules, to the phones that haven't had this
# event's push: one push per event for each phone; the start's types aren't
# sent again; a type the rules refuse stays refused; the frame it first
# alarmed on becomes the event's objdetect.jpg if it has none, or if it raised
# the event's first push. Drives
# processNewAlarmsInFork against a real MariaDB, with sleep standing in for
# time: each "second" live detection may add a row, and the event ends when
# the test says.
use strict;
use warnings;
no warnings 'once';
our ( $ticks, $on_tick );
BEGIN { *CORE::GLOBAL::sleep = sub { $main::ticks++; $main::on_tick->($main::ticks) if $main::on_tick; 0 } }
use FindBin;
use lib "$FindBin::Bin/../../";
use lib "$FindBin::Bin/lib";

use Test::More;
use File::Temp qw(tempdir);
use JSON;
use AlertRulesTest;

use ZmEventNotification::Config qw(:all);
use ZmEventNotification::Constants qw(:all);

our ( @sent, @tags, $current );

BEGIN {
  for my $pkg (qw(ZmEventNotification::FCM ZmEventNotification::MQTT ZmEventNotification::DB ZmEventNotification::WebSocketHandler)) {
    ( my $file = $pkg ) =~ s{::}{/}g;
    $INC{"$file.pm"} = 1;
  }
  no strict 'refs';
  *{'ZmEventNotification::FCM::sendOverFCM'} = sub { push @main::sent, [ $_[1]->{id}, $_[0]->{Cause}, $_[0]->{DetectionJson}{labels} ] };
  *{'ZmEventNotification::FCM::import'} = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::sendOverFCM"} = \&ZmEventNotification::FCM::sendOverFCM;
  };
  *{'ZmEventNotification::MQTT::sendOverMQTTBroker'} = sub { };
  *{'ZmEventNotification::MQTT::import'} = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::sendOverMQTTBroker"} = \&ZmEventNotification::MQTT::sendOverMQTTBroker;
  };
  *{'ZmEventNotification::DB::updateEventinZmDB'}   = sub { };
  *{'ZmEventNotification::DB::getNotesFromEventDB'} = sub {''};
  *{'ZmEventNotification::DB::tagEventObjects'}     = sub { push @main::tags, [ @{ $_[1] } ] };
  *{'ZmEventNotification::DB::import'} = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::$_"} = \&{"ZmEventNotification::DB::$_"} for qw(updateEventinZmDB getNotesFromEventDB tagEventObjects);
  };
  *{'ZmEventNotification::WebSocketHandler::getNotificationStatusEsControl'} = sub {0};
  *{'ZmEventNotification::WebSocketHandler::import'} = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::getNotificationStatusEsControl"} = \&ZmEventNotification::WebSocketHandler::getNotificationStatusEsControl;
  };
}

my ( $dbh, $zm, $ours ) = AlertRulesTest::database();
END { AlertRulesTest::drop_databases( $dbh, $zm, $ours ) if $dbh && $dbh->ping }

use_ok('ZmEventNotification::HookProcessor');
use_ok('ZmEventNotification::AlertRules');

my $data     = tempdir( CLEANUP => 1 );
my $pictures = tempdir( CLEANUP => 1 );
my $events   = tempdir( CLEANUP => 1 );
mkdir "$data/push" or die $!;
my $hook = "$data/hook.pl";
open( my $h, '>', $hook ) or die $!;
print $h 'print $ENV{TEST_HOOK_OUT} // ""; exit( $ENV{TEST_HOOK_EXIT} // 0 );', "\n";
close($h);

sub config {
  my %more = @_;
  AlertRulesTest::config( { enable => 'yes', database => $ours, follow => 'yes', follow_seconds => 1, pictures => $pictures, %more } );
  $server_config{base_data_path}                     = $data;
  $hooks_config{enabled}                             = 1;
  $hooks_config{event_start_hook}                    = "$^X $hook";
  $hooks_config{event_end_hook}                      = undef;
  $hooks_config{hook_pass_image_path}                = 0;
  $hooks_config{use_hook_description}                = 1;
  $hooks_config{tag_detected_objects}                = 1;
  $hooks_config{hook_skip_monitors}                  = '';
  $hooks_config{event_start_notify_on_hook_success}  = 'all';
  $hooks_config{event_start_notify_on_hook_fail}     = 'none';
  $notify_config{send_event_start_notification}      = 1;
  $notify_config{send_event_end_notification}        = 0;
  $escontrol_config{enabled}                         = 0;
}
$main::dbh = $dbh;
$dbh->do( 'CREATE TABLE Events (Id BIGINT UNSIGNED NOT NULL PRIMARY KEY, MonitorId INT UNSIGNED, StartDateTime DATETIME(6), '
    . 'EndDateTime DATETIME NULL, Cause VARCHAR(32), AlarmFrames INT UNSIGNED NOT NULL DEFAULT 0, Notes TEXT)' ) or die $dbh->errstr;
$dbh->do('CREATE TABLE Tags (Id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, Name VARCHAR(64) NOT NULL UNIQUE)') or die $dbh->errstr;
$dbh->do('CREATE TABLE Events_Tags (TagId INT UNSIGNED NOT NULL, EventId BIGINT UNSIGNED NOT NULL, PRIMARY KEY (TagId, EventId))') or die $dbh->errstr;
$dbh->do("INSERT INTO Tags (Name) VALUES ('car'), ('person'), ('mine')") or die $dbh->errstr;
$dbh->do("INSERT INTO Users (Id, Username) VALUES (1, 'alice'), (2, 'bob'), (3, 'carol')") or die $dbh->errstr;
# alice: people on the camera; bob: people and cars; carol: trucks only
$dbh->do( "INSERT INTO `$ours`.alert_rules (user_id, monitor_id, alerts, labels) VALUES (1, 5, 1, ?), (2, 5, 1, ?), (3, 5, 1, ?)",
  undef, encode_json( ['person'] ), encode_json( [ 'person', 'car' ] ), encode_json( ['truck'] ) )
  or die $dbh->errstr;

{
  no warnings 'redefine';
  *ZmEventNotification::AlertRules::_event_path = sub { "$events/$_[0]" };
}

our $state;
{
  no warnings 'redefine';
  *main::zmGetMonitorState = sub { $main::state };
  *main::zmGetLastEvent    = sub { $main::current };
}

# Live detection's row for a type in the alarm raised at $raised, seen now.
sub alarmed {
  my ( $label, $confidence, $raised, $picture ) = @_;
  $dbh->do(
    "INSERT INTO `$ours`.detector_alarms VALUES (5, ?, ?, UTC_TIMESTAMP(6), UTC_TIMESTAMP(6), ?, ?, ?)"
      . ' ON DUPLICATE KEY UPDATE last_seen = UTC_TIMESTAMP(6)',
    undef, $raised, $label, $confidence, $label eq 'car' ? 1 : 0, $picture
  ) or die $dbh->errstr;
}

sub conns {
  my $n = 0;
  return map { { type => FCM, pushstate => 'enabled', state => INVALID_CONNECTION, id => $_, token => "token-$_-" . ( ++$n ) x 12,
                 monlist => '5', intlist => '0', user => $_ } } qw(alice bob carol);
}

# One event on camera 5, started a second ago (or `ago` seconds). %$script:
# tick => code; `cause`, the event's; `keep`, to keep what was told of earlier
# events' alarms. ZoneMinder moves to the next event at tick $end.
sub run_event {
  my ( $eid, $end, %script ) = @_;
  my $cause = delete $script{cause} // 'Detected';
  my $ago   = delete $script{ago}   // 1;
  my $keep  = delete $script{keep};
  @sent = @tags = ();
  @AlertRulesTest::log = ();
  unlink "$data/push/last_sent.json";
  unlink "$data/push/alarms_sent.json" if !$keep;
  $dbh->do( 'REPLACE INTO Events (Id, MonitorId, StartDateTime, Cause) VALUES (?, 5, NOW(6) - INTERVAL ? SECOND, ?)', undef, $eid, $ago, $cause )
    or die $dbh->errstr;
  mkdir "$events/$eid";
  $main::current = $eid;
  my $pipe = '';
  open( my $w, '>', \$pipe ) or die $!;
  *main::WRITER = *$w;
  @main::active_connections = conns();
  $main::state = 4;    # in alarm
  $main::ticks = 0;
  $main::on_tick = sub {
    my $t = shift;
    $script{$t}->() if $script{$t};
    $main::current = 0 if $t >= $end;    # ZoneMinder's next event
  };
  ZmEventNotification::HookProcessor::processNewAlarmsInFork(
    { Alarm => { MonitorId => 5, EventId => $eid, MonitorName => 'Garage Mast Camera', Start => { State => 'pending', Cause => $cause } },
      MonitorObj => {} } );
  $main::on_tick = undef;
  return [ grep {/^event_description/} split /\n/, $pipe ];
}

sub who { return [ sort map { $_->[0] } @_ ] }

subtest 'a type that joins the alarm is sent at once, alone, through the rules, to phones not yet told' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  my $raised = '2030-01-01 00:00:00';    # later than the event's start, so it's the event's
  alarmed( 'car', 0.90, $raised, 'car.jpg' );
  open( my $p, '>', "$pictures/car.jpg" ) or die $!;
  print $p 'the car frame';
  close($p);
  open( $p, '>', "$pictures/person.jpg" ) or die $!;
  print $p 'the person frame';
  close($p);
  local $ENV{TEST_HOOK_OUT}  = 'detected:car:90%--SPLIT--{"labels":["car"]}';
  local $ENV{TEST_HOOK_EXIT} = 0;
  my $desc = run_event(
    100, 8,
    2 => sub { alarmed( 'person', 0.72, $raised, 'person.jpg' ) },
    3 => sub { alarmed( 'car', 0.95, $raised ) },              # seen again: already told
    5 => sub { alarmed( 'truck', 0.66, '2030-01-01 00:00:09', 'truck.jpg' ) },
  );
  my @start  = grep { $_->[1] =~ /^detected:car/ } @sent;
  my @person = grep { $_->[1] =~ /^detected:person/ } @sent;
  my @truck  = grep { $_->[1] =~ /^detected:truck/ } @sent;
  is_deeply( who(@start),  ['bob'],            'the start (a car): bob, who has cars on' );
  is_deeply( who(@person), ['alice'], 'a person joins: alice, at once; bob had this event\'s push' );
  is_deeply( $person[0][2], ['person'], 'alone: only the type that joined' );
  like( $person[0][1], qr/^detected:person:72% Detected$/, 'its text as the hook\'s, before the event\'s cause' );
  is_deeply( who(@truck), ['carol'], 'a truck joins: carol only; nobody else has trucks on' );
  is( scalar(@sent), 3, 'one push per event for each phone: nobody is sent twice' );
  is_deeply( \@tags, [ ['car'], ['person'], ['truck'] ], 'the start\'s type, then each joined type, tagged on the event' );
  is( scalar( grep {/detected:person:72%/} @$desc ) + scalar( grep {/detected:truck:66%/} @$desc ), 2, 'and its text put before the notes' );
  open( my $o, '<', "$events/100/objdetect.jpg" ) or die "no objdetect.jpg: $!";
  is( scalar(<$o>), 'the person frame', 'the picture: the frame the first joined type alarmed on' );
  close($o);
};

subtest 'nothing at the start: the first type to alarm is sent, and its frame is the picture' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  local $ENV{TEST_HOOK_OUT}  = '';
  local $ENV{TEST_HOOK_EXIT} = 1;
  run_event( 101, 4, 1 => sub { alarmed( 'person', 0.81, '2030-01-01 00:00:00', 'person.jpg' ) } );
  is_deeply( who(@sent), [ 'alice', 'bob' ], 'the person: alice and bob' );
  ok( -e "$events/101/objdetect.jpg", 'the event has its picture' );
};

subtest 'the first push\'s frame replaces a picture of a type nobody was sent' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  mkdir "$events/102";
  open( my $p, '>', "$events/102/objdetect.jpg" ) or die $!;
  print $p 'the start frame';
  close($p);
  local $ENV{TEST_HOOK_OUT}  = '';
  local $ENV{TEST_HOOK_EXIT} = 1;
  run_event( 102, 3, 1 => sub { alarmed( 'person', 0.81, '2030-01-01 00:00:00', 'person.jpg' ) } );
  open( my $o, '<', "$events/102/objdetect.jpg" ) or die $!;
  is( scalar(<$o>), 'the person frame', 'the person, who raised the event\'s first push' );
  close($o);
};

subtest 'an event whose start was sent keeps its picture' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  mkdir "$events/106";
  open( my $p, '>', "$events/106/objdetect.jpg" ) or die $!;
  print $p 'the car frame, from the start';
  close($p);
  local $ENV{TEST_HOOK_OUT}  = 'detected:car:90%--SPLIT--{"labels":["car"]}';
  local $ENV{TEST_HOOK_EXIT} = 0;
  run_event( 106, 3, 1 => sub { alarmed( 'person', 0.81, '2030-01-01 00:00:00', 'person.jpg' ) } );
  is_deeply( [ map { $_->[0] } @sent ], [ 'bob', 'alice' ], 'bob at the start, alice when the person joins' );
  open( my $o, '<', "$events/106/objdetect.jpg" ) or die $!;
  is( scalar(<$o>), 'the car frame, from the start', 'unchanged: the start was the event\'s first push' );
  close($o);
};

subtest 'one push per event for each phone, raised by the first type its user has on' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  local $ENV{TEST_HOOK_OUT}  = '';
  local $ENV{TEST_HOOK_EXIT} = 1;
  run_event(
    107, 6,
    1 => sub { alarmed( 'car',    0.85, '2030-01-01 00:00:00' ) },
    2 => sub { alarmed( 'person', 0.81, '2030-01-01 00:00:00' ) },
    3 => sub { alarmed( 'truck',  0.70, '2030-01-01 00:00:00' ) },
  );
  is_deeply( [ map { [ $_->[0], $_->[2] ] } @sent ], [ [ 'bob', ['car'] ], [ 'alice', ['person'] ], [ 'carol', ['truck'] ] ],
    'bob for the car; alice for the person, and not bob again; carol for the truck' );
};

subtest 'one alarm, one push for each phone, though it runs on into the next event' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  local $ENV{TEST_HOOK_OUT}  = '';
  local $ENV{TEST_HOOK_EXIT} = 1;
  run_event( 120, 3, 1 => sub { alarmed( 'person', 0.81, '2030-01-02 00:00:00' ) } );
  is_deeply( who(@sent), [ 'alice', 'bob' ], 'the person: alice and bob' );
  # ZoneMinder's next event, the same alarm still on: its start hook answers with it
  local $ENV{TEST_HOOK_OUT}  = 'detected:person:81%--SPLIT--{"labels":["person"],"alarms":{"person":["2030-01-02 00:00:00.000000"]}}';
  local $ENV{TEST_HOOK_EXIT} = 0;
  run_event( 121, 4, keep => 1, 2 => sub { alarmed( 'person', 0.81, '2030-01-02 00:00:00' ) } );
  is( scalar(@sent), 0, 'the next event: nobody told again of the same alarm' );
  ok( AlertRulesTest::logged( info => qr/no alert to alice's phone .*told of this alarm already/ ), 'and the log says why' );
  # A new alarm with a person in it, in that event: a new push
  run_event( 122, 4, keep => 1, cause => 'Detected', 2 => sub { alarmed( 'person', 0.9, '2030-01-02 00:01:00' ) } );
  is_deeply( who(@sent), [ 'alice', 'bob' ], 'a new alarm: told' );
};

subtest 'an event goes on after its alarm ends: a second alarm in it is told' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  local $ENV{TEST_HOOK_OUT}  = 'detected:car:90%--SPLIT--{"labels":["car"]}';
  local $ENV{TEST_HOOK_EXIT} = 0;
  run_event( 130, 6,
    1 => sub { $main::state = main::STATE_TAPE() },    # the car's alarm over; ZoneMinder records on in the same event
    3 => sub { alarmed( 'person', 0.88, '2030-01-03 00:00:00' ); $main::state = 4 } );
  is_deeply( [ map { $_->[0] } @sent ], [ 'bob', 'alice' ], 'bob for the car; alice for the person, in the same event' );
};

subtest 'an event that ends with no alarm frames gives back its tags, notes and picture' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  $dbh->do('DELETE FROM Events_Tags');
  mkdir "$events/140";
  open( my $p, '>', "$events/140/objdetect.jpg" ) or die $!;
  print $p 'given';
  close($p);
  local $ENV{TEST_HOOK_OUT}  = 'detected:car:90%--SPLIT--{"labels":["car"]}';
  local $ENV{TEST_HOOK_EXIT} = 0;
  run_event( 140, 3, 3 => sub {
    $dbh->do("UPDATE Events SET EndDateTime = NOW(), AlarmFrames = 0, Notes = 'detected:car:90% ' WHERE Id = 140");
    $dbh->do("INSERT INTO Events_Tags SELECT Id, 140 FROM Tags WHERE Name IN ('car', 'mine')");
  } );
  is_deeply( $dbh->selectcol_arrayref('SELECT t.Name FROM Events_Tags et JOIN Tags t ON t.Id = et.TagId WHERE et.EventId = 140'),
    ['mine'], 'its car tag taken off; a tag it wasn\'t given kept' );
  is( $dbh->selectrow_array('SELECT Notes FROM Events WHERE Id = 140'), '', 'the text taken off its notes' );
  ok( !-e "$events/140/objdetect.jpg", 'its picture taken off' );
};

subtest 'an event that ends with alarm frames keeps them' => sub {
  config();
  $dbh->do('DELETE FROM Events_Tags');
  local $ENV{TEST_HOOK_OUT}  = 'detected:car:90%--SPLIT--{"labels":["car"]}';
  local $ENV{TEST_HOOK_EXIT} = 0;
  run_event( 141, 3, 3 => sub {
    $dbh->do("UPDATE Events SET EndDateTime = NOW(), AlarmFrames = 40 WHERE Id = 141");
    $dbh->do("INSERT INTO Events_Tags SELECT Id, 141 FROM Tags WHERE Name = 'car'");
  } );
  is( $dbh->selectrow_array('SELECT COUNT(*) FROM Events_Tags WHERE EventId = 141'), 1, 'its tag kept' );
};

subtest 'an alarm raised in a continuous section is the alarmed event\'s that ZoneMinder opens for it' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  $dbh->do('DELETE FROM Events WHERE Id = 151');
  local $ENV{TEST_HOOK_OUT}  = '';
  local $ENV{TEST_HOOK_EXIT} = 1;
  run_event( 150, 4, cause => 'Continuous', ago => 10,
    1 => sub {    # a person raises an alarm: now, inside the section
      $dbh->do( "INSERT INTO `$ours`.detector_alarms VALUES (5, UTC_TIMESTAMP(6), 'person', UTC_TIMESTAMP(6), UTC_TIMESTAMP(6), 0.9, 1, NULL)" );
    },
    2 => sub {    # and ZoneMinder opens the alarmed event, from a moment before
      $dbh->do("INSERT INTO Events (Id, MonitorId, StartDateTime, Cause) VALUES (151, 5, NOW(6) - INTERVAL 3 SECOND, 'Detected')");
    } );
  is( scalar(@sent), 0, 'nothing told in the section: the alarm is the next event\'s' );
  is_deeply( \@tags, [], 'nor tagged' );
};

subtest 'an alarm over before the event started isn\'t the event\'s' => sub {
  config();
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  $dbh->do( "INSERT INTO `$ours`.detector_alarms VALUES (5, '2020-01-01', 'person', '2020-01-01', '2020-01-01', 0.9, 1, NULL)" ) or die $dbh->errstr;
  local $ENV{TEST_HOOK_OUT}  = '';
  local $ENV{TEST_HOOK_EXIT} = 1;
  run_event( 103, 3 );
  is( scalar(@sent), 0, 'nothing sent' );
};

subtest 'not following: as before, one decision at the start' => sub {
  config( follow => 'no' );
  $dbh->do("DELETE FROM `$ours`.detector_alarms");
  local $ENV{TEST_HOOK_OUT}  = '';
  local $ENV{TEST_HOOK_EXIT} = 1;
  run_event( 104, 3, 1 => sub { alarmed( 'person', 0.81, '2030-01-01 00:00:00' ) } );
  is( scalar(@sent), 0, 'the person that joined isn\'t sent' );
  ok( !ZmEventNotification::AlertRules::following(), 'following is off unless set' );
};

subtest 'the table away: said once for the event, and the event goes on' => sub {
  config( database => 'no_such_database' );
  local $ENV{TEST_HOOK_OUT}  = 'detected:car:90%--SPLIT--{"labels":["car"]}';
  local $ENV{TEST_HOOK_EXIT} = 0;
  run_event( 105, 4 );
  is( AlertRulesTest::logged( error => qr/what has alarmed in event 105 couldn't be read/ ), 1, 'logged once' );
};

done_testing();
