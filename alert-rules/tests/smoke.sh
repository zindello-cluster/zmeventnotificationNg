#!/bin/sh
# Our image laid over the ZoneMinder image the way the chart does it, and ZoneMinder started
# against a throwaway MariaDB with its event server on (ALERT-RULES.md, "The image"):
#   - the files are copied out by our image's own cp, as ZoneMinder's user (the chart's init
#     container), and mounted read-only over /usr/bin/zmeventnotification.pl and
#     /usr/share/perl5/ZmEventNotification;
#   - ZoneMinder starts as that user (PUID, PGID: its start re-owns the image's files, and must
#     leave the read-only ones alone);
#   - the event server is running, at this branch's release, listening, with no error in its log,
#     and with the alert rules off, as they are unless its config turns them on;
#   - with the rules turned on and the tables there (alert-rules/t/schema.sql): a pretend phone
#     (tests/phone.py) signs in as a ZoneMinder user and registers, and is listed in alert_phones
#     under that user, by its token's hash; Remove on that row takes it out of the token file
#     and off the list.
#
#   alert-rules/tests/smoke.sh <zoneminder image> <event server image>
set -eu
zm=$1
es=$2
cd "$(git rev-parse --show-toplevel)"
version=$(tr -d '[:space:]' < VERSION)
net=es-smoke-$$
pass=throwaway
uid=1000
overlay=$(mktemp -d)
chmod 777 "$overlay"

cleanup() {
  docker rm -f es-smoke es-smoke-db >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  # The copies belong to ZoneMinder's user, not ours.
  docker run --rm --user 0 -v "$overlay:/overlay" "$es" rm -r /overlay/bin /overlay/perl5 >/dev/null 2>&1 || true
  rmdir "$overlay" 2>/dev/null || true
}
trap cleanup EXIT
docker rm -f es-smoke es-smoke-db >/dev/null 2>&1 || true

# The chart's init container: not root, a read-only root filesystem, no capabilities.
docker run --rm --user "$uid:$uid" --read-only --cap-drop ALL -v "$overlay:/overlay" "$es" cp -R /event-server/. /overlay/
test -x "$overlay/bin/zmeventnotification.pl" || { echo "the copy isn't executable" >&2; exit 1; }

docker network create "$net" >/dev/null
docker run -d --name es-smoke-db --network "$net" -e MARIADB_ROOT_PASSWORD=$pass -e MARIADB_DATABASE=zm \
  -e MARIADB_USER=zmuser -e MARIADB_PASSWORD=$pass docker.io/library/mariadb:12.3.3@sha256:d46e102fa8b9b72bfcdeb56f9dd538742092119dc8b11f31fe662605cd234cd9 >/dev/null
# The image's own readiness check, over TCP: the entrypoint's temporary server doesn't pass it.
for i in $(seq 60); do
  docker exec es-smoke-db healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
  sleep 2
done
docker exec es-smoke-db healthcheck.sh --connect --innodb_initialized
sql() { docker exec -i es-smoke-db mariadb -uroot -p$pass "$@"; }
sql -e "SET GLOBAL log_bin_trust_function_creators=1;"

docker run -d --name es-smoke --network "$net" --shm-size 256m -e TZ=Australia/Sydney \
  -e ZM_DB_HOST=es-smoke-db -e ZM_DB_NAME=zm -e ZM_DB_USER=zmuser -e ZM_DB_PASS=$pass \
  -e PUID=$uid -e PGID=$uid -e ZM_ES_ENABLE=1 \
  -v "$overlay/bin/zmeventnotification.pl:/usr/bin/zmeventnotification.pl:ro" \
  -v "$overlay/perl5/ZmEventNotification:/usr/share/perl5/ZmEventNotification:ro" "$zm" >/dev/null
in_zm() { docker exec es-smoke "$@"; }
fail() {
  echo "FAILED: $1" >&2
  docker logs es-smoke 2>&1 | tail -n 40 >&2
  in_zm sh -c 'tail -n 40 /var/log/zm/zmeventnotification.log /var/log/zm/zmdc.log 2>/dev/null' >&2 || true
  exit 1
}
for i in $(seq 120); do
  if in_zm curl -sf -o /dev/null http://127.0.0.1/zm/ 2>/dev/null; then break; fi
  sleep 2
done
in_zm curl -sf -o /dev/null http://127.0.0.1/zm/ || fail "ZoneMinder didn't start"
echo "ok: ZoneMinder started with our files mounted read-only"

# What runs is what we built.
for f in bin/zmeventnotification.pl $(cd "$overlay" && find perl5 -type f | sort); do
  case "$f" in bin/*) at=/usr/bin/${f#bin/} ;; *) at=/usr/share/$f ;; esac
  docker exec -i es-smoke cmp -s - "$at" < "alert-rules/files/$f" || fail "$at in the container isn't alert-rules/files/$f"
done
echo "ok: the container's event server is this build's"

log=/var/log/zm/zmeventnotification.log
wait_log() { # <pattern> <what>
  for i in $(seq 60); do
    if in_zm grep -q -- "$1" "$log" 2>/dev/null; then echo "ok: $2"; return; fi
    sleep 2
  done
  fail "$2 ($1 not in $log)"
}
wait_log "Event Notification daemon v $version starting" "the event server started, at $version"
wait_log "Web Socket Event Server listening on port 9000" "it listens for the app"
in_zm pgrep -f /usr/bin/zmeventnotification.pl >/dev/null || fail "the event server isn't running"
no_errors() {
  if in_zm grep -E '\.(ERR|FAT|PNC) ' "$log"; then fail "errors in the event server's log"; fi
}
no_errors
if in_zm grep -q 'Alert rules' "$log"; then fail "the alert rules ran without being turned on"; fi
echo "ok: nothing but information in its log, and nothing from the alert rules: they're off"

# The rules on, as the chart turns them on: the tables beside ZoneMinder's, in a database its own
# user can use, and our section in the event server's config.
sql -e "CREATE DATABASE detector; GRANT ALL ON detector.* TO 'zmuser'@'%';"
sql detector < alert-rules/t/schema.sql
docker exec -i --user 0 es-smoke sh -c 'cat >> /config/es/zmeventnotification.yml' <<'YAML'

alert_rules:
  enable: "yes"
  database: detector
YAML
in_zm sh -c ": > $log"
in_zm zmdc.pl restart zmeventnotification.pl >/dev/null
wait_log "Alert rules are on, kept in the detector database" "restarted with the alert rules on"
wait_log "Web Socket Event Server listening on port 9000" "it listens for the app"

# Is that phone listed, under that user? (The first update is at the event server's start, the
# next ones every 30 seconds.)
token="smoke-test-token-$$-0123456789abcdef"
hash=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
listed() { sql -N -e "SELECT COALESCE(username, '') FROM detector.alert_phones WHERE token_hash = '$hash' AND \`remove\` = 0"; }
in_file() { in_zm grep -q -- "$token" /config/es/push/tokens.txt; }
wait_for() { # <what> <command...>
  what=$1; shift
  for i in $(seq 40); do
    if "$@"; then echo "ok: $what"; return; fi
    sleep 2
  done
  fail "$what"
}

# A fresh ZoneMinder's own user. Its sign-in is checked against ZoneMinder's users.
docker exec -i es-smoke python3 - admin admin "$token" < alert-rules/tests/phone.py || fail "the pretend phone couldn't sign in and register"
in_file || fail "the phone's token isn't in the token file"
in_zm python3 -c '
import json, sys
phone = json.load(open("/config/es/push/tokens.txt"))["tokens"][sys.argv[1]]
assert phone.get("user") == "admin", phone.get("user")
assert phone.get("paired") and phone.get("seen"), sorted(phone)
' "$token" || fail "the token file doesn't have the phone's user and when it paired"
echo "ok: the token file keeps the phone's user and when it paired"
is_admins() { [ "$(listed)" = admin ]; }
wait_for "the phone is listed under the user who signed in on it, by its token's hash" is_admins
[ "$(sql -N -e "SELECT COUNT(*) FROM detector.alert_phones")" = 1 ] || fail "more than the one phone is listed"

if docker exec -i es-smoke python3 - admin not-the-password "$token-2" < alert-rules/tests/phone.py >/dev/null 2>&1; then
  fail "a wrong password signed in"
fi
echo "ok: a wrong password doesn't sign in"

# Remove, as the page and the API do it.
sql -e "UPDATE detector.alert_phones SET \`remove\` = 1 WHERE token_hash = '$hash'"
gone() { [ "$(sql -N -e "SELECT COUNT(*) FROM detector.alert_phones")" = 0 ] && ! in_file; }
wait_for "Remove takes the phone out of the token file and off the list" gone
in_zm grep -q "Alert rules: admin's phone was removed" "$log" || fail "the removal isn't in the log"
in_zm pgrep -f /usr/bin/zmeventnotification.pl >/dev/null || fail "the event server isn't running"
no_errors
echo "ok: nothing but information in its log"
echo "smoke test passed"
