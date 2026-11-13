# What our tests share (alert-rules/t/): upstream's stubs and fixtures, a log
# that can be read back, the config with the rules on or off, and, for the
# tests that need one, the throwaway MariaDB alert-rules/tests/perl.sh starts.
package AlertRulesTest;
use strict;
use warnings;
use FindBin;
use File::Spec;
use YAML::XS;
use Test::More;

use lib "$FindBin::Bin/../../t/lib";
require StubZM;

use ZmEventNotification::Config qw(:all);

our @log;    # [ level, message ]
{
  no warnings 'redefine';
  *main::Info    = sub { push @log, [ 'info',    $_[0] ] };
  *main::Warning = sub { push @log, [ 'warning', $_[0] ] };
  *main::Error   = sub { push @log, [ 'error',   $_[0] ] };
}

sub logged {
  my ( $level, $like ) = @_;
  return scalar grep { $_->[0] eq $level && $_->[1] =~ $like } @log;
}

# Upstream's test config, with our section when one is given.
sub config {
  my $alert_rules = shift;
  my $fixtures    = File::Spec->catdir( $FindBin::Bin, '..', '..', 't', 'fixtures' );
  my $cfg         = YAML::XS::LoadFile( File::Spec->catfile( $fixtures, 'test_es.yml' ) );
  $ZmEventNotification::Config::secrets = YAML::XS::LoadFile( File::Spec->catfile( $fixtures, 'test_secrets.yml' ) );
  $cfg->{alert_rules} = $alert_rules if $alert_rules;
  loadEsConfigSettings($cfg);
  $ZmEventNotification::Config::config_obj = $cfg;
  ZmEventNotification::AlertRules::_reset() if defined &ZmEventNotification::AlertRules::_reset;
  @log = ();
  return $cfg;
}

# The throwaway MariaDB: ZoneMinder's users in one database, our tables in
# another, both made new. Returns the connection the event server would hold
# (to ZoneMinder's database), or skips the whole file when no database is
# given. perl.sh always gives one, so CI never skips.
sub database {
  my $host = $ENV{ALERT_RULES_TEST_DB_HOST}
    or plan skip_all => 'no database given (alert-rules/tests/perl.sh starts one)';
  require DBI;
  my @login = ( $ENV{ALERT_RULES_TEST_DB_USER} // 'root', $ENV{ALERT_RULES_TEST_DB_PASSWORD} // '' );
  my $root  = DBI->connect( "DBI:mysql:host=$host", @login, { RaiseError => 1, PrintError => 0 } );
  my ( $zm, $ours ) = ( "zm_test_$$", "alerts_test_$$" );
  $root->do("CREATE DATABASE `$_`") for $zm, $ours;
  $root->do("CREATE TABLE `$zm`.Users (Id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, Username VARCHAR(64) NOT NULL UNIQUE)");

  open( my $fh, '<', File::Spec->catfile( $FindBin::Bin, 'schema.sql' ) ) or die "schema.sql: $!";
  my $schema = do { local $/; <$fh> };
  close($fh);
  $schema =~ s/--[^\n]*//g;
  $root->do("USE `$ours`");
  $root->do($_) for grep {/\S/} split /;/, $schema;
  $root->disconnect();

  # As the event server connects (ZoneMinder's zmDbConnect): errors returned,
  # not raised, and text as text.
  my $dbh = DBI->connect( "DBI:mysql:database=$zm;host=$host", @login, { RaiseError => 0, PrintError => 0, mysql_enable_utf8mb4 => 1 } )
    or die $DBI::errstr;
  return ( $dbh, $zm, $ours );
}

sub drop_databases {
  my ( $dbh, @names ) = @_;
  $dbh->do("DROP DATABASE IF EXISTS `$_`") for @names;
}

1;
