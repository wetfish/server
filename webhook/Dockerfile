# Deploy webhook listener (https://github.com/adnanh/webhook), packaged by
# Debian.
#
# It receives GitHub push webhooks and only writes trigger files. It has no
# Docker access; the host's systemd units run the deploys.
#
# The hook definitions, with each project's secret, are generated on the
# server into state/webhook/hooks.json and mounted read-only, so they never
# enter the image.

FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends webhook \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 start.sh /usr/local/bin/start-webhook
COPY --chmod=755 request-deploy.sh /usr/local/bin/request-deploy

ENTRYPOINT ["/usr/local/bin/start-webhook"]
