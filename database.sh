#!/usr/bin/env bash
#
# Manages the shared database, shared-mariadb, which projects on this server
# can use, each with its own database and user. A project uses it when its
# config file has a DATABASE_PASSWORD. Run from the clone, as root on a
# server or as yourself on your own computer:
#
#   ./database.sh shell [<project>]   Open a MariaDB shell as root, in the
#                                     project's database if one is given
#   ./database.sh dump <project>      Write the project's database as SQL to
#                                     standard output
#   ./database.sh import <project>    Run SQL from standard input in the
#                                     project's database
#
# The scripts run these themselves:
#
#   ./database.sh prepare <project> <commit>
#                                     Starts the database if it isn't
#                                     running, connects it to the project's
#                                     network, and creates the project's
#                                     database and user. A database it has
#                                     just created gets the tables of the
#                                     schema the commit's setup.conf names.
#                                     (deploy.sh)
#   ./database.sh reconnect           Connects the database to every
#                                     project's network again after its
#                                     container is replaced (setup.sh)
#   ./database.sh disconnect <name>   Removes a project's network, keeping
#                                     its database (remove-project.sh)
#
# See "Databases" in docs/how-it-works.md.

set -euo pipefail

CONTAINER="shared-mariadb"

# How long the database has to start and pass its health check, in seconds
START_TIMEOUT=120

# All work happens in functions called from the last line, so a `git pull`
# that changes this file cannot affect a run in progress.

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" >&2
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    echo "Usage: ./database.sh shell [<project>] | dump <project> | import <project>" >&2
    echo "       ./database.sh prepare <project> <commit> | reconnect | disconnect <name>" >&2
    exit 1
}

# Reads KEY=value from a file without executing it, removing one pair of
# surrounding quotes
file_value() {
    local value
    value="$({ grep -E "^$2=" "$1" 2> /dev/null || true; } | tail -n 1 | cut -d '=' -f 2-)"
    value="${value#\"}"
    value="${value%\"}"
    echo "$value"
}

check_system() {
    INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

    [[ -f "$INSTALL_DIR/.env" ]] || fail "$INSTALL_DIR/.env is missing; run setup.sh first"
    command -v jq > /dev/null || fail "jq is missing; run setup.sh, or install jq"
}

# The project's network and its database's name, which is also its user's.
# MariaDB names use '_' rather than '-', so they never need quoting in a
# project's code.
project_names() {
    [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]] || fail "'$1' is not a valid project name"

    NAME="$1"
    NETWORK="$NAME-database"
    DATABASE="${NAME//-/_}"
}

# Reads a project's database password from config/<name>.conf
load_project() {
    local file="$INSTALL_DIR/config/$1.conf"

    project_names "$1"
    [[ -f "$file" ]] || fail "$NAME is not on this server (no config/$NAME.conf)"

    PASSWORD="$(file_value "$file" DATABASE_PASSWORD)"
    [[ -n "$PASSWORD" ]] || fail "$NAME does not use the shared database (no DATABASE_PASSWORD in config/$NAME.conf)"
    [[ "$PASSWORD" =~ ^[A-Za-z0-9]{16,}$ ]] || fail "config/$NAME.conf: DATABASE_PASSWORD must be at least 16 letters and numbers; generate one with: openssl rand -hex 24"
}

running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2> /dev/null)" == "true" ]]
}

require_running() {
    running || fail "the shared database is not running; deploying a project that uses it starts it"
}

# Runs a MariaDB program in the database's container as root. The password
# is read inside the container, so it never appears in the host's process
# list. A terminal is attached only when both ends are one, so dumps and
# imports pass through unchanged.
client() {
    local flags=(--interactive)
    [[ -t 0 && -t 1 ]] && flags+=(--tty)

    docker exec "${flags[@]}" "$CONTAINER" \
        sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec "$@"' sh "$@"
}

# Starts the database if it isn't running, and waits until it passes its
# health check. A container that exists is only started, never replaced:
# replacing it would disconnect every project. setup.sh replaces it when
# its image changes, then runs `reconnect`.
start() {
    local deadline=$((SECONDS + START_TIMEOUT)) health

    if ! running; then
        [[ -n "$(file_value "$INSTALL_DIR/.env" MARIADB_ROOT_PASSWORD)" ]] \
            || fail "MARIADB_ROOT_PASSWORD is not set in .env; run setup.sh"

        log "Starting the shared database"
        (cd "$INSTALL_DIR" && docker compose --profile database up --detach --no-recreate mariadb)
    fi

    while true; do
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2> /dev/null || true)"
        [[ "$health" != "healthy" ]] || return 0
        [[ $SECONDS -lt $deadline ]] || fail "the shared database did not become ready; see: docker logs $CONTAINER"
        sleep 2
    done
}

# Creates the project's network if it doesn't exist, and connects the
# database to it. Only the project's containers join it, so no project can
# reach another's through the database's networks. It is internal: nothing
# on it reaches the internet.
connect() {
    if ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
        docker network create --internal "$NETWORK" > /dev/null
    fi

    if ! docker inspect --format '{{json .NetworkSettings.Networks}}' "$CONTAINER" \
        | jq --exit-status --arg network "$NETWORK" 'has($network)' > /dev/null; then
        docker network connect "$NETWORK" "$CONTAINER"
    fi
}

# Creates the project's database and user, which can reach only that
# database, and sets the user's password to the one in its config file.
# Names and password are checked to be plain letters, numbers, and '_', so
# they need no escaping.
create_user() {
    client mariadb --user=root << EOF
CREATE DATABASE IF NOT EXISTS \`$DATABASE\`;
CREATE USER IF NOT EXISTS '$DATABASE'@'%' IDENTIFIED BY '$PASSWORD';
ALTER USER '$DATABASE'@'%' IDENTIFIED BY '$PASSWORD';
GRANT ALL PRIVILEGES ON \`$DATABASE\`.* TO '$DATABASE'@'%';
EOF
}

database_exists() {
    [[ -n "$(client mariadb --user=root --batch --skip-column-names \
        --execute "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DATABASE'")" ]]
}

# Runs the schema file from the commit in the project's database, as the
# project's own user, so it can change nothing outside that database. It
# connects over TCP, as projects do, so the user's '%' host applies. The
# password is sent on the first line of standard input, never on a command
# line, and the shell reads only that line, leaving the SQL for mariadb.
run_schema() {
    {
        echo "$PASSWORD"
        git -C "$INSTALL_DIR/projects/$NAME" cat-file blob "$2:$1"
    } | docker exec --interactive "$CONTAINER" \
        sh -c 'read -r MYSQL_PWD && export MYSQL_PWD && exec mariadb --host=127.0.0.1 --user="$1" "$1"' sh "$DATABASE"
}

# Creates the project's tables only in a database this deploy created, so
# a schema never runs against existing data, whatever it contains. If it
# fails, the new database is dropped again, so the next deploy starts over
# rather than finding a database without its tables.
prepare() {
    local schema="" created=false

    load_project "$1"
    start
    log "Connecting the shared database to $NAME's network"
    connect

    # The schema is looked up before anything is created, so a problem with
    # it never leaves a new database without its tables
    if ! database_exists; then
        created=true
        schema="$("$INSTALL_DIR/configure-project.sh" --schema "$NAME" "$2")"
    fi

    create_user

    $created || return 0
    log "Created $NAME's database"
    [[ -n "$schema" ]] || return 0

    log "Creating $NAME's tables from $schema"
    if ! run_schema "$schema" "$2"; then
        client mariadb --user=root --execute "DROP DATABASE \`$DATABASE\`"
        fail "$schema failed in $NAME's new database, so the database was removed again"
    fi
}

reconnect() {
    local file name

    running || return 0

    for file in "$INSTALL_DIR"/config/*.conf; do
        [[ -f "$file" ]] || continue
        name="$(basename "$file" .conf)"
        [[ -n "$(file_value "$file" DATABASE_PASSWORD)" ]] || continue

        project_names "$name"
        log "Connecting the shared database to $NAME's network"
        connect
    done
}

# The project's config file is already gone, so only its name is used
disconnect() {
    project_names "$1"

    docker network inspect "$NETWORK" > /dev/null 2>&1 || return 0

    if running; then
        docker network disconnect "$NETWORK" "$CONTAINER" 2> /dev/null || true
    fi
    docker network rm "$NETWORK" > /dev/null
}

main() {
    [[ $# -ge 1 ]] || usage

    check_system

    case "$1:$#" in
        shell:1)
            require_running
            client mariadb --user=root
            ;;
        shell:2)
            load_project "$2"
            require_running
            client mariadb --user=root "$DATABASE"
            ;;
        dump:2)
            load_project "$2"
            require_running
            client mariadb-dump --user=root --single-transaction --routines --triggers "$DATABASE"
            ;;
        import:2)
            load_project "$2"
            require_running
            [[ ! -t 0 ]] || fail "pipe the SQL in: ./database.sh import $2 < dump.sql"
            client mariadb --user=root "$DATABASE"
            ;;
        prepare:3) prepare "$2" "$3" ;;
        reconnect:1) reconnect ;;
        disconnect:2) disconnect "$2" ;;
        *) usage ;;
    esac
}

main "$@"
exit
