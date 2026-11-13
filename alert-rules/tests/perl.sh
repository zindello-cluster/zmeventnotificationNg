#!/bin/sh
# The event server's Perl tests, run inside the ZoneMinder image: its Perl and its modules are the
# ones the event server runs with in the pod. Upstream's own (t/) first, unchanged; then ours
# (alert-rules/t/), when there are any. The checkout is mounted read-only, and nothing in the
# container reaches the network. --init: upstream's hook tests leave orphans for process 1 to reap,
# and prove doesn't.
#
#   alert-rules/tests/perl.sh <zoneminder image>
set -eu
image=$1
cd "$(git rev-parse --show-toplevel)"
ours=
[ -n "$(find alert-rules/t -name '*.t' 2>/dev/null)" ] && ours=alert-rules/t/
docker run --rm --init --network none -v "$PWD:/src:ro" -w /src --entrypoint prove "$image" -I t/lib -I . -r t/ $ours
