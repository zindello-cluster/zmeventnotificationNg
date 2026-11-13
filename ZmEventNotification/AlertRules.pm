package ZmEventNotification::AlertRules;

# zindello-cluster: alert rules (ALERT-RULES.md).
#
# A push goes to a phone only when that phone's user has the event's camera,
# and one of the types found in it, switched on. The rules are rows in a
# database beside ZoneMinder's, set through ZoneMinder's Event Server page
# and its API; this module reads them, and keeps the list of paired phones
# that page shows.
#
#   alert_rules:
#     enable: "yes"        # off unless set: with it off nothing here runs
#     database: detector   # where the alert_rules, alert_users and
#                          # alert_phones tables are
#
# It uses the event server's own database connection, ZoneMinder's. Nothing
# here may stop a push or the daemon: if the rules can't be read the alert is
# sent as it was before them, and a failed update of the phones table is
# logged and tried again.

use strict;
use warnings;
use JSON;
use Digest::SHA qw(sha256_hex);
use Encode ();
use POSIX qw(strftime);
use ZmEventNotification::Constants qw(:all);
use ZmEventNotification::Config qw(:all);
use ZmEventNotification::FCM ();

use constant TICK_SECONDS  => 30;    # how often the phones table is brought up to date
use constant CACHE_SECONDS => 10;    # how long a rule that was read is used

my $settings;
my %cache;
my %pushed;
my $last_tick = 0;

sub _settings {
  return $settings if $settings;
  my ( $on, $db ) = ( 0, 'detector' );
  if ($config_obj) {
    $on = config_get_val( $config_obj, 'alert_rules', 'enable', 'no' ) ? 1 : 0;
    $db = config_get_val( $config_obj, 'alert_rules', 'database', 'detector' );
  }
  if ( $on && $db !~ /^\w+$/ ) {
    main::Error("Alert rules: '$db' isn't a database's name, so the rules are off");
    $on = 0;
  }
  main::Info("Alert rules are on, kept in the $db database") if $on;
  return $settings = { on => $on, db => $db };
}

sub enabled { return _settings()->{on}; }

# For tests: forget the settings and everything remembered.
sub _reset {
  $settings  = undef;
  %cache     = ();
  %pushed    = ();
  $last_tick = 0;
}

sub _rows {
  my ( $sql, @bind ) = @_;
  my $dbh = $main::dbh or die "no database connection\n";
  my $sth = $dbh->prepare($sql) or die( ( $dbh->errstr() // 'prepare failed' ) . "\n" );
  $sth->execute(@bind) or die( ( $sth->errstr() // 'execute failed' ) . "\n" );
  my $rows = $sth->fetchall_arrayref( {} );
  $sth->finish();
  return $rows;
}

sub _do {
  my ( $sql, @bind ) = @_;
  my $dbh = $main::dbh or die "no database connection\n";
  defined $dbh->do( $sql, undef, @bind ) or die( ( $dbh->errstr() // 'statement failed' ) . "\n" );
  return;
}

sub _cached {
  my ( $key, $read ) = @_;
  my $hit = $cache{$key};
  return $hit->{value} if $hit && time() - $hit->{at} < CACHE_SECONDS;
  my $value = $read->();
  $cache{$key} = { at => time(), value => $value };
  return $value;
}

# The ZoneMinder user of that name: { id, alerts }, or undef if there is none.
sub _user {
  my $name = shift;
  my $db   = _settings()->{db};
  return _cached(
    "user\0$name",
    sub {
      my $rows = _rows(
        "SELECT u.Id AS id, a.alerts AS alerts FROM Users u"
          . " LEFT JOIN `$db`.alert_users a ON a.user_id = u.Id WHERE u.Username = ?",
        $name
      );
      return undef if !@$rows;
      return { id => $rows->[0]{id}, alerts => ( $rows->[0]{alerts} // 1 ) ? 1 : 0 };
    }
  );
}

# The user's row for the camera, else the default (user 0, camera 0), else
# undef: { alerts, labels => { name => 1 } }.
sub _rule {
  my ( $uid, $mid ) = @_;
  my $db = _settings()->{db};
  return _cached(
    "rule\0$uid\0$mid",
    sub {
      my $rows = _rows(
        "SELECT user_id, alerts, labels FROM `$db`.alert_rules"
          . " WHERE (user_id = ? AND monitor_id = ?) OR (user_id = 0 AND monitor_id = 0)",
        $uid, $mid
      );
      my ($row) = grep { $uid && $_->{user_id} == $uid } @$rows;
      ($row) = grep { $_->{user_id} == 0 } @$rows if !$row;
      return undef if !$row;
      my $labels = JSON->new->decode( $row->{labels} );    # ZoneMinder's connection returns text, not bytes
      die "a rule's types aren't a list\n" if ref($labels) ne 'ARRAY';
      return { alerts => $row->{alerts} ? 1 : 0, labels => { map { lc($_) => 1 } grep { defined && !ref } @$labels } };
    }
  );
}

# The types the hook found in the event, as the rules name them.
sub labels {
  my $alarm = shift;
  my $det   = $alarm->{DetectionJson};
  my @raw;
  if ( ref($det) eq 'HASH' && ref( $det->{labels} ) eq 'ARRAY' ) {
    @raw = @{ $det->{labels} };
  } elsif ( ref($det) eq 'ARRAY' ) {
    @raw = map { ref($_) eq 'HASH' ? $_->{label} : () } @$det;
  }
  my %seen;
  my @found;
  foreach (@raw) {
    next if !defined || ref;
    ( my $label = lc ) =~ s/^\s+|\s+$//g;
    $label = 'motorcycle' if $label eq 'motorbike';    # an older name some models give
    push @found, $label if $label ne '' && !$seen{$label}++;
  }
  return @found;
}

sub _decide {
  my ( $alarm, $ac ) = @_;
  my $uid = 0;
  if ( defined $ac->{user} && $ac->{user} ne '' ) {
    my $user = _user( $ac->{user} );
    return ( 0, 'that user is no longer in ZoneMinder' ) if !$user;
    return ( 0, 'all of their alerts are switched off' ) if !$user->{alerts};
    $uid = $user->{id};
  }
  my $rule = _rule( $uid, $alarm->{MonitorId} );
  return 1 if !$rule;
  return ( 0, 'the camera is switched off' ) if !$rule->{alerts};
  my @found = labels($alarm);
  return 1 if !@found;
  return 1 if grep { $rule->{labels}{$_} } @found;
  return ( 0, join( ', ', @found ) . ( @found > 1 ? " aren't" : " isn't" ) . ' switched on for the camera' );
}

# Asked by sendEvent, in an event's fork, for each phone or open connection
# it is about to send to: 1 to send, 0 not to.
sub allows {
  my ( $alarm, $ac ) = @_;
  return 1 if !enabled();
  return 1 if ( $ac->{type} // 0 ) == MQTT;

  my ( $ok, $why ) = eval { _decide( $alarm, $ac ) };
  if ($@) {
    ( my $err = $@ ) =~ s/\s+$//;
    main::Error("Alert rules: the rules couldn't be read, so this alert is sent as it was before them: $err");
    return 1;
  }
  return 1 if $ok;

  my $who = defined $ac->{user} && $ac->{user} ne '' ? "$ac->{user}'s phone" : 'a phone with no user yet';
  $who = defined $ac->{user} && $ac->{user} ne '' ? "$ac->{user}'s open connection" : 'an open connection'
    if ( $ac->{type} // 0 ) == WEB;
  my $camera = defined $alarm->{Name} && $alarm->{Name} ne '' ? $alarm->{Name} : 'camera ' . ( $alarm->{MonitorId} // '?' );
  main::Info("Alert rules: no alert to $who for $camera: $why");
  return 0;
}

sub _hash { return sha256_hex( Encode::encode_utf8( $_[0] ) ); }

sub _utc {
  my $t = shift;
  return undef if !defined $t || ref($t) || $t !~ /^\d+$/ || !$t;
  return strftime( '%Y-%m-%d %H:%M:%S', gmtime($t) );
}

sub _cut {
  my ( $str, $max ) = @_;
  return undef if !defined $str || ref($str) || $str eq '';
  return substr( $str, 0, $max );
}

# The parent, when a fork reports a push it sent to a token.
sub pushed {
  my $token = shift;
  return if !enabled() || !defined $token || $token eq '';
  $pushed{ _hash($token) } = time();
  return;
}

# Forget phones: their tokens out of the token file, and out of what the
# parent holds. A phone that is connected right now keeps its connection,
# without the token, so it gets no push; it pairs again when its app next
# registers.
sub _forget {
  my %drop = map { $_ => 1 } @_;
  {
    my $lock = ZmEventNotification::FCM::_lockTokenFile();
    my $file = ZmEventNotification::FCM::readTokenFile();
    if ( $file && ref( $file->{tokens} ) eq 'HASH' ) {
      delete @{ $file->{tokens} }{ keys %drop };
      ZmEventNotification::FCM::writeTokenFile($file);
    }
  }
  foreach my $ac (@main::active_connections) {
    next if ref($ac) ne 'HASH' || !defined $ac->{token} || !$drop{ $ac->{token} };
    if ( !exists $ac->{conn} || $ac->{state} == INVALID_CONNECTION ) {
      $ac->{state} = PENDING_DELETE;
    } else {
      $ac->{type}  = WEB;
      $ac->{token} = '';
    }
  }
  return;
}

sub _phones {
  my $db   = _settings()->{db};
  my $file = ZmEventNotification::FCM::readTokenFile();
  return if !$file || ref( $file->{tokens} ) ne 'HASH';

  my %token = map { _hash($_) => $_ } keys %{ $file->{tokens} };
  my %row   = map { $_->{token_hash} => $_ } @{
    _rows("SELECT token_hash, username, platform, app_version, profile, first_seen, last_seen, `remove` FROM `$db`.alert_phones")
  };

  # Remove, from the page or the API
  my @removed = grep { $row{$_}{remove} } keys %row;
  if (@removed) {
    my @tokens = grep { defined } @token{@removed};
    _forget(@tokens) if @tokens;
    foreach my $hash (@removed) {
      _do( "DELETE FROM `$db`.alert_phones WHERE token_hash = ? AND `remove` = 1", $hash );
      my $whose = defined $row{$hash}{username} ? "$row{$hash}{username}'s phone" : 'a phone with no user';
      main::Info("Alert rules: $whose was removed, and gets no more alerts until its app pairs again");
      delete $row{$hash};
      delete $token{$hash};
    }
  }

  # A phone in the token file gets a row, kept as the file has it
  my @columns = qw(username platform app_version profile first_seen last_seen);
  foreach my $hash ( keys %token ) {
    my $t = $file->{tokens}{ $token{$hash} };
    $t = {} if ref($t) ne 'HASH';
    my %want = (
      username    => _cut( $t->{user}, 64 ),
      platform    => _cut( $t->{platform}, 16 ) // 'unknown',
      app_version => _cut( $t->{appversion}, 32 ) // 'unknown',
      profile     => _cut( $t->{profile}, 64 ),
      first_seen  => _utc( $t->{paired} ),
      last_seen   => _utc( $t->{seen} ),
    );
    my $have = $row{$hash};
    next if $have && !grep { ( $have->{$_} // "\0" ) ne ( $want{$_} // "\0" ) } @columns;
    _do(
      "INSERT INTO `$db`.alert_phones (token_hash, " . join( ', ', @columns ) . ') VALUES (?, ?, ?, ?, ?, ?, ?)'
        . ' ON DUPLICATE KEY UPDATE ' . join( ', ', map {"$_ = VALUES($_)"} @columns ),
      $hash, @want{@columns}
    );
  }

  # A phone no longer in the token file (the push service refused it, and so
  # the event server dropped it) loses its row
  foreach my $hash ( grep { !exists $token{$_} } keys %row ) {
    _do( "DELETE FROM `$db`.alert_phones WHERE token_hash = ?", $hash );
  }

  foreach my $hash ( keys %pushed ) {
    _do( "UPDATE `$db`.alert_phones SET last_push = ? WHERE token_hash = ?", _utc( $pushed{$hash} ), $hash );
    delete $pushed{$hash};
  }
  return;
}

# The parent, on each of its ticks: every TICK_SECONDS, and the first time.
sub tick {
  return if !enabled() || !$fcm_config{enabled};
  my $now = time();
  return if $now - $last_tick < TICK_SECONDS;
  $last_tick = $now;
  if ( !eval { _phones(); 1 } ) {
    ( my $err = $@ ) =~ s/\s+$//;
    main::Error("Alert rules: the list of paired phones wasn't brought up to date, trying again in a while: $err");
  }
  return;
}

1;
