#!/usr/bin/env bash
#
# Adds a project to this server: writes config/<name>.conf with a new
# webhook secret, applies the configuration, deploys the project, and prints
# the webhook to add in GitHub. Run from the clone, as root on a server or as
# yourself on your own computer:
#
#   ./add-project.sh --name glitch --repo https://github.com/wetfish/glitch.git --domain stage-glitch.wetfish.net
#   ./add-project.sh      # asks for anything not given
#
# See "Projects" in docs/how-it-works.md.

set -euo pipefail

NAME_PATTERN='^[a-z][a-z0-9-]*$'
# A remote repository, or a local path for testing before pushing
REPO_PATTERN='^(https://|ssh://|git@|/)[^[:space:]]+$'

# All work happens in functions called from the last line, so a `git pull`
# that changes this file cannot affect a run in progress.

info() {
    echo "==> $*"
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    cat << EOF
Usage: ./add-project.sh [options]

  --name <name>            Project name: lowercase letters, numbers, and '-'.
                           It names the webhook URL and the containers.
  --repo <url or path>     The project's Git repository, or a local clone for
                           testing changes before pushing them
  --domain <domain>        A domain the project answers on; repeat for more.
                           Redirects go to the first one.
  --redirect <domain>      A domain that redirects to the first domain;
                           repeat for more
  --branch <branch>        Deploy this branch instead of main on staging or
                           release on production
  --upstream <service:port>
                           The Compose service and port that serve the
                           project, instead of nginx:80
  -h, --help               Show this help

The name, repository, and domains are asked for if not given. Without a
terminal to ask on, they are required.
EOF
}

# Prompt text goes to stderr; the answer is printed to stdout
ask() {
    local reply
    read -r -p "$1: " reply
    echo "$reply"
}

# Reads KEY=value from a file without executing it
file_value() {
    { grep -E "^$2=" "$1" 2> /dev/null || true; } | tail -n 1 | cut -d '=' -f 2-
}

parse_options() {
    NAME=""
    REPO=""
    DOMAINS=""
    REDIRECTS=""
    BRANCH=""
    UPSTREAM=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --name | --repo | --domain | --redirect | --branch | --upstream)
                [[ $# -ge 2 ]] || fail "$1 needs a value"
                set_option "$1" "$2"
                shift 2
                ;;
            --*=*)
                set_option "${1%%=*}" "${1#*=}"
                shift
                ;;
            *)
                usage >&2
                fail "unknown option: $1"
                ;;
        esac
    done
}

set_option() {
    case "$1" in
        --name) NAME="$2" ;;
        --repo) REPO="$2" ;;
        --domain) DOMAINS+="${DOMAINS:+ }$2" ;;
        --redirect) REDIRECTS+="${REDIRECTS:+ }$2" ;;
        --branch) BRANCH="$2" ;;
        --upstream) UPSTREAM="$2" ;;
        *)
            usage >&2
            fail "unknown option: $1"
            ;;
    esac
}

check_system() {
    INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
    CONFIG_FILE=""

    [[ -f "$INSTALL_DIR/.env" ]] || fail "$INSTALL_DIR/.env is missing; run setup.sh first"
    SERVER_HOSTNAME="$(file_value "$INSTALL_DIR/.env" SERVER_HOSTNAME)"
}

# Asks for the required settings that were not given as options
choose_settings() {
    local interactive=false
    [[ -t 0 ]] && interactive=true

    if [[ -z "$NAME" ]]; then
        $interactive || fail "pass the project's name with --name"
        NAME="$(ask "Project name (lowercase letters, numbers, and '-')")"
    fi

    [[ "$NAME" =~ $NAME_PATTERN ]] || fail "'$NAME' is not a valid project name: use lowercase letters, numbers, and '-', starting with a letter"

    CONFIG_FILE="$INSTALL_DIR/config/$NAME.conf"
    [[ ! -e "$CONFIG_FILE" ]] || fail "$NAME is already on this server; edit config/$NAME.conf and run apply.sh to change it"

    if [[ -z "$REPO" ]]; then
        $interactive || fail "pass the project's repository with --repo"
        REPO="$(ask "Git repository (for example https://github.com/wetfish/$NAME.git)")"
    fi

    # A local clone is used by its full path
    if [[ -d "$REPO" ]]; then
        REPO="$(cd "$REPO" && pwd)"
    fi

    [[ "$REPO" =~ $REPO_PATTERN ]] || fail "'$REPO' is not a Git repository URL or a local directory"

    if [[ -z "$DOMAINS" ]]; then
        $interactive || fail "pass at least one domain with --domain"
        DOMAINS="$(ask "Domains, separated by spaces (the first is the main one)")"
    fi

    [[ -n "$DOMAINS" ]] || fail "a project needs at least one domain"
}

# Writes the config file. apply.sh checks it along with every other
# project's; if it refuses, the file is removed again, so a failed add
# leaves the server as it was.
add_project() {
    info "Adding $NAME"

    mkdir -p "$INSTALL_DIR/config"
    chmod 700 "$INSTALL_DIR/config"

    (
        umask 077
        {
            echo "REPO=$REPO"
            echo "DOMAINS=$DOMAINS"
            [[ -z "$REDIRECTS" ]] || echo "REDIRECTS=$REDIRECTS"
            [[ -z "$BRANCH" ]] || echo "BRANCH=$BRANCH"
            [[ -z "$UPSTREAM" ]] || echo "UPSTREAM=$UPSTREAM"
            echo "WEBHOOK_SECRET=$(openssl rand -hex 32)"
        } > "$CONFIG_FILE"
    )

    if ! "$INSTALL_DIR/apply.sh"; then
        rm -f "$CONFIG_FILE"
        fail "$NAME was not added"
    fi
}

# The project stays added if its first deploy fails, so the problem can be
# fixed in the project and the deploy run again
first_deploy() {
    echo
    if "$INSTALL_DIR/deploy.sh" "$NAME"; then
        DEPLOYED=true
    else
        DEPLOYED=false
    fi
}

print_webhook() {
    local secret
    secret="$(file_value "$CONFIG_FILE" WEBHOOK_SECRET)"

    cat << EOF

==============================================================================
Added $NAME. Its settings are in config/$NAME.conf.

Add a webhook in GitHub (the repository's Settings → Webhooks → Add webhook):

  Payload URL:   https://$SERVER_HOSTNAME/hooks/$NAME
  Content type:  application/json
  Secret:        $secret
  Events:        Just the push event

Point these domains' DNS at this server:

  $DOMAINS${REDIRECTS:+ $REDIRECTS}
==============================================================================
EOF

    if [[ "$DEPLOYED" != true ]]; then
        echo
        echo "The first deploy of $NAME failed; see the output above. Fix the problem in"
        echo "the project, then deploy again with: ./deploy.sh $NAME"
        exit 1
    fi
}

main() {
    parse_options "$@"
    check_system

    # Never add two projects at once
    mkdir -p "$INSTALL_DIR/generated"
    exec 9> "$INSTALL_DIR/generated/add-project.lock"
    flock 9

    choose_settings
    add_project
    first_deploy
    print_webhook
}

main "$@"
exit
