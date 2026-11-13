# Alert rules: our fork of the event server

This is [ZoneMinder/zmeventnotificationNg](https://github.com/ZoneMinder/zmeventnotificationNg)
(GPL-2.0-or-later), forked for alert rules on security.zindello.com.au: a push goes to a phone
only when its user has that camera, and a type found in the event, switched on. The event server
is where a push is decided, and upstream's keeps no user against a phone. Kept until upstream has
the change (cluster-docs: `spec/layout.md`, O431, K89, `docs/runbooks/event-server-fork.md`; the
design is `external-security.zindello.com.au`'s
[`docs/alert-rules.md`](https://github.com/zindello-cluster/external-security.zindello.com.au/blob/main/docs/alert-rules.md)).
It's a feature that could go upstream, so it's kept as small commits that a pull request could
carry.

## Our commits

One new module, and a few lines where upstream's code calls it, each marked `zindello-cluster` in
a comment where it sits, so a new upstream release merges cleanly:

1. **The alert rules** (`ZmEventNotification/AlertRules.pm`, new). Reads the rules and decides:
   all of the user's alerts off, no push; the user's row for the camera, else the default row,
   and its switch off, no push; otherwise a push if one of the types the hook found is in the
   row. And it keeps the list of paired phones the page shows (`alert_phones`: a hash of each
   token, never the token), and forgets a phone the page or the API marked for Remove. Off unless
   the event server's config turns it on:
   ```yaml
   alert_rules:
     enable: "yes"
     database: detector
   ```
   With it off nothing of ours runs. If the rules can't be read an alert is sent as it was before
   them, and the log says so.
2. **The sign-in keeps the user** (`WebSocketHandler.pm`). Upstream checks the user and password
   and forgets them; ours keeps the name on the connection, only when it was checked against
   ZoneMinder's users, and hands it on when the phone registers its token.
3. **The token file keeps the user** (`FCM.pm`), with when the phone paired and last registered,
   and it's read back at start. Upstream's own calls write what they always did.
4. **`sendEvent` asks the rules** (`HookProcessor.pm`) before it sends or claims the interval, for
   pushes and the app's open connection, at the start and the end of an event. MQTT is untouched.
5. **The parent's tick** (`zmeventnotification.pl`) brings the list of phones up to date every 30
   seconds, and notes each push a fork reports for "last alert".

`git log $(cat alert-rules/UPSTREAM_RELEASE)..alert-rules -- zmeventnotification.pl ZmEventNotification`
lists them.

## The branches

- **`alert-rules`,** the default: an upstream release, our commits, and our build.
  `alert-rules/UPSTREAM_RELEASE` names the release: the one the ZoneMinder image carries
  (`alert-rules/ZONEMINDER_IMAGE`, the image `zindello-cluster/zoneminder` is built on), not
  upstream's newest. The event server's files must match the rest of what that image holds, its
  hook scripts and pyzm.
- **`master`:** upstream's, only ever synced from upstream. Nothing of ours is merged to it.

Upstream's own workflows are deleted on `alert-rules`, and GitHub never registered them in the
fork, so there was nothing to switch off; ours are `.github/workflows/alert-rules-*`.

## The image

A merge to `alert-rules` builds `ghcr.io/zindello-cluster/zmeventnotificationng:<release>`: the
event server's own files, `zmeventnotification.pl` and its `ZmEventNotification` modules, under
`/event-server` on a BusyBox pinned by digest, which is there only for `cp`
(`alert-rules/Dockerfile`, `alert-rules/export.sh`). Nothing is compiled. The chart copies them
into a volume as the pod starts and mounts that, read-only, over the ZoneMinder image's copies
(`/usr/bin/zmeventnotification.pl`, `/usr/share/perl5/ZmEventNotification`).

Before building, CI:
- checks that the ZoneMinder image's event server is upstream's at our release, byte for byte, so
  an image that changed it, or carries another release, fails the build rather than being
  overwritten (`tests/check-files.sh`);
- runs the event server's tests inside the ZoneMinder image, whose Perl is the one it runs with:
  upstream's, unchanged and with nothing reaching the network, then ours in `alert-rules/t/`
  against a throwaway MariaDB: each line of the rule, the token file, the sign-in, the list of
  phones and Remove (`tests/perl.sh`). `alert-rules/t/schema.sql` is a copy of the chart's tables.

After building, it lays the image over the ZoneMinder image as the chart does and starts
ZoneMinder against a throwaway MariaDB (`tests/smoke.sh`): the event server must be running, at
our release, with no error in its log and the rules off; then, with the rules on, a pretend phone
(`tests/phone.py`) signs in and registers, is listed under its user, and Remove forgets it. A
pull request into the branch runs the same, without pushing.

The digest is in the run's summary. `external-security.zindello.com.au` pins it; a pull request
there moves it, and merging and syncing that is the deploy. The image is private on GHCR.

## A new upstream release

1. Each morning the `upstream` workflow opens an issue when upstream has a release newer than
   `UPSTREAM_RELEASE`.
2. Read its release notes. If upstream now has what our commits do, stop here and retire the fork
   (below). Otherwise it waits for the ZoneMinder image.
3. When `zindello-cluster/zoneminder` moves to a team image with a newer event server, sync
   `master` (the **Sync fork** button, or `gh repo sync zindello-cluster/zmeventnotificationNg -b master`).
4. `alert-rules/sync.sh <release> <that image by digest>` merges the release into a new branch,
   `upstream-<release>`, keeps upstream's workflows out, and records the release and the image. A
   conflict in our files stops it, naming them.
5. Push it and open a pull request into `alert-rules` with the release notes, risks and
   rollback. CI checks, tests, builds and smoke-tests it; the owner merges it.
6. The merge builds the image; then one pull request in the chart moves both digests, ZoneMinder's
   and the event server's, together.

## Retiring the fork

When upstream's event server has the change, or ZoneMinder keeps each phone against its user
itself and the rules move there: take the event server's image and the step that lays it over out
of `external-security.zindello.com.au`, archive this repo, and take its row out of the layout.
