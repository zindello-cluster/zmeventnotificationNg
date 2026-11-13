#!/bin/sh
# The event server's files from this checkout, laid out for the image (alert-rules/Dockerfile):
#   <out dir>/bin/zmeventnotification.pl
#   <out dir>/perl5/ZmEventNotification/*.pm
# Version.pm gets the release from VERSION, the one change upstream's installer makes to these
# files (install.sh, "Update Version.pm with the version from VERSION file").
#
#   alert-rules/export.sh <out dir>
set -eu
out=$1
cd "$(git rev-parse --show-toplevel)"
version=$(tr -d '[:space:]' < VERSION)

rm -rf "$out"
mkdir -p "$out/bin" "$out/perl5/ZmEventNotification"
install -m 755 zmeventnotification.pl "$out/bin/zmeventnotification.pl"
for f in ZmEventNotification/*.pm; do
  install -m 644 "$f" "$out/perl5/ZmEventNotification/"
done
sed "s/^\(.*\)\$FALLBACK_VERSION = '.*';$/\1\$FALLBACK_VERSION = '$version';/" ZmEventNotification/Version.pm \
  > "$out/perl5/ZmEventNotification/Version.pm"
grep -q "FALLBACK_VERSION = '$version';" "$out/perl5/ZmEventNotification/Version.pm" \
  || { echo "Version.pm: the release wasn't set" >&2; exit 1; }
chmod -R go-w "$out"
echo "exported $version into $out:"
(cd "$out" && find . -type f | sort)
