#!/usr/bin/env bash
# Merges an upstream event server release into a new branch off alert-rules, ready for a pull
# request (ALERT-RULES.md; cluster-docs docs/runbooks/event-server-fork.md):
#   alert-rules/sync.sh v7.0.36 ghcr.io/zoneminder/zoneminder:1.38.7-es@sha256:…
# The branch follows the release the ZoneMinder image carries, so the second argument is that
# image, by digest: the one zindello-cluster/zoneminder's ai-live-detection/Dockerfile is FROM.
# Upstream's workflows stay off this branch, so any the merge brings back are removed again. Any
# other conflict stops here, for a person to resolve. Run from a clone of this repo with a clean
# tree; it pushes nothing.
set -euo pipefail
release=${1:?usage: alert-rules/sync.sh <release tag> <zoneminder image by digest>}
image=${2:?usage: alert-rules/sync.sh <release tag> <zoneminder image by digest>}
[[ $release =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a release tag: $release" >&2; exit 1; }
[[ $image =~ ^ghcr\.io/zoneminder/zoneminder:[^@]+@sha256:[0-9a-f]{64}$ ]] || { echo "not the ZoneMinder team's image by digest: $image" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"
[ -z "$(git status --porcelain)" ] || { echo "the working tree isn't clean" >&2; exit 1; }

git fetch -q origin alert-rules
git fetch -q --no-tags https://github.com/ZoneMinder/zmeventnotificationNg.git "refs/tags/$release:refs/tags/$release"
git switch -q -c "upstream-$release" origin/alert-rules

git merge -q --no-ff --no-commit "$release" || echo "the merge conflicts; checking where"
# Upstream's own workflows: everything in .github/workflows that isn't ours, conflicting or not.
git ls-files -- .github/workflows | { grep -v '^\.github/workflows/alert-rules-' || true; } | sort -u | xargs -r git rm -qf --
if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
  echo "these still conflict; resolve them, then git commit, and re-run the steps after the merge in this script by hand:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 1
fi
git commit -q -m "Merge upstream zmeventnotificationNg $release"

echo "$release" > alert-rules/UPSTREAM_RELEASE
echo "$image" > alert-rules/ZONEMINDER_IMAGE
git commit -q -m "alert-rules: upstream $release, checked against $image" alert-rules/UPSTREAM_RELEASE alert-rules/ZONEMINDER_IMAGE

echo "ready: push upstream-$release and open a pull request into alert-rules; its CI checks the image, tests, builds and smoke-tests it"
