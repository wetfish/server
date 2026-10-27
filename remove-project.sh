#!/usr/bin/env bash
#
# Removes a project from this server: stops its containers, deletes
# config/<name>.conf and its env files in config/<name>/, and applies the
# configuration, so Caddy stops serving its domains and its webhook is gone.
# Its clone in projects/<name>, its Docker volumes, its files on the server's
# storage, and its database on the shared database are kept. Run from the
# clone, as root on a server or as yourself on your own computer:
#
#   ./remove-project.sh glitch
#   ./remove-project.sh glitch --yes    # without asking to confirm
#
# See "Projects" in docs/how-it-works.md.

set -euo pipefail

info() {
    echo "==> $*"
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    echo "Usage: ./remove-project.sh <name> [--yes]" >&2
    exit 1
}

main() {
    local name="" confirmed=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y | --yes) confirmed=true ;;
            -h | --help | -*) usage ;;
            *)
                [[ -z "$name" ]] || usage
                name="$1"
                ;;
        esac
        shift
    done

    [[ -n "$name" ]] || usage

    local install_dir config_file reply uses_database=false uses_storage=false
    install_dir="$(cd "$(dirname "$0")" && pwd)"
    config_file="$install_dir/config/$name.conf"

    [[ "$name" =~ ^[a-z][a-z0-9-]*$ && -f "$config_file" ]] || fail "$name is not on this server (no config/$name.conf)"

    if grep -qE '^DATABASE_PASSWORD=.' "$config_file"; then
        uses_database=true
    fi

    if grep -qE '^VOLUMES=.' "$config_file"; then
        uses_storage=true
    fi

    if ! $confirmed; then
        [[ -t 0 ]] || fail "pass --yes to remove $name without a terminal to confirm on"
        read -r -p "Remove $name? Its domains stop being served and its webhook stops working. [y/N]: " reply
        [[ "$reply" =~ ^[Yy] ]] || fail "$name was not removed"
    fi

    info "Removing $name"

    # Kept until the configuration applies, so a failure leaves the
    # project where it was
    local backup
    backup="$(mktemp)"
    mv "$config_file" "$backup"

    if ! "$install_dir/apply.sh"; then
        mv "$backup" "$config_file"
        fail "$name was not removed"
    fi
    rm -f "$backup"
    rm -rf "${install_dir:?}/config/$name"

    info "Stopping $name's containers"
    docker compose --project-name "$name" down --remove-orphans
    "$install_dir/database.sh" disconnect "$name"
    rm -rf "$install_dir/generated/projects/$name" "$install_dir/generated/maintenance/$name"

    echo
    echo "Removed $name. Delete its webhook in GitHub (the repository's Settings → Webhooks)."
    if [[ -d "$install_dir/projects/$name" ]]; then
        echo "Its clone in projects/$name and its Docker volumes are kept; delete them if"
        echo "nothing in them is needed."
    fi

    if $uses_storage; then
        echo
        local hostname
        hostname="$({ grep -E '^SERVER_HOSTNAME=' "$install_dir/.env" || true; } | tail -n 1 | cut -d '=' -f 2-)"
        echo "Its files on the server's storage, in /mnt/virtual/$hostname/$name, are"
        echo "kept too, along with the Docker volumes that bind them. Delete them if"
        echo "nothing in them is needed:"
        echo
        echo "  docker volume ls --filter label=org.wetfish.server.project=$name"
    fi

    if $uses_database; then
        local database="${name//-/_}"
        echo
        echo "Its database on shared-mariadb is kept too. To delete it, run"
        echo "./database.sh shell and enter:"
        echo
        echo "  DROP DATABASE \`$database\`; DROP USER '$database'@'%';"
    fi
}

main "$@"
exit
