#!/usr/bin/env perl
# The token file keeps each phone's user, and when it paired and last
# registered, only for a caller that hands the user on; upstream's own calls
# write what they always did.
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

for my $pkg (qw(ZmEventNotification::MQTT ZmEventNotification::DB ZmEventNotification::WebSocketHandler LWP::UserAgent HTTP::Request)) {
  ( my $file = $pkg ) =~ s{::}{/}g;
  $INC{"$file.pm"} = 1;
  no strict 'refs';
  *{"${pkg}::import"} = sub {1};
}

use_ok('ZmEventNotification::FCM');
ZmEventNotification::FCM->import(':all');

AlertRulesTest::config();
$fcm_config{enabled} = 1;
my $dir = tempdir( CLEANUP => 1 );

sub file_of {
  my $content = shift;
  my $path    = "$dir/tokens-" . ( 0 + keys %{ { map { $_ => 1 } glob("$dir/*") } } ) . '.txt';
  open( my $fh, '>', $path ) or die $!;
  print $fh encode_json($content);
  close($fh);
  return $path;
}

sub read_back {
  open( my $fh, '<', shift ) or die $!;
  local $/;
  return decode_json(<$fh>)->{tokens};
}

my @upstream = qw(appversion intlist invocations monlist platform pushstate);

subtest 'upstream\'s call: what it always wrote' => sub {
  local $fcm_config{token_file} = file_of( { tokens => {} } );
  saveFCMTokens( 'tokA', '1,2', '0,0', 'android', 'enabled', undef, '3.0' );
  my $t = read_back( $fcm_config{token_file} )->{tokA};
  is_deeply( [ sort keys %$t ], \@upstream, 'no user, no times' );

  saveFCMTokens( 'tokA', '1,2', '0,0', 'android', 'enabled', undef, '3.0', 'Home' );
  $t = read_back( $fcm_config{token_file} )->{tokA};
  is_deeply( [ sort keys %$t ], [ sort @upstream, 'profile' ], 'with a profile: still none' );
};

subtest 'a new phone, its user handed on' => sub {
  local $fcm_config{token_file} = file_of( { tokens => {} } );
  my $before = time();
  my @back   = saveFCMTokens( 'tokB', '1,2', '0,0', 'ios', 'enabled', undef, '3.0', 'Home', 'alice' );
  is_deeply( \@back, [ '1,2', '0,0' ], 'returns what upstream\'s returns' );
  my $t = read_back( $fcm_config{token_file} )->{tokB};
  is( $t->{user}, 'alice', 'the user' );
  ok( $t->{paired} >= $before && $t->{paired} <= time(), 'when it paired' );
  ok( $t->{seen} >= $before   && $t->{seen} <= time(),   'when it last registered' );
  is( $t->{platform}, 'ios',  'and upstream\'s own: the platform' );
  is( $t->{profile},  'Home', 'the profile' );
};

subtest 'a phone from before the rules' => sub {
  local $fcm_config{token_file} = file_of(
    { tokens => { tokC => { monlist => '1', intlist => '0', platform => 'android', pushstate => 'enabled', appversion => '2.9', invocations => { count => 4, at => 10 } } } } );
  saveFCMTokens( 'tokC', '1', '0', 'android', 'enabled', { count => 4, at => 10 }, '3.0', undef, 'bob' );
  my $t = read_back( $fcm_config{token_file} )->{tokC};
  is( $t->{user}, 'bob', 'gets its user' );
  ok( $t->{seen}, 'and when it last registered' );
  ok( !exists $t->{paired}, 'but not a time it paired: that was before' );
};

subtest 'a registration with no user doesn\'t forget one' => sub {
  local $fcm_config{token_file} = file_of( { tokens => { tokD => { user => 'carol', paired => 100, seen => 200, platform => 'ios' } } } );
  saveFCMTokens( 'tokD', '1', '0', 'ios', 'enabled', undef, '3.0', undef, undef );
  my $t = read_back( $fcm_config{token_file} )->{tokD};
  is( $t->{user},   'carol', 'the user stays' );
  is( $t->{paired}, 100,     'when it paired stays' );
  ok( $t->{seen} > 200, 'when it last registered moves' );

  saveFCMTokens( 'tokD', '1', '0', 'ios', 'enabled', undef, '3.0', undef, 'dave' );
  is( read_back( $fcm_config{token_file} )->{tokD}{user}, 'dave', 'another user signing in on it takes it' );
};

subtest 'the user is read back at start' => sub {
  local $fcm_config{token_file} = file_of(
    { tokens => { tokE => { user => 'erin', platform => 'ios', pushstate => 'enabled' }, tokF => { platform => 'android', pushstate => 'enabled' } } } );
  @main::active_connections = ();
  initFCMTokens();
  my %by = map { $_->{token} => $_ } @main::active_connections;
  is( $by{tokE}{user}, 'erin', 'a phone with a user' );
  ok( !defined $by{tokF}{user}, 'a phone with none' );
  is( $by{tokF}{type}, FCM, 'which is still a phone to push to' );
};

subtest 'upstream\'s own rewrites keep what we added' => sub {
  local $fcm_config{token_file} = file_of( { tokens => { tokG => { user => 'gus', paired => 100, seen => 200, platform => 'ios', pushstate => 'enabled' } } } );
  saveFCMTokens( 'tokG', '1', '0', 'ios', 'disabled', undef, '3.0' );
  my $t = read_back( $fcm_config{token_file} )->{tokG};
  is_deeply( [ @$t{qw(user paired seen pushstate)} ], [ 'gus', 100, 200, 'disabled' ], 'an 8-argument save' );
};

done_testing();
