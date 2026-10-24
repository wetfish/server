#!/bin/sh
# Run by the webhook listener for every request signed with a project's
# secret. Its output is the response GitHub shows under Recent Deliveries.
#
# Arguments, from the project's hook definition:
#   1. the project name
#   2. the branch this server deploys for the project
#   3. the pushed ref from the payload (refs/heads/<branch>)
#
# Pushes to other branches and GitHub's ping event (which has no ref)
# succeed without deploying, so a failed delivery in GitHub always means a
# real problem. Writing the trigger file starts the project's deploy on the
# host.

set -eu

project="$1"
branch="$2"
ref="${3:-}"

if [ "$ref" != "refs/heads/$branch" ]; then
    printf 'Ignored %s: this server deploys %s of %s\n' "${ref:-a request without a ref}" "$branch" "$project"
    exit 0
fi

date -u > "/triggers/$project"
printf 'Deploy of %s %s requested\n' "$project" "$branch"
