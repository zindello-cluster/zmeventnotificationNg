#!/usr/bin/env perl
# The sign-in keeps the user on the connection, only when it was checked
# against ZoneMinder's users, and hands it on when the phone registers.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../";
use lib "$FindBin::Bin/lib";

use Test::More;
use JSON;
use AlertRulesTest;

use ZmEventNotification::Config qw(:all);
use ZmEventNotification::Constants qw(:all);

our @saved;

sub main::saveEsControlSettings { }
sub main::restartES             { }

# FCM and DB stubbed as upstream's t/15 stubs them: saveFCMTokens is a spy.
BEGIN {
  for my $pkg (qw(ZmEventNotification::FCM ZmEventNotification::DB)) {
    ( my $file = $pkg ) =~ s{::}{/}g;
    $INC{"$file.pm"} = 1;
  }
  no strict 'refs';
  *{'ZmEventNotification::FCM::saveFCMTokens'} = sub { push @main::saved, [@_]; return ( $_[1], $_[2] ); };
  *{'ZmEventNotification::FCM::import'}        = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::saveFCMTokens"} = \&ZmEventNotification::FCM::saveFCMTokens;
  };
  *{'ZmEventNotification::DB::getAllMonitorIds'} = sub { return ( 1, 2, 3 ); };
  *{'ZmEventNotification::DB::import'}           = sub {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::getAllMonitorIds"} = \&ZmEventNotification::DB::getAllMonitorIds;
  };
}

{
  package MockConn;
  sub new  { bless { sent => [] }, shift }
  sub ip   {'192.168.1.1'}
  sub port {12345}
  sub send_utf8 { push @{ $_[0]{sent} }, $_[1]; 1 }
}

use_ok('ZmEventNotification::WebSocketHandler');
ZmEventNotification::WebSocketHandler->import(':all');

AlertRulesTest::config();

# Whether ZoneMinder knows the user is validateAuth's to say (upstream's t/15
# tests it); here it answers as told.
our $auth_ok = 1;
{
  no warnings 'redefine';
  *ZmEventNotification::WebSocketHandler::validateAuth = sub { $auth_ok };
}

sub connect_and {
  my ( $conn, @messages ) = @_;
  @main::saved              = ();
  @main::active_connections = ( { conn => $conn, state => PENDING_AUTH, type => WEB, token => '', category => 'normal', badge => 0, monlist => '', intlist => '' } );
  processIncomingMessage( $conn, encode_json($_) ) for @messages;
  return $main::active_connections[0];
}

my $sign_in  = { event => 'auth', data => { user => 'alice', password => 'x', appversion => '3.0' } };
my $register = { event => 'push', data => { type => 'token', token => 'tokT', platform => 'ios', monlist => '1,2', intlist => '0,0', state => 'enabled' } };

subtest 'a sign-in ZoneMinder checked' => sub {
  local $auth_config{enabled} = 1;
  local $fcm_config{enabled}  = 1;
  my $ac = connect_and( MockConn->new(), $sign_in );
  is( $ac->{state}, VALID_CONNECTION, 'signed in' );
  is( $ac->{user},  'alice',          'the connection keeps the user' );

  $ac = connect_and( MockConn->new(), $sign_in, $register );
  is( $ac->{type},  FCM,    'the phone registers' );
  is( $ac->{token}, 'tokT', 'its token' );
  is( scalar @main::saved, 1, 'saved once' );
  is( scalar @{ $main::saved[0] }, 9, 'with a ninth argument' );
  is( $main::saved[0][8], 'alice', 'the user' );
  is( $main::saved[0][0], 'tokT',  'and upstream\'s own first' );
};

subtest 'a sign-in that fails' => sub {
  local $auth_config{enabled} = 1;
  local $auth_ok = 0;
  my $ac = connect_and( MockConn->new(), $sign_in );
  is( $ac->{state}, PENDING_DELETE, 'refused' );
  ok( !exists $ac->{user}, 'no user kept' );
};

subtest 'ZoneMinder\'s sign-in off: the name is anyone\'s to give' => sub {
  local $auth_config{enabled} = 0;
  local $fcm_config{enabled}  = 1;
  my $ac = connect_and( MockConn->new(), $sign_in, $register );
  is( $ac->{state}, VALID_CONNECTION, 'connected' );
  ok( !exists $ac->{user}, 'no user kept' );
  is( scalar @{ $main::saved[0] }, 9, 'the save still has its ninth argument' );
  ok( !defined $main::saved[0][8], 'undefined' );
};

subtest 'the control interface\'s sign-in isn\'t a ZoneMinder user\'s' => sub {
  local $auth_config{enabled} = 1;
  my $ac = connect_and( MockConn->new(), { %$sign_in, category => 'escontrol' } );
  is( $ac->{state}, VALID_CONNECTION, 'connected' );
  ok( !exists $ac->{user}, 'no user kept' );
};

subtest 'signing in again as someone else' => sub {
  local $auth_config{enabled} = 1;
  local $fcm_config{enabled}  = 1;
  my $again = { event => 'auth', data => { user => 'bob', password => 'x', appversion => '3.0' } };
  my $ac = connect_and( MockConn->new(), $sign_in, $again, $register );
  is( $ac->{user},        'bob', 'the connection\'s user is the last to sign in' );
  is( $main::saved[0][8], 'bob', 'and the phone is saved as theirs' );

  $ac = connect_and( MockConn->new(), $sign_in, { %$again, category => 'escontrol' } );
  ok( !exists $ac->{user}, 'a control sign-in after a user\'s drops the user' );
};

done_testing();
