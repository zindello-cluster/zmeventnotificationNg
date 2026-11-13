#!/bin/sh
# The event server's Perl tests, run inside the ZoneMinder image: its Perl and its modules are the
# ones the event server runs with in the pod. The checkout is mounted read-only.
#   - Upstream's own (t/) first, unchanged, with nothing in the container reaching the network.
#   - Then ours (alert-rules/t/), which need a database for the rules and the list of phones: a
#     throwaway MariaDB on a network of its own, which is all they can reach.
# --init: upstream's hook tests leave orphans for process 1 to reap, and prove doesn't.
#
#   alert-rules/tests/perl.sh <zoneminder image>
set -eu
image=$1
cd "$(git rev-parse --show-toplevel)"
net=es-perl-$$
db=es-perl-db-$$
pass=throwaway

docker run --rm --init --network none -v "$PWD:/src:ro" -w /src --entrypoint prove "$image" -I t/lib -I . -r t/

cleanup() {
  docker rm -f "$db" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create --internal "$net" >/dev/null
docker run -d --name "$db" --network "$net" -e MARIADB_ROOT_PASSWORD=$pass \
  docker.io/library/mariadb:12.3.3@sha256:d46e102fa8b9b72bfcdeb56f9dd538742092119dc8b11f31fe662605cd234cd9 >/dev/null
# The image's own readiness check, over TCP: the entrypoint's temporary server doesn't pass it.
for i in $(seq 60); do
  docker exec "$db" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
  sleep 2
done
docker exec "$db" healthcheck.sh --connect --innodb_initialized

# Given a database, none of ours may skip.
out=$(mktemp)
rc=0
docker run --rm --init --network "$net" -v "$PWD:/src:ro" -w /src \
  -e ALERT_RULES_TEST_DB_HOST="$db" -e ALERT_RULES_TEST_DB_USER=root -e ALERT_RULES_TEST_DB_PASSWORD=$pass \
  --entrypoint prove "$image" -I t/lib -I . -r alert-rules/t/ > "$out" 2>&1 || rc=$?
cat "$out"
if grep -q 'skipped' "$out"; then echo "one of our tests was skipped" >&2; rc=1; fi
rm -f "$out"
exit $rc
