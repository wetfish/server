#!/usr/bin/env bash
#
# Sets up a server: installs Docker, writes .env, and starts the shared
# services. Run as root on Debian 13 (or Ubuntu), either straight from
# GitHub, which clones the repository into /srv/wetfish-server:
#
#   curl -fsSL https://raw.githubusercontent.com/wetfish/server/main/setup.sh | sudo bash
#
# or from a clone, which stays wherever it is:
#
#   sudo ./setup.sh
#
# Settings can be given as options instead of answering prompts; see
# --help. Safe to re-run: existing settings are kept and every step is
# repeated. See docs/how-it-works.md.

set -euo pipefail

REPO_URL="https://github.com/wetfish/server.git"
DEFAULT_DIR="/srv/wetfish-server"
DEPLOY_USER="deploy"

# All work happens in functions called from the last line, so a download
# cut short never runs half a script, and a `git pull` that changes this
# file cannot affect a run in progress.

# --- Output and prompts -------------------------------------------------------

info() {
    echo
    echo "==> $*"
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    cat << EOF
Usage: sudo ./setup.sh [options]

  --hostname <name>   This server's own hostname, such as stage.example.com.
                      It receives the GitHub webhooks for every project.
  --cloudflare        Turn on Cloudflare-only mode (see docs/cloudflare.md)
  --no-cloudflare     Leave Cloudflare-only mode off without asking
  -h, --help          Show this help

Anything not given is asked for. Without a terminal to ask on, a missing
--hostname is an error, and Cloudflare-only mode stays off.
EOF
}

interactive() {
    [[ -t 0 ]]
}

# Prompt text goes to stderr; the answer is printed to stdout
ask() {
    local reply
    read -r -p "$1: " reply
    echo "$reply"
}

confirm() {
    local reply
    read -r -p "$1 [y/N]: " reply
    [[ "$reply" =~ ^[Yy] ]]
}

# --- .env files ---------------------------------------------------------------

# Reads KEY=value from a .env file without executing it; prints nothing if
# the key is missing
env_value() {
    { grep -E "^$2=" "$1" 2> /dev/null || true; } | tail -n 1 | cut -d '=' -f 2-
}

# Sets KEY=VALUE in a .env file, replacing an existing or commented-out line
# for the key, or appending one. The file is rewritten in place, so its
# owner and permissions are kept.
set_env() {
    local file="$1" key="$2" value="$3"

    KEY="$key" VALUE="$value" awk '
        BEGIN { key = ENVIRON["KEY"]; line = key "=" ENVIRON["VALUE"] }
        !done && $0 ~ ("^#? *" key "=") { print line; done = 1; next }
        { print }
        END { if (!done) print line }
    ' "$file" > "$file.tmp"

    cat "$file.tmp" > "$file"
    rm "$file.tmp"
}

valid_hostname() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

# --- Checks -------------------------------------------------------------------

check_system() {
    [[ "$(id -u)" -eq 0 ]] || fail "run this script as root, for example with sudo"

    [[ -f /etc/os-release ]] || fail "only Debian and Ubuntu are supported"
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="$ID"
    OS_CODENAME="$VERSION_CODENAME"

    [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" ]] || fail "only Debian and Ubuntu are supported (found $OS_ID)"
}

# Prints the directory of the clone this script is running from, or nothing
# when it runs by itself: piped from curl, or saved as a lone file
clone_dir() {
    local script="${BASH_SOURCE[0]:-}" dir

    [[ -n "$script" && -f "$script" ]] || return 0
    dir="$(cd "$(dirname "$script")" && pwd)"

    if [[ -d "$dir/.git" && -f "$dir/docker-compose.yml" && -f "$dir/cloudflare.sh" ]]; then
        echo "$dir"
    fi
}

# --- Running by itself --------------------------------------------------------

# Clones the repository into DEFAULT_DIR, or uses the clone already there,
# then runs that clone's own setup.sh, so the rest of setup always matches
# the files it sets up. Prompts are read from the terminal, since a script
# piped from curl has the download as its input.
bootstrap() {
    if [[ -d "$DEFAULT_DIR/.git" ]]; then
        info "Using the existing clone in $DEFAULT_DIR"
        echo "    To update it first: git -C $DEFAULT_DIR pull"
    elif [[ -e "$DEFAULT_DIR" ]]; then
        fail "$DEFAULT_DIR already exists and is not a clone of $REPO_URL"
    else
        info "Installing git"
        apt-get update -qq
        apt-get install -y -qq ca-certificates git > /dev/null

        info "Cloning $REPO_URL into $DEFAULT_DIR"
        git clone --quiet "$REPO_URL" "$DEFAULT_DIR"
    fi

    if (: < /dev/tty) 2> /dev/null; then
        exec bash "$DEFAULT_DIR/setup.sh" "$@" < /dev/tty
    else
        exec bash "$DEFAULT_DIR/setup.sh" "$@"
    fi
}

# --- Settings -----------------------------------------------------------------

parse_options() {
    HOSTNAME_OPTION=""
    CLOUDFLARE_OPTION=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                [[ $# -ge 2 ]] || fail "--hostname needs a value"
                HOSTNAME_OPTION="$2"
                shift 2
                ;;
            --hostname=*)
                HOSTNAME_OPTION="${1#*=}"
                shift
                ;;
            --cloudflare)
                CLOUDFLARE_OPTION="on"
                shift
                ;;
            --no-cloudflare)
                CLOUDFLARE_OPTION="off"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                fail "unknown option: $1"
                ;;
        esac
    done
}

# Settles every setting before the long-running steps, so nobody has to
# wait around to answer a question
choose_settings() {
    local env_file="$INSTALL_DIR/.env"

    SERVER_HOSTNAME="$HOSTNAME_OPTION"

    if [[ -z "$SERVER_HOSTNAME" ]]; then
        SERVER_HOSTNAME="$(env_value "$env_file" SERVER_HOSTNAME)"
        [[ "$SERVER_HOSTNAME" != "localhost" ]] || SERVER_HOSTNAME=""
    fi

    if [[ -z "$SERVER_HOSTNAME" ]]; then
        interactive || fail "pass this server's hostname with --hostname"

        echo
        echo "This server's own hostname receives the GitHub webhooks for every project,"
        echo "for example stage.example.com or prod.example.com. Its DNS record must"
        echo "point at this server."
        SERVER_HOSTNAME="$(ask "Hostname")"
    fi

    valid_hostname "$SERVER_HOSTNAME" || fail "'$SERVER_HOSTNAME' is not a valid hostname"

    if [[ "$CLOUDFLARE_OPTION" == "on" ]]; then
        ENABLE_CLOUDFLARE=true
    elif [[ "$CLOUDFLARE_OPTION" == "off" ]]; then
        ENABLE_CLOUDFLARE=false
    elif systemctl is-enabled --quiet cloudflare-firewall.service 2> /dev/null; then
        # Already on: re-apply it, so updated files take effect
        ENABLE_CLOUDFLARE=true
    elif interactive; then
        echo
        echo "Cloudflare-only mode accepts web traffic only from Cloudflare's proxies."
        echo "Turn it on only once every domain on this server, including $SERVER_HOSTNAME,"
        echo "is proxied through Cloudflare; see docs/cloudflare.md. It can be turned on"
        echo "later with: sudo ./cloudflare.sh enable"
        if confirm "Turn on Cloudflare-only mode now?"; then
            ENABLE_CLOUDFLARE=true
        else
            ENABLE_CLOUDFLARE=false
        fi
    else
        ENABLE_CLOUDFLARE=false
    fi
}

# --- Setup steps --------------------------------------------------------------

install_packages() {
    info "Installing required packages"
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl git > /dev/null
}

# Builds can use more memory than a small server has. Adds a 1 GiB swap file
# when there is less than 2 GiB of memory and no swap yet.
ensure_swap() {
    local memory_kb

    if [[ -n "$(swapon --show --noheadings)" ]]; then
        return
    fi

    memory_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
    if [[ "$memory_kb" -ge $((2 * 1024 * 1024)) ]]; then
        return
    fi

    info "Adding a 1 GiB swap file, since this server has less than 2 GiB of memory"

    if [[ ! -f /swapfile ]]; then
        fallocate -l 1G /swapfile 2> /dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null
    fi

    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

# Installs Docker Engine and the Compose plugin from Docker's apt repository
install_docker() {
    if command -v docker > /dev/null && docker compose version > /dev/null 2>&1; then
        info "Docker is already installed"
    else
        info "Installing Docker"
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
    fi

    # Container logs grow without limit by default and can fill a small
    # server's disk. The local driver keeps at most 100 MB per container.
    # An existing daemon.json is left alone.
    if [[ ! -f /etc/docker/daemon.json ]]; then
        info "Limiting the size of container logs"
        mkdir -p /etc/docker
        echo '{ "log-driver": "local" }' > /etc/docker/daemon.json
        systemctl restart docker
    fi

    systemctl enable --quiet --now docker
}

# Deploys run as this user, which has no password or login shell. It is in
# the docker group, which is equivalent to root access.
ensure_deploy_user() {
    if ! id "$DEPLOY_USER" > /dev/null 2>&1; then
        info "Creating the $DEPLOY_USER user"
        useradd --system --create-home --shell /usr/sbin/nologin "$DEPLOY_USER"
    fi

    usermod -aG docker "$DEPLOY_USER"
}

# Docker's published ports bypass ufw for IPv4, but ufw still blocks the
# IPv6 connections Docker accepts on the server itself
open_ufw() {
    if command -v ufw > /dev/null && ufw status | grep -q "^Status: active"; then
        info "Allowing ports 80 and 443 in ufw"
        ufw allow 80/tcp > /dev/null
        ufw allow 443 > /dev/null
    fi
}

write_env() {
    local env_file="$INSTALL_DIR/.env"

    if [[ ! -f "$env_file" ]]; then
        info "Writing .env"
        cp "$INSTALL_DIR/.env.example" "$env_file"
    else
        info "Updating .env"
    fi

    chmod 600 "$env_file"
    set_env "$env_file" SERVER_HOSTNAME "$SERVER_HOSTNAME"
    set_env "$env_file" UID "$(id -u "$DEPLOY_USER")"
    set_env "$env_file" GID "$(id -g "$DEPLOY_USER")"
}

# The directories must exist before the containers start, or Docker creates
# them owned by root. The webhook runs as the deploy user and writes the
# trigger files.
create_state_dirs() {
    mkdir -p "$INSTALL_DIR"/state/{caddy/global,caddy/sites,webhook,triggers}
    chown "$DEPLOY_USER:$DEPLOY_USER" "$INSTALL_DIR/state/triggers"
}

start_services() {
    info "Building and starting the shared services"
    (cd "$INSTALL_DIR" && docker compose up --detach --build --remove-orphans)
}

apply_cloudflare() {
    if [[ "$ENABLE_CLOUDFLARE" == true ]]; then
        "$INSTALL_DIR/cloudflare.sh" enable
    fi
}

print_summary() {
    local cloudflare="off (turn it on with: sudo ./cloudflare.sh enable)"
    [[ "$ENABLE_CLOUDFLARE" != true ]] || cloudflare="on"

    cat << EOF

==============================================================================
Setup complete: https://$SERVER_HOSTNAME/

  Installed in:          $INSTALL_DIR
  Cloudflare-only mode:  $cloudflare

From your own machine, https://$SERVER_HOSTNAME/ should answer "OK" once its
DNS record points at this server and Caddy has its certificate. If it does
not, check Caddy's log from $INSTALL_DIR:

  docker compose logs caddy
==============================================================================
EOF
}

# --- Main ---------------------------------------------------------------------

main() {
    # Checked first, so --help and mistyped options never clone anything
    parse_options "$@"
    check_system

    INSTALL_DIR="$(clone_dir)"
    if [[ -z "$INSTALL_DIR" ]]; then
        bootstrap "$@"
    fi

    # The path is written into systemd units, so keep it to plain characters
    [[ "$INSTALL_DIR" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "the repository path may only contain letters, numbers, '.', '_', '-', and '/' ($INSTALL_DIR)"

    echo "Setting up this server from $INSTALL_DIR"
    choose_settings

    install_packages
    ensure_swap
    install_docker
    ensure_deploy_user
    open_ufw
    write_env
    create_state_dirs
    start_services
    apply_cloudflare
    print_summary
}

main "$@"
exit
