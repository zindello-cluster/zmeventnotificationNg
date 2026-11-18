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
#     follow: "yes"        # off unless set: while an event is on, push the
#                          # moment a type joins its alarm (below)
#     follow_seconds: 1    # how often a running event is looked at
#     pictures: /run/live-pictures  # where live detection leaves the frame
#                          # each type first alarmed on, its boxes drawn;
#                          # unset, no pictures
#     hold_seconds: 5      # live detection's alarm.holdSeconds: an alarm
#                          # stays on this long after its last sighting
#
# Following an event (the owner, 18 November 2026: "If a current event is
# firing, and a category we notify about shows up, it should be immediate.";
# cluster-docs O477). Live detection writes each type that raises or holds a
# camera's alarm to detector_alarms, in the same database. While an event is
# on, its fork asks here every follow_seconds which types have alarmed on its
# camera since it started; a type not yet told of in this event is sent on its
# own, through sendEvent and so through the rules, to the phones that haven't
# had this event's push: one push per event for each phone (the owner: "Per
# event", cluster-docs O481). The frame it first alarmed on becomes the
# event's objdetect.jpg, as zm_detect's picture was, if the event has none, or
# if it raised the event's first push (the owner: "Let's go with C."; O478).
#
# One alarm, one push (the owner: "Check it and fix please."; cluster-docs
# O500). ZoneMinder's events and live detection's alarms don't line up: an
# alarm may run on through several events (ZoneMinder starts a new one every
# few seconds), and an event may hold more than one alarm. So:
#   - a phone is told of an alarm once, whichever event it's in: each alarm a
#     push is about is remembered for that phone (push/alarms_sent.json) and
#     not told again;
#   - an event is followed until ZoneMinder moves on to the next one, not only
#     while its alarm is on, so a second alarm in the same event is seen;
#   - an event's types are those whose alarm was on during it (their last
#     sighting, plus hold_seconds, at or after its start, and their first
#     before the next event's start); an alarm raised once the event is at
#     least MinSectionLength old waits up to 3 s for the event ZoneMinder
#     opens for it;
#   - an event that ends with no alarm frames loses the tags, notes and
#     picture given to it.
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
use Fcntl ();
use Time::Local qw(timegm);
use ZmEventNotification::Constants qw(:all);
use ZmEventNotification::Config qw(:all);
use ZmEventNotification::FCM ();

use constant TICK_SECONDS  => 30;    # how often the phones table is brought up to date
use constant CACHE_SECONDS => 10;    # how long a rule that was read is used

my $settings;
my %cache;
my %event_start;    # event id -> { start, cause, next }: its start and the next event's, seconds since the epoch
my %pushed;
my $last_tick = 0;

sub _settings {
  return $settings if $settings;
  my ( $on, $db, $follow, $every, $pictures, $hold ) = ( 0, 'detector', 0, 1, undef, 0 );
  if ($config_obj) {
    $on     = config_get_val( $config_obj, 'alert_rules', 'enable', 'no' ) ? 1 : 0;
    $db     = config_get_val( $config_obj, 'alert_rules', 'database', 'detector' );
    $follow = config_get_val( $config_obj, 'alert_rules', 'follow', 'no' ) ? 1 : 0;
    $every  = config_get_val( $config_obj, 'alert_rules', 'follow_seconds', 1 );
    $pictures = config_get_val( $config_obj, 'alert_rules', 'pictures', undef );
    $hold     = config_get_val( $config_obj, 'alert_rules', 'hold_seconds', 0 );
  }
  if ( !defined $hold || $hold !~ /^\d+(\.\d+)?$/ ) {
    main::Error("Alert rules: hold_seconds must be a number of seconds; 0 it is");
    $hold = 0;
  }
  if ( !defined $every || $every !~ /^[1-9]\d*$/ ) {
    main::Error("Alert rules: follow_seconds must be a whole number of seconds, 1 or more; 1 it is");
    $every = 1;
  }
  if ( $on && $db !~ /^\w+$/ ) {
    main::Error("Alert rules: '$db' isn't a database's name, so the rules are off");
    $on = 0;
  }
  main::Info( "Alert rules are on, kept in the $db database" . ( $follow ? ", following each event every $every s" : '' ) ) if $on;
  return $settings = { on => $on, db => $db, follow => $on && $follow, every => $every, pictures => $pictures, hold => $hold };
}

sub enabled { return _settings()->{on}; }

# Whether a running event is followed, and how often, in whole seconds.
sub following      { return _settings()->{follow}; }
sub follow_seconds { return _settings()->{every}; }

# For tests: forget the settings and everything remembered.
sub _reset {
  $settings  = undef;
  %cache       = ();
  %pushed      = ();
  %event_start = ();
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
  return _once( $alarm, $ac, [ labels($alarm) ] ) if !$rule;
  return ( 0, 'the camera is switched off' ) if !$rule->{alerts};
  my @found = labels($alarm);
  return 1 if !@found;
  my @on = grep { $rule->{labels}{$_} } @found;
  return _once( $alarm, $ac, \@on ) if @on;
  return ( 0, join( ', ', @found ) . ( @found > 1 ? " aren't" : " isn't" ) . ' switched on for the camera' );
}

# The phone's key in push/alarms_sent.json: its token, or its connection.
sub _phone_key {
  my $ac = shift;
  return ( $ac->{token} // '' ) ne '' ? 'token:' . _hash( $ac->{token} ) : 'connection:' . ( $ac->{id} // '' );
}

# One alarm, one push for each phone: 1 if the alarms behind these types
# (the detections' `alarms`, live detection's raise times) include one this
# phone hasn't been told of, and then they're remembered for it; (0, why) if
# it has been told of them all. Detections without alarms (not ours) are
# always sent. Kept a day.
sub _once {
  my ( $alarm, $ac, $types ) = @_;
  my $det = $alarm->{DetectionJson};
  my %ids;
  if ( ref($det) eq 'HASH' && ref( $det->{alarms} ) eq 'HASH' ) {
    foreach my $t (@$types) {
      my $a = $det->{alarms}{$t};
      $ids{"$alarm->{MonitorId}:$_"} = 1 for ref($a) eq 'ARRAY' ? @$a : defined $a ? ($a) : ();
    }
  }
  return 1 if !%ids;
  my $file = $server_config{base_data_path} . '/push/alarms_sent.json';
  sysopen( my $fh, $file, Fcntl::O_RDWR() | Fcntl::O_CREAT(), 0600 ) or die "can't open $file: $!\n";
  flock( $fh, Fcntl::LOCK_EX() ) or die "can't lock $file: $!\n";
  my $raw  = do { local $/; <$fh> };
  my $sent = eval { decode_json($raw) } // {};
  my $now  = time();
  foreach my $p ( keys %$sent ) {
    delete @{ $sent->{$p} }{ grep { $now - $sent->{$p}{$_} > 86400 } keys %{ $sent->{$p} } };
    delete $sent->{$p} if !%{ $sent->{$p} };
  }
  my $key = _phone_key($ac);
  my @new = grep { !$sent->{$key}{$_} } keys %ids;
  $sent->{$key}{$_} = $now for @new;
  seek( $fh, 0, 0 );
  truncate( $fh, 0 );
  print $fh encode_json($sent);
  close($fh);
  return 1 if @new;
  return ( 0, 'it was told of this alarm already, in an earlier event' );
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

# The event: its start, its cause, and the next event's start on the camera
# once there is one (seconds since the epoch). ZoneMinder writes times in its
# own zone, which its connection has.
sub _event {
  my ( $eid, $mid ) = @_;
  my $e = $event_start{$eid};
  if ( !$e ) {
    my $rows = _rows( 'SELECT UNIX_TIMESTAMP(StartDateTime) AS t, Cause AS cause FROM Events WHERE Id = ?', $eid );
    die "no event $eid\n" if !@$rows || !defined $rows->[0]{t};
    my $msl = eval { _rows( 'SELECT MinSectionLength AS l FROM Monitors WHERE Id = ?', $mid )->[0]{l} };
    $e = $event_start{$eid} = { start => $rows->[0]{t}, cause => $rows->[0]{cause} // '', min_section => $msl // 10 };
  }
  if ( !defined $e->{next} ) {
    my $rows = _rows( 'SELECT UNIX_TIMESTAMP(StartDateTime) AS t FROM Events WHERE MonitorId = ? AND Id > ? ORDER BY Id LIMIT 1', $mid, $eid );
    $e->{next} = $rows->[0]{t} if @$rows && defined $rows->[0]{t};
  }
  return $e;
}

sub _utc6 {
  my $t = shift;
  my $s = POSIX::floor($t);
  return strftime( '%Y-%m-%d %H:%M:%S', gmtime($s) ) . sprintf( '.%06d', int( ( $t - $s ) * 1e6 + 0.5 ) % 1000000 );
}

sub _epoch {
  my ( $y, $mo, $d, $h, $mi, $s, $f ) = $_[0] =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)(?:\.(\d+))?/ or return undef;
  return timegm( $s, $mi, $h, $d, $mo - 1, $y ) + ( $f ? "0.$f" : 0 );
}

# The types whose live detection alarm was on during the event: their last
# sighting, plus hold_seconds, at or after its start, and their first before
# the next event's start. { label => { confidence, picture, alarms, inside } }:
# the frame it first alarmed on, if live detection kept one; its alarms' raise
# times; and whether every one of them was raised inside the event, after its
# start (raised: the newest). Dies if they can't be read.
sub alarmed {
  my ( $eid, $mid ) = @_;
  my $db   = _settings()->{db};
  my $e    = _event( $eid, $mid );
  my @bind = ( $mid, _utc6( $e->{start} - _settings()->{hold} ) );
  my $sql =
      "SELECT label, MAX(best_confidence) AS confidence,"
    . " SUBSTRING_INDEX(GROUP_CONCAT(picture ORDER BY raised_at, first_seen SEPARATOR '\\n'), '\\n', 1) AS picture,"
    . " GROUP_CONCAT(DISTINCT DATE_FORMAT(raised_at, '%Y-%m-%d %H:%i:%s.%f') ORDER BY raised_at SEPARATOR ',') AS alarms"
    . " FROM `$db`.detector_alarms WHERE monitor_id = ? AND last_seen >= ?";
  if ( defined $e->{next} ) {
    $sql .= ' AND first_seen < ?';
    push @bind, _utc6( $e->{next} );
  }
  my $rows = _rows( "$sql GROUP BY label", @bind );
  my %found;
  foreach (@$rows) {
    ( my $label = lc( $_->{label} // '' ) ) =~ s/^\s+|\s+$//g;
    $label = 'motorcycle' if $label eq 'motorbike';
    next if $label eq '';
    my @alarms = split /,/, $_->{alarms} // '';
    my @times  = grep {defined} map { _epoch($_) } @alarms;
    $found{$label} = {
      confidence => $_->{confidence},
      picture    => $_->{picture},
      alarms     => \@alarms,
      inside     => ( @times && !grep { $_ <= $e->{start} + 1 } @times ) ? 1 : 0,
      raised     => ( sort { $b <=> $a } @times )[0],
    };
  }
  return \%found;
}

# Whether a type should wait before it's told: its newest alarm was raised
# less than 3 s ago, once the event was at least the camera's
# MinSectionLength old, and ZoneMinder hasn't opened the next event yet.
# ZoneMinder opens a new event for an alarm that starts in an event that old,
# a moment after it's raised; the type is that event's, not this one's.
sub _waits {
  my ( $eid, $mid, $type ) = @_;
  my $e = _event( $eid, $mid );
  return 0 if defined $e->{next} || !defined $type->{raised};
  return 0 if $type->{raised} < $e->{start} + $e->{min_section} - 0.5;
  return time() - $type->{raised} < 3 ? 1 : 0;
}

# What has joined the event's alarm since this was last asked: (its text, as
# the hook's, its detections, with only those types and their alarms, and the
# picture of the first of them), or () when nothing new has. $told holds, for
# each type, the alarms already told of in this event, and is kept up to date:
# a type is new in a new alarm of it. A failed read is logged once for the
# event, and tried again.
sub joined {
  my ( $eid, $mid, $told ) = @_;
  my $now = eval { alarmed( $eid, $mid ) };
  if ( !$now ) {
    ( my $err = $@ // '' ) =~ s/\s+$//;
    main::Error("Alert rules: what has alarmed in event $eid couldn't be read, trying again: $err") if !$told->{"\0failed"}++;
    return;
  }
  my %fresh;
  foreach my $l ( keys %$now ) {
    next if ref( $told->{$l} ) eq 'HASH' && $told->{$l}{"\0any"};
    my @ids = grep { !( ref( $told->{$l} ) eq 'HASH' && $told->{$l}{$_} ) } @{ $now->{$l}{alarms} };
    $fresh{$l} = \@ids if @ids && !_waits( $eid, $mid, $now->{$l} );
  }
  my @new = sort { $now->{$b}{confidence} <=> $now->{$a}{confidence} || $a cmp $b } keys %fresh;
  return if !@new;
  foreach my $l (@new) { $told->{$l}{$_} = 1 for @{ $fresh{$l} } }
  my @score = map { 0 + sprintf( '%.2f', $now->{$_}{confidence} ) } @new;
  my ($picture) = grep { defined && $_ ne '' } map { $now->{$_}{picture} } @new;
  my $text  = 'detected:' . join( ' ', map { "$new[$_]:" . sprintf( '%d%%', $score[$_] * 100 + 0.5 ) } 0 .. $#new );
  main::Info("Alert rules: $text joined the alarm of event $eid");
  return ( $text,
    { labels => \@new, confidences => \@score, alarms => { map { $_ => $fresh{$_} } @new }, frame_id => 'alarm', source => 'live detection' },
    $picture );
}

# The event's alarm frames once ZoneMinder has closed it, or undef while it
# hasn't (waited for up to $tries seconds).
sub alarm_frames {
  my ( $eid, $tries ) = @_;
  for my $try ( 0 .. ( $tries // 5 ) ) {
    my $rows = eval { _rows( 'SELECT AlarmFrames AS af, EndDateTime AS ended FROM Events WHERE Id = ?', $eid ) };
    return $rows->[0]{af} if $rows && @$rows && defined $rows->[0]{ended};
    sleep(1) if $try < ( $tries // 5 );
  }
  return undef;
}

# An event that ended with no alarm frames had no alarm: the tags, the notes'
# texts and the picture it was given come off.
sub untell {
  my ( $eid, $labels, $texts ) = @_;
  my $ok = eval {
    foreach my $l (@$labels) {
      _do( 'DELETE et FROM Events_Tags et JOIN Tags t ON t.Id = et.TagId WHERE et.EventId = ? AND t.Name = ?', $eid, $l );
    }
    foreach my $t (@$texts) {
      _do( 'UPDATE Events SET Notes = TRIM(REPLACE(Notes, ?, \'\')) WHERE Id = ?', "$t ", $eid );
    }
    my $path = eval { _event_path($eid) };
    unlink("$path/objdetect.jpg") if $path && -e "$path/objdetect.jpg";
    1;
  };
  if ( !$ok ) {
    ( my $err = $@ // '' ) =~ s/\s+$//;
    main::Error("Alert rules: event $eid had no alarm, but what it was given couldn't all be taken off: $err");
    return 0;
  }
  main::Info( "Alert rules: event $eid had no alarm; its " . join( ', ', @$labels ) . ' taken off' ) if @$labels;
  return 1;
}

# The event's folder, from ZoneMinder (a sub of its own so tests can stand in).
sub _event_path {
  my $eid = shift;
  require ZoneMinder::Event;
  return ZoneMinder::Event->new($eid)->Path();
}

# The picture live detection kept, as the event's objdetect.jpg, which the
# phone app shows as its detection picture: only if it has none yet, or, with
# $replace, in place of one (the frame of the type that raised the event's
# first push, over one of a type nobody was sent). 1 if it was written.
sub picture_to_event {
  my ( $eid, $picture, $replace ) = @_;
  my $dir = _settings()->{pictures};
  return 0 if !$dir || !defined $picture || $picture !~ /^[\w.-]+\.jpg$/;
  my $ok = eval {
    my $path = _event_path($eid);
    die "no folder for event $eid\n" if !$path || !-d $path;
    my $to = "$path/objdetect.jpg";
    return 0 if -e $to && !$replace;
    require File::Copy;
    File::Copy::copy( "$dir/$picture", "$to.tmp" ) or die "copying $picture: $!\n";
    rename( "$to.tmp", $to ) or die "renaming it: $!\n";
    1;
  };
  if ( !defined $ok ) {
    ( my $err = $@ ) =~ s/\s+$//;
    main::Error("Alert rules: event ${eid}'s picture wasn't written: $err");
    return 0;
  }
  return $ok;
}

# The start's types and their alarms, as told of: into $told (see joined).
sub told_at_start {
  my ( $start, $told ) = @_;
  my $det = $start->{DetectionJson};
  foreach my $l ( labels($start) ) {
    my $a = ref($det) eq 'HASH' && ref( $det->{alarms} ) eq 'HASH' ? $det->{alarms}{$l} : undef;
    my @ids = ref($a) eq 'ARRAY' ? @$a : defined $a ? ($a) : ();
    $told->{$l}{$_} = 1 for @ids;
    $told->{$l}{"\0any"} = 1 if !@ids;    # a start without alarms (not ours): the type as a whole
  }
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
