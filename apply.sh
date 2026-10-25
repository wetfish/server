#!/usr/bin/env bash
#
# Applies this server's project configuration: generates each project's
# Caddy site and webhook from config/<project>.conf, reloads Caddy and the
# webhook listener, and on a server turns on each project's deploys. Run
# from the clone after changing a file in config/, as root on a server or as
# yourself on your own computer:
#
#   ./apply.sh
#
# Every file is checked before anything changes, and if Caddy rejects the
# generated configuration, the previous files are put back. The format is
# described in docs/how-it-works.md.

set -euo pipefail

# Project names become container names and webhook URLs
NAME_PATTERN='^[a-z][a-z0-9-]*$'
DOMAIN_PATTERN='^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
BRANCH_PATTERN='^[A-Za-z0-9._/-]+$'
SECRET_PATTERN='^[A-Za-z0-9_-]{16,}$'
UPSTREAM_PATTERN='^[a-z0-9][a-z0-9_.-]*:[0-9]+$'
KEYS_PATTERN='^(REPO|BRANCH|DOMAINS|REDIRECTS|UPSTREAM|WEBHOOK_SECRET)='

# All work happens in functions called from the last line, so a `git pull`
# that changes this file cannot affect a run in progress.

# --- Output -------------------------------------------------------------------

info() {
    echo "==> $*"
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

# --- Settings -----------------------------------------------------------------

# Reads KEY=value from a file without executing it, removing one pair of
# surrounding quotes; prints nothing if the key is missing
file_value() {
    local value
    value="$({ grep -E "^$2=" "$1" 2> /dev/null || true; } | tail -n 1 | cut -d '=' -f 2-)"
    value="${value#\"}"
    value="${value%\"}"
    echo "$value"
}

check_system() {
    INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
    CONFIG_DIR="$INSTALL_DIR/config"
    GENERATED_DIR="$INSTALL_DIR/generated"

    local env_file="$INSTALL_DIR/.env"
    [[ -f "$env_file" ]] || fail "$env_file is missing; run setup.sh first"

    SERVER_HOSTNAME="$(file_value "$env_file" SERVER_HOSTNAME)"
    SERVER_ENVIRONMENT="$(file_value "$env_file" SERVER_ENVIRONMENT)"
    DEPLOY_GID="$(file_value "$env_file" GID)"

    [[ -n "$SERVER_HOSTNAME" ]] || fail "SERVER_HOSTNAME is not set in .env; run setup.sh"
    [[ "$DEPLOY_GID" =~ ^[0-9]+$ ]] || fail "GID is not set in .env; run setup.sh"

    case "$SERVER_ENVIRONMENT" in
        staging) DEFAULT_BRANCH="main" ;;
        production) DEFAULT_BRANCH="release" ;;
        *) fail "SERVER_ENVIRONMENT in .env must be staging or production; run setup.sh" ;;
    esac
}

# --- Reading the configuration ------------------------------------------------

# Reads and checks every config/<project>.conf into the PROJECTS list and the
# P_* maps. Stops at the first problem, before anything is changed.
load_projects() {
    PROJECTS=()
    declare -gA P_BRANCH=() P_DOMAINS=() P_REDIRECTS=() P_UPSTREAM=() P_SECRET=()

    # Which project claims each domain, so no two can share one
    local -A claimed=()
    local file name label line number domain

    shopt -s nullglob
    for file in "$CONFIG_DIR"/*.conf; do
        name="$(basename "$file" .conf)"
        label="config/$name.conf"
        [[ "$name" =~ $NAME_PATTERN ]] || fail "$label: project names may only contain lowercase letters, numbers, and '-', starting with a letter"

        # The file holds the project's webhook secret
        chmod 600 "$file"

        number=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            number=$((number + 1))
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            [[ "$line" =~ $KEYS_PATTERN ]] || fail "$label, line $number: expected REPO, BRANCH, DOMAINS, REDIRECTS, UPSTREAM, or WEBHOOK_SECRET, followed by '='"
        done < "$file"

        local repo branch domains redirects upstream secret
        repo="$(file_value "$file" REPO)"
        branch="$(file_value "$file" BRANCH)"
        domains="$(file_value "$file" DOMAINS)"
        redirects="$(file_value "$file" REDIRECTS)"
        upstream="$(file_value "$file" UPSTREAM)"
        secret="$(file_value "$file" WEBHOOK_SECRET)"

        [[ -n "$repo" ]] || fail "$label: REPO is missing"
        [[ -n "$domains" ]] || fail "$label: DOMAINS is missing"
        [[ -n "$secret" ]] || fail "$label: WEBHOOK_SECRET is missing"

        branch="${branch:-$DEFAULT_BRANCH}"
        upstream="${upstream:-nginx:80}"

        [[ "$branch" =~ $BRANCH_PATTERN ]] || fail "$label: '$branch' is not a valid BRANCH"
        [[ "$upstream" =~ $UPSTREAM_PATTERN ]] || fail "$label: UPSTREAM must look like <service>:<port>, such as nginx:80"
        [[ "$secret" =~ $SECRET_PATTERN ]] || fail "$label: WEBHOOK_SECRET must be at least 16 letters, numbers, '-', or '_'; generate one with: openssl rand -hex 32"

        for domain in $domains $redirects; do
            [[ "$domain" =~ $DOMAIN_PATTERN || "$domain" == "$SERVER_HOSTNAME" ]] || fail "$label: '$domain' is not a valid domain"
            [[ -z "${claimed[$domain]:-}" ]] || fail "$domain is in both config/${claimed[$domain]}.conf and config/$name.conf"
            claimed[$domain]="$name"
        done

        for domain in $redirects; do
            [[ "$domain" != "$SERVER_HOSTNAME" ]] || fail "$label: the server's own hostname cannot be a redirect"
        done

        PROJECTS+=("$name")
        P_BRANCH[$name]="$branch"
        P_DOMAINS[$name]="$domains"
        P_REDIRECTS[$name]="$redirects"
        # Caddy reaches the service by the alias deploy.sh gives it on the
        # shared web network
        P_UPSTREAM[$name]="$name-$upstream"
        P_SECRET[$name]="$secret"
    done
    shopt -u nullglob
}

# --- Generating ---------------------------------------------------------------

# Writes the Caddy site file for one project
write_site() {
    local name="$1" file="$2"
    local noindex="" site_domains="" primary domain

    [[ "$SERVER_ENVIRONMENT" != "staging" ]] || noindex=$'\timport noindex\n'

    # Requests are redirected to the first domain listed
    read -r primary _ <<< "${P_DOMAINS[$name]}"

    for domain in ${P_DOMAINS[$name]}; do
        [[ "$domain" == "$SERVER_HOSTNAME" ]] || site_domains+="${site_domains:+, }$domain"
    done

    {
        echo "# Generated by apply.sh from config/$name.conf; edit that file instead,"
        echo "# then run apply.sh."

        if [[ -n "$site_domains" ]]; then
            echo
            echo "$site_domains {"
            printf '%s' "$noindex"
            echo "	import project ${P_UPSTREAM[$name]}"
            echo "}"
        fi

        if [[ -n "${P_REDIRECTS[$name]}" ]]; then
            echo
            echo "$(echo "${P_REDIRECTS[$name]}" | xargs | sed 's/ /, /g') {"
            printf '%s' "$noindex"
            echo "	redir https://$primary{uri} permanent"
            echo "}"
        fi
    } > "$file"
}

# Writes what the server's own hostname serves besides the webhooks: the
# project whose domains include it, or a plain "OK"
write_hostname() {
    local file="$1" name domain

    for name in "${PROJECTS[@]}"; do
        for domain in ${P_DOMAINS[$name]}; do
            if [[ "$domain" == "$SERVER_HOSTNAME" ]]; then
                {
                    echo "# Generated by apply.sh: config/$name.conf serves the server's own hostname"
                    echo "import project ${P_UPSTREAM[$name]}"
                } > "$file"
                return
            fi
        done
    done

    {
        echo "# Generated by apply.sh: no project serves the server's own hostname,"
        echo "# so it answers with a plain response for checking that the server is up"
        echo 'respond "OK" 200'
    } > "$file"
}

# Writes the webhook definitions: one hook per project, at /hooks/<project>,
# accepting only requests signed with that project's secret
write_hooks() {
    local file="$1" name separator=""

    {
        echo "["
        for name in "${PROJECTS[@]}"; do
            printf '%s' "$separator"
            separator=$',\n'
            cat << EOF
    {
        "id": "$name",
        "execute-command": "/usr/local/bin/request-deploy",
        "pass-arguments-to-command": [
            { "source": "string", "name": "$name" },
            { "source": "string", "name": "${P_BRANCH[$name]}" },
            { "source": "payload", "name": "ref" }
        ],
        "include-command-output-in-response": true,
        "include-command-output-in-response-on-error": true,
        "trigger-rule-mismatch-http-response-code": 403,
        "trigger-rule": {
            "match": {
                "type": "payload-hmac-sha256",
                "secret": "${P_SECRET[$name]}",
                "parameter": { "source": "header", "name": "X-Hub-Signature-256" }
            }
        }
    }
EOF
        done
        echo "]"
    } > "$file"
}

generate() {
    local dir="$1" name

    mkdir -p "$dir/sites" "$dir/hostname" "$dir/webhook"

    for name in "${PROJECTS[@]}"; do
        write_site "$name" "$dir/sites/$name.Caddyfile"
    done

    write_hostname "$dir/hostname/server.Caddyfile"
    write_hooks "$dir/webhook/hooks.json"

    chmod 755 "$dir/sites" "$dir/hostname"
    chmod 644 "$dir"/sites/*.Caddyfile "$dir/hostname/server.Caddyfile" 2> /dev/null || true
}

# --- Applying -----------------------------------------------------------------

running() {
    command -v docker > /dev/null && [[ -n "$(docker ps --quiet --filter "name=^$1\$" 2> /dev/null)" ]]
}

# Moves the generated Caddy files into place, keeping the previous ones in
# the given backup directory
swap_caddy_files() {
    local from="$1" backup="$2" dir

    for dir in sites hostname; do
        rm -rf "${backup:?}/$dir"
        if [[ -d "$GENERATED_DIR/caddy/$dir" ]]; then
            mv "$GENERATED_DIR/caddy/$dir" "$backup/$dir"
        fi
        mv "$from/$dir" "$GENERATED_DIR/caddy/$dir"
    done
}

apply_caddy() {
    local new="$1" backup="$2"

    mkdir -p "$GENERATED_DIR/caddy"
    swap_caddy_files "$new" "$backup"

    if running shared-caddy; then
        info "Reloading Caddy"
        if ! docker exec shared-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
            # Put the previous files back, so a restart never loads a
            # configuration Caddy rejected
            local dir
            for dir in sites hostname; do
                rm -rf "${GENERATED_DIR:?}/caddy/$dir"
                if [[ -d "$backup/$dir" ]]; then
                    mv "$backup/$dir" "$GENERATED_DIR/caddy/$dir"
                fi
            done
            fail "Caddy rejected the generated configuration; the previous configuration is still in use"
        fi
    fi
}

apply_hooks() {
    local new="$1" current="$GENERATED_DIR/webhook/hooks.json"

    if cmp -s "$new" "$current"; then
        return
    fi

    mkdir -p "$GENERATED_DIR/webhook"
    install -m 0640 -g "$DEPLOY_GID" "$new" "$current"

    # The listener only reads its hooks when it starts
    if running shared-webhook; then
        info "Restarting the webhook listener"
        docker restart shared-webhook > /dev/null
    fi
}

# On a server, a systemd path unit per project starts its deploy whenever
# the webhook writes the project's trigger file. Elsewhere, such as on your
# own computer, deploys run by hand or with `./deploy.sh --watch`.
deploys_automatic() {
    [[ "$(id -u)" -eq 0 && -d /run/systemd/system && -f /etc/systemd/system/project-deploy@.path ]]
}

apply_deploy_units() {
    deploys_automatic || return 0

    local name unit enabled
    for name in "${PROJECTS[@]}"; do
        systemctl enable --quiet --now "project-deploy@$name.path"
    done

    # Projects that were removed
    for unit in /etc/systemd/system/multi-user.target.wants/project-deploy@*.path; do
        [[ -e "$unit" ]] || continue
        enabled="$(basename "$unit" .path)"
        enabled="${enabled#project-deploy@}"
        [[ -f "$CONFIG_DIR/$enabled.conf" ]] || systemctl disable --quiet --now "project-deploy@$enabled.path"
    done
}

print_summary() {
    local name

    if [[ ${#PROJECTS[@]} -eq 0 ]]; then
        info "No projects in config/; $SERVER_HOSTNAME answers \"OK\""
        return
    fi

    info "Applied ${#PROJECTS[@]} project(s) on this $SERVER_ENVIRONMENT server"
    for name in "${PROJECTS[@]}"; do
        echo
        echo "    $name"
        echo "      Branch:   ${P_BRANCH[$name]}"
        echo "      Domains:  ${P_DOMAINS[$name]}"
        [[ -z "${P_REDIRECTS[$name]}" ]] || echo "      Redirects: ${P_REDIRECTS[$name]}"
        echo "      Webhook:  https://$SERVER_HOSTNAME/hooks/$name"
    done

    if ! deploys_automatic; then
        echo
        echo "Deploys here run by hand: ./deploy.sh <project>, or ./deploy.sh --watch to"
        echo "deploy whenever the webhook requests it, as a server does."
    fi
}

# --- Main ---------------------------------------------------------------------

main() {
    [[ $# -eq 0 ]] || fail "apply.sh takes no arguments; it applies every file in config/"

    check_system

    # Never apply two changes at once
    mkdir -p "$GENERATED_DIR"
    exec 9> "$GENERATED_DIR/apply.lock"
    flock 9

    load_projects

    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "$WORK_DIR"' EXIT

    generate "$WORK_DIR/new"
    mkdir -p "$WORK_DIR/backup"

    apply_caddy "$WORK_DIR/new" "$WORK_DIR/backup"
    apply_hooks "$WORK_DIR/new/webhook/hooks.json"
    apply_deploy_units
    print_summary
}

main "$@"
exit
