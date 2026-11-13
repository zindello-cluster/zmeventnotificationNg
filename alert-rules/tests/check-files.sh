#!/bin/sh
# The ZoneMinder image's event server is upstream's at <release>: zmeventnotification.pl and every
# ZmEventNotification module byte for byte (Version.pm with the release the installer writes into
# it), and no module upstream's tag hasn't got. Our image is laid over exactly these, so a
# ZoneMinder image that changed them, or carries another release, fails here rather than being
# silently overwritten.
#
#   alert-rules/tests/check-files.sh <release tag> <zoneminder image>
set -eu
release=$1
image=$2
bin=/usr/bin/zmeventnotification.pl
lib=/usr/share/perl5/ZmEventNotification

tmp=$(mktemp -d)
cid=$(docker create "$image")
trap 'docker rm -f "$cid" >/dev/null; rm -r "$tmp"' EXIT
docker cp -q "$cid:$bin" "$tmp/zmeventnotification.pl"
docker cp -q "$cid:$lib" "$tmp/ZmEventNotification"
version=$(git show "$release:VERSION" | tr -d '[:space:]')

status=0
same() { # <file at the tag> <the image's copy> <its path in the image>
  if [ "$1" = ZmEventNotification/Version.pm ]; then
    git show "$release:$1" | sed "s/^\(.*\)\$FALLBACK_VERSION = '.*';$/\1\$FALLBACK_VERSION = '$version';/" > "$tmp/.want"
  else
    git show "$release:$1" > "$tmp/.want"
  fi
  if [ ! -f "$2" ]; then echo "MISSING in the ZoneMinder image: $3" >&2; status=1
  elif ! cmp -s "$tmp/.want" "$2"; then echo "CHANGED in the ZoneMinder image: $3 differs from upstream's at $release" >&2; status=1
  else echo "ok: $3"
  fi
}
same zmeventnotification.pl "$tmp/zmeventnotification.pl" "$bin"
for f in $(git ls-tree --name-only "$release" ZmEventNotification/ | grep '\.pm$'); do
  same "$f" "$tmp/$f" "$lib/${f#ZmEventNotification/}"
done
for f in "$tmp"/ZmEventNotification/*; do
  name=${f##*/}
  git cat-file -e "$release:ZmEventNotification/$name" 2>/dev/null \
    || { echo "EXTRA in the ZoneMinder image: $lib/$name isn't in upstream's $release" >&2; status=1; }
done
test "$status" = 0 || exit "$status"
echo "the ZoneMinder image's event server is upstream's $release ($version)"
