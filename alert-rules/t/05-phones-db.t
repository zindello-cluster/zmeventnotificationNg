#!/usr/bin/env perl
# The list of paired phones the Event Server page shows, kept from the token
# file against a real MariaDB; and Remove, which forgets a phone.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../";
use lib "$FindBin::Bin/lib";

# A clock the test can move, for the 30 seconds between updates.
our $clock;
BEGIN { $clock = 0; *CORE::GLOBAL::time = sub { CORE::time() + $main::clock }; }

use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use POSIX qw(strftime);
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

my ( $dbh, $zm, $ours ) = AlertRulesTest::database();
END { AlertRulesTest::drop_databases( $dbh, $zm, $ours ) if $dbh && $dbh->ping }

use_ok('ZmEventNotification::AlertRules');

my $dir = tempdir( CLEANUP => 1 );
AlertRulesTest::config( { enable => 'yes', database => $ours } );
$fcm_config{enabled}    = 1;
$fcm_config{token_file} = "$dir/tokens.txt";
$main::dbh              = $dbh;

sub write_file {
  open( my $fh, '>', $fcm_config{token_file} ) or die $!;
  print $fh encode_json( { tokens => shift } );
  close($fh);
}

sub read_file {
  open( my $fh, '<', $fcm_config{token_file} ) or die $!;
  local $/;
  return decode_json(<$fh>)->{tokens};
}

# The token file, byte for byte.
sub file_bytes {
  open( my $fh, '<', $fcm_config{token_file} ) or die $!;
  local $/;
  return scalar <$fh>;
}

sub rows {
  return $dbh->selectall_hashref( "SELECT * FROM `$ours`.alert_phones", 'token_hash' ) // die $dbh->errstr;
}

# The next update: 31 seconds on.
sub later {
  $main::clock += 31;
  @AlertRulesTest::log = ();
  ZmEventNotification::AlertRules::tick();
}

my %file = (
  'tok-alice' => { user => 'alice', platform => 'ios', appversion => '3.0.1', profile => 'Home', paired => 1700000000, seen => 1700000100, pushstate => 'enabled', monlist => '1,2', intlist => '0,0', invocations => { count => 2, at => 10 } },
  'tok-old'   => { platform => 'android', pushstate => 'enabled', monlist => '1', intlist => '0' },
);
my %hash = map { $_ => sha256_hex($_) } keys %file, 'tok-live', 'tok-gone';

subtest 'the phones in the token file are listed' => sub {
  write_file( \%file );
  ZmEventNotification::AlertRules::tick();
  my $rows = rows();
  is( scalar keys %$rows, 2, 'one row each' );
  my $a = $rows->{ $hash{'tok-alice'} };
  ok( $a, 'under the SHA-256 of its token' );
  is_deeply(
    [ @$a{qw(username platform app_version profile first_seen last_seen last_push remove)} ],
    [ 'alice', 'ios', '3.0.1', 'Home', '2023-11-14 22:13:20', '2023-11-14 22:15:00', undef, 0 ],
    'a phone with a user: who, what, and when in UTC'
  );
  my $o = $rows->{ $hash{'tok-old'} };
  is_deeply(
    [ @$o{qw(username platform app_version profile first_seen last_seen last_push remove)} ],
    [ undef, 'android', 'unknown', undef, undef, undef, undef, 0 ],
    'a phone from before the rules: what the file has, the rest empty'
  );
  my ($leak) = $dbh->selectrow_array("SELECT COUNT(*) FROM `$ours`.alert_phones WHERE CONCAT_WS('|', token_hash, username, platform, app_version, profile) LIKE '%tok-%'");
  is( $leak, 0, 'no token is in the table' );
  ok( !AlertRulesTest::logged( error => qr/./ ), 'without an error' );
};

subtest 'every 30 seconds, not every tick' => sub {
  $file{'tok-old'} = { %{ $file{'tok-old'} }, user => 'bob', seen => 1700000200, appversion => '3.0.2' };
  write_file( \%file );
  ZmEventNotification::AlertRules::tick();
  ok( !defined rows()->{ $hash{'tok-old'} }{username}, 'a tick straight after changes nothing' );
  later();
  my $o = rows()->{ $hash{'tok-old'} };
  is_deeply( [ @$o{qw(username app_version first_seen last_seen)} ], [ 'bob', '3.0.2', undef, '2023-11-14 22:16:40' ], '30 seconds on, the row is as the file has it' );
  is( rows()->{ $hash{'tok-alice'} }{last_seen}, '2023-11-14 22:15:00', 'and the other row is untouched' );
};

subtest 'the last alert sent' => sub {
  ZmEventNotification::AlertRules::pushed('tok-alice');
  my $at = strftime( '%Y-%m-%d %H:%M:%S', gmtime( time() ) );
  later();
  my $rows = rows();
  is( $rows->{ $hash{'tok-alice'} }{last_push}, $at, 'is the time the fork reported it, UTC' );
  ok( !defined $rows->{ $hash{'tok-old'} }{last_push}, 'for that phone only' );
  later();
  is( rows()->{ $hash{'tok-alice'} }{last_push}, $at, 'and stays until the next' );
};

subtest 'long values are cut to fit' => sub {
  $file{'tok-alice'}{profile} = 'p' x 200;
  write_file( \%file );
  later();
  is( rows()->{ $hash{'tok-alice'} }{profile}, 'p' x 64, 'a profile' );
  ok( !AlertRulesTest::logged( error => qr/./ ), 'without an error' );
  $file{'tok-alice'}{profile} = 'Home';
  write_file( \%file );
  later();
};

subtest 'Remove' => sub {
  $file{'tok-live'} = { user => 'alice', platform => 'ios', pushstate => 'enabled', paired => 1700000000, seen => 1700000300 };
  write_file( \%file );
  later();
  is( scalar keys %{ rows() }, 3, 'three phones' );

  my $conn = bless {}, 'MockConn';
  @main::active_connections = (
    { type => FCM, state => INVALID_CONNECTION, token => 'tok-alice', user => 'alice' },                    # from the file
    { type => FCM, state => INVALID_CONNECTION, token => 'tok-old',   user => 'bob' },
    { type => FCM, state => VALID_CONNECTION,   token => 'tok-live',  user => 'alice', conn => $conn },     # its app is open
    { type => WEB, state => VALID_CONNECTION,   token => '',          user => 'bob',   conn => bless( {}, 'MockConn' ) },
  );
  $dbh->do( "UPDATE `$ours`.alert_phones SET `remove` = 1 WHERE token_hash IN (?, ?)", undef, @hash{qw(tok-alice tok-live)} ) or die $dbh->errstr;

  ZmEventNotification::AlertRules::tick();
  is( scalar keys %{ rows() }, 3, 'not before the next update' );
  later();

  my $rows = rows();
  is_deeply( [ keys %$rows ], [ $hash{'tok-old'} ], 'their rows are gone, the other phone\'s isn\'t' );
  my $tokens = read_file();
  is_deeply( [ sort keys %$tokens ], ['tok-old'], 'their tokens are out of the token file' );
  is( $tokens->{'tok-old'}{user}, 'bob', 'and the other phone\'s entry is whole' );
  is( $main::active_connections[0]{state}, PENDING_DELETE, 'a phone that isn\'t connected is dropped' );
  is( $main::active_connections[1]{state}, INVALID_CONNECTION, 'the other phone is still pushed to' );
  is( $main::active_connections[1]{token}, 'tok-old',          'with its token' );
  is_deeply( [ @{ $main::active_connections[2] }{qw(type token state)} ], [ WEB, '', VALID_CONNECTION ], 'a phone whose app is open keeps its connection, without the token' );
  is( $main::active_connections[2]{conn}, $conn, 'the same connection' );
  is_deeply( [ @{ $main::active_connections[3] }{qw(type token state)} ], [ WEB, '', VALID_CONNECTION ], 'another open connection is untouched' );
  is( AlertRulesTest::logged( info => qr/^Alert rules: alice's phone was removed, and gets no more alerts until its app pairs again$/ ), 2, 'each said in the log' );

  later();
  is_deeply( [ keys %{ rows() } ], [ $hash{'tok-old'} ], 'and it stays that way' );
  delete @file{qw(tok-alice tok-live)};
};

subtest 'a removed phone that pairs again is listed again' => sub {
  $file{'tok-live'} = { user => 'alice', platform => 'ios', pushstate => 'enabled', paired => 1700000400, seen => 1700000400 };
  write_file( \%file );
  later();
  my $row = rows()->{ $hash{'tok-live'} };
  is( $row->{remove},     0,                     'not marked' );
  is( $row->{first_seen}, '2023-11-14 22:20:00', 'paired when it paired again' );
};

subtest 'Remove on a phone the token file no longer has' => sub {
  $dbh->do( "INSERT INTO `$ours`.alert_phones (token_hash, platform, app_version, `remove`) VALUES (?, 'ios', '1', 1)", undef, $hash{'tok-gone'} ) or die $dbh->errstr;
  my $before = file_bytes();
  later();
  ok( !exists rows()->{ $hash{'tok-gone'} }, 'its row goes' );
  is( file_bytes(), $before, 'and the token file is as it was' );
};

subtest 'a phone the push service refused' => sub {
  delete $file{'tok-live'};    # as the event server does, when a push to it is refused
  write_file( \%file );
  later();
  is_deeply( [ keys %{ rows() } ], [ $hash{'tok-old'} ], 'is gone from the list' );
};

subtest 'a token file that can\'t be read: nothing is taken off the list' => sub {
  open( my $fh, '>', $fcm_config{token_file} ) or die $!;
  print $fh '{"tokens": {';
  close($fh);
  later();
  is( scalar keys %{ rows() }, 1, 'half written' );
  unlink $fcm_config{token_file};
  later();
  is( scalar keys %{ rows() }, 1, 'missing' );
  write_file( \%file );
};

subtest 'the database away' => sub {
  $file{'tok-new'} = { user => 'bob', platform => 'ios' };
  write_file( \%file );
  my $before = file_bytes();
  my $gone   = $dbh->clone();
  $gone->disconnect();
  {
    local $main::dbh = $gone;
    is( eval { later(); 'lived' }, 'lived', 'the update fails without stopping anything' );
    ok( AlertRulesTest::logged( error => qr/^Alert rules: the list of paired phones wasn't brought up to date, trying again in a while: / ), 'and an error says so' );
  }
  is( file_bytes(), $before, 'the token file is untouched' );
  is( scalar keys %{ rows() }, 1, 'the table is as it was' );
  later();
  is( scalar keys %{ rows() }, 2, 'and the next update catches up' );
};

subtest 'pushes switched off in the event server' => sub {
  local $fcm_config{enabled} = 0;
  $file{'tok-more'} = { platform => 'ios' };
  write_file( \%file );
  later();
  is( scalar keys %{ rows() }, 2, 'the list isn\'t kept' );
};

done_testing();
