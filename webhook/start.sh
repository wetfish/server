#!/bin/sh
# Starts the webhook listener with the hooks generated for this server's
# projects.
#
# -verbose keeps webhook running when no hooks are loaded, so a server with
# no projects yet still starts. webhook only reads hook files that loaded
# when it started, so the container is restarted whenever a project is
# added or removed.

set -eu

hooks=/hooks/hooks.json

if [ ! -f "$hooks" ]; then
    echo "No projects are registered on this server yet ($hooks does not exist)"
fi

exec webhook -hooks "$hooks" -port 9000 -verbose
