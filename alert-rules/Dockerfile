# alert-rules: the event server's own files, for the chart to lay over the ZoneMinder image's
# copies as the pod starts (ALERT-RULES.md; cluster-docs O431, K89). Nothing is compiled: the files
# are Perl.
#
# BusyBox is here only for `cp`: an init container copies /event-server into a volume, which
# ZoneMinder's container mounts over /usr/bin/zmeventnotification.pl and
# /usr/share/perl5/ZmEventNotification. Pinned by digest; it moves by pull request.
FROM docker.io/library/busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4

# files/ is written by CI (alert-rules/export.sh): bin/zmeventnotification.pl and
# perl5/ZmEventNotification/*.pm from this branch, the release set in Version.pm as upstream's
# installer does.
COPY --chown=root:root files/ /event-server/

USER 65534:65534
CMD ["cp", "-R", "/event-server/.", "/overlay/"]
