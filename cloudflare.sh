#!/usr/bin/env bash
#
# Cloudflare-only mode: accepts web traffic only from Cloudflare's proxies,
# so the sites cannot be reached directly by the server's IP address, and
# passes each visitor's real address on to Caddy and the projects.
#
# Run as root from the clone:
#
#   sudo ./cloudflare.sh enable    Turn the mode on (or re-apply it)
#   sudo ./cloudflare.sh update    Download Cloudflare's address ranges again
#                                  and apply any changes; runs weekly
#   sudo ./cloudflare.sh disable   Turn the mode off
#   sudo ./cloudflare.sh status    Show whether the mode is on
#
#   sudo ./cloudflare.sh allowlist add <address>
#   sudo ./cloudflare.sh allowlist remove <address>
#   sudo ./cloudflare.sh allowlist
#       Let an address or range besides Cloudflare reach ports 80 and 443,
#       for example a developer testing the server directly; take it off the
#       list again; or show the list. Removing an address only takes it off
#       the allowlist: addresses that are neither Cloudflare's nor on the
#       allowlist are blocked.
#
# Before enabling, every domain on this server, including its own hostname,
# must be proxied through Cloudflare: anything else becomes unreachable.
# See docs/cloudflare.md.

set -euo pipefail

# Cloudflare's published address ranges, one per line
IPV4_URL="https://www.cloudflare.com/ips-v4/"
IPV6_URL="https://www.cloudflare.com/ips-v6/"

IPV4_PATTERN='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
IPV6_PATTERN='^[0-9a-fA-F:]+/[0-9]{1,3}$'

RULESET="/etc/cloudflare-only.nft"
TABLE=(inet cloudflare_only)
UNITS=(cloudflare-firewall.service cloudflare-update.service cloudflare-update.timer)

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

# --- Checks -------------------------------------------------------------------

check_system() {
    [[ "$(id -u)" -eq 0 ]] || fail "run this script as root, for example with sudo"

    INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
    CLOUDFLARE_DIR="$INSTALL_DIR/generated/cloudflare"
    ALLOWLIST_FILE="$CLOUDFLARE_DIR/allowlist.txt"
    CADDY_SETTINGS="$INSTALL_DIR/generated/caddy/global/cloudflare.Caddyfile"

    # The path is written into a systemd unit, so keep it to plain characters
    [[ "$INSTALL_DIR" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "the repository path may only contain letters, numbers, '.', '_', '-', and '/' ($INSTALL_DIR)"
}

install_packages() {
    local missing=()

    command -v nft > /dev/null || missing+=(nftables)
    command -v curl > /dev/null || missing+=(curl)

    if [[ ${#missing[@]} -gt 0 ]]; then
        command -v apt-get > /dev/null || fail "install ${missing[*]} first"
        info "Installing ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}" > /dev/null
    fi
}

is_enabled() {
    systemctl is-enabled --quiet cloudflare-firewall.service 2> /dev/null
}

# --- Address ranges -----------------------------------------------------------

# Prints the ranges from one of Cloudflare's lists, one per line. Fails if
# the download fails or any line is not an address range, so a broken
# download can never replace the current ranges.
download_ranges() {
    local url="$1" pattern="$2" body ranges

    body="$(curl -fsSL --max-time 30 "$url")" || return 1
    ranges="$(printf '%s\n' "$body" | tr -d '\r' | sed -e 's/[[:space:]]*$//' -e '/^$/d')"

    [[ -n "$ranges" ]] || return 1
    ! grep -qvE "$pattern" <<< "$ranges" || return 1

    printf '%s\n' "$ranges"
}

# Downloads both lists into NEW_IPV4 and NEW_IPV6
download_all() {
    info "Downloading Cloudflare's address ranges"

    NEW_IPV4="$(download_ranges "$IPV4_URL" "$IPV4_PATTERN")" || {
        echo "Could not download a valid list from $IPV4_URL" >&2
        return 1
    }

    NEW_IPV6="$(download_ranges "$IPV6_URL" "$IPV6_PATTERN")" || {
        echo "Could not download a valid list from $IPV6_URL" >&2
        return 1
    }

    echo "    $(wc -l <<< "$NEW_IPV4") IPv4 and $(wc -l <<< "$NEW_IPV6") IPv6 ranges"
}

ranges_changed() {
    [[ "$NEW_IPV4" != "$(cat "$CLOUDFLARE_DIR/ips-v4.txt" 2> /dev/null)" ]] \
        || [[ "$NEW_IPV6" != "$(cat "$CLOUDFLARE_DIR/ips-v6.txt" 2> /dev/null)" ]]
}

load_current_ranges() {
    [[ -f "$CLOUDFLARE_DIR/ips-v4.txt" && -f "$CLOUDFLARE_DIR/ips-v6.txt" ]] \
        || fail "Cloudflare's address ranges are missing; run: sudo ./cloudflare.sh enable"

    NEW_IPV4="$(cat "$CLOUDFLARE_DIR/ips-v4.txt")"
    NEW_IPV6="$(cat "$CLOUDFLARE_DIR/ips-v6.txt")"
}

# --- Allowlist ----------------------------------------------------------------

# Addresses besides Cloudflare's that may reach ports 80 and 443, one per line
load_allowlist() {
    ALLOWLIST="$(cat "$ALLOWLIST_FILE" 2> /dev/null || true)"
}

# Accepts an IPv4 or IPv6 address, with or without a /prefix. nft checks the
# finished rules as well, so anything this lets through that is still
# invalid, such as 300.1.2.3, changes nothing.
valid_address() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
        || [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]
}

# Prints the nftables elements line for the allowlist's IPv4 or IPv6
# addresses, or nothing if it has none of that kind
allowlist_elements() {
    local addresses

    if [[ "$1" == "ipv6" ]]; then
        addresses="$(grep ':' <<< "$ALLOWLIST" || true)"
    else
        addresses="$(grep -v ':' <<< "$ALLOWLIST" | sed '/^$/d' || true)"
    fi

    if [[ -n "$addresses" ]]; then
        echo "elements = { $(paste -sd ',' <<< "$addresses" | sed 's/,/, /g') }"
    fi
}

show_allowlist() {
    if [[ -z "$ALLOWLIST" ]]; then
        echo "The allowlist is empty: only Cloudflare can reach ports 80 and 443."
    else
        echo "Besides Cloudflare, these can reach ports 80 and 443:"
        local address
        while read -r address; do
            echo "    $address"
        done <<< "$ALLOWLIST"
    fi
}

# --- Templates ----------------------------------------------------------------

# Fills in a template's @CLOUDFLARE_IPV4@ and @CLOUDFLARE_IPV6@ (comma
# separated, for nftables), @CLOUDFLARE_RANGES@ (space separated, for Caddy),
# and @ALLOWLIST_IPV4@ and @ALLOWLIST_IPV6@ (nftables elements lines)
render() {
    IPV4="$(paste -sd ',' <<< "$NEW_IPV4" | sed 's/,/, /g')" \
    IPV6="$(paste -sd ',' <<< "$NEW_IPV6" | sed 's/,/, /g')" \
    RANGES="$(printf '%s\n%s\n' "$NEW_IPV4" "$NEW_IPV6" | paste -sd ' ')" \
    ALLOWLIST_IPV4="$(allowlist_elements ipv4)" \
    ALLOWLIST_IPV6="$(allowlist_elements ipv6)" \
    awk '{
        gsub(/@CLOUDFLARE_IPV4@/, ENVIRON["IPV4"])
        gsub(/@CLOUDFLARE_IPV6@/, ENVIRON["IPV6"])
        gsub(/@CLOUDFLARE_RANGES@/, ENVIRON["RANGES"])
        gsub(/@ALLOWLIST_IPV4@/, ENVIRON["ALLOWLIST_IPV4"])
        gsub(/@ALLOWLIST_IPV6@/, ENVIRON["ALLOWLIST_IPV6"])
        print
    }' "$1"
}

# --- Caddy --------------------------------------------------------------------

caddy_running() {
    command -v docker > /dev/null && [[ -n "$(docker ps --quiet --filter 'name=^shared-caddy$' 2> /dev/null)" ]]
}

reload_caddy() {
    if caddy_running; then
        docker exec shared-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    else
        echo "    Caddy is not running; it will use the new settings when it starts"
    fi
}

# Writes Caddy's trusted proxies and reloads Caddy. If Caddy rejects the new
# settings, the previous file is put back, so a restart never loads a
# configuration Caddy cannot start with.
apply_caddy_settings() {
    local backup=""

    info "Trusting Cloudflare's proxies in Caddy"
    mkdir -p "$(dirname "$CADDY_SETTINGS")"

    if [[ -f "$CADDY_SETTINGS" ]]; then
        backup="$(mktemp)"
        cp "$CADDY_SETTINGS" "$backup"
    fi

    render "$INSTALL_DIR/cloudflare/trusted-proxies.Caddyfile" > "$CADDY_SETTINGS"
    chmod 644 "$CADDY_SETTINGS"

    if ! reload_caddy; then
        if [[ -n "$backup" ]]; then
            cp "$backup" "$CADDY_SETTINGS"
        else
            rm -f "$CADDY_SETTINGS"
        fi
        fail "Caddy rejected the new settings; nothing was changed"
    fi

    [[ -z "$backup" ]] || rm -f "$backup"
}

remove_caddy_settings() {
    if [[ -f "$CADDY_SETTINGS" ]]; then
        info "Removing Cloudflare's proxies from Caddy"
        rm -f "$CADDY_SETTINGS"
        reload_caddy
    fi
}

# --- Firewall -----------------------------------------------------------------

# Renders the ruleset and checks it with nft before anything is changed
prepare_ruleset() {
    local problem="${1:-the generated firewall rules are invalid}"

    NEW_RULESET="$(mktemp)"
    render "$INSTALL_DIR/cloudflare/firewall.nft" > "$NEW_RULESET"

    if ! nft --check --file "$NEW_RULESET"; then
        rm -f "$NEW_RULESET"
        fail "$problem; nothing was changed"
    fi
}

install_ruleset() {
    install -m 0644 "$NEW_RULESET" "$RULESET"
    rm -f "$NEW_RULESET"

    mkdir -p "$CLOUDFLARE_DIR"
    printf '%s\n' "$NEW_IPV4" > "$CLOUDFLARE_DIR/ips-v4.txt"
    printf '%s\n' "$NEW_IPV6" > "$CLOUDFLARE_DIR/ips-v6.txt"

    if [[ -n "$ALLOWLIST" ]]; then
        printf '%s\n' "$ALLOWLIST" > "$ALLOWLIST_FILE"
    else
        rm -f "$ALLOWLIST_FILE"
    fi
}

# Installs the systemd units with this clone's path filled in. They are
# copied rather than linked, so changes to the clone never change the host's
# services until this script runs again.
install_units() {
    local unit
    for unit in "${UNITS[@]}"; do
        DIR="$INSTALL_DIR" awk '{
            gsub(/@INSTALL_DIR@/, ENVIRON["DIR"])
            print
        }' "$INSTALL_DIR/systemd/$unit" > "/etc/systemd/system/$unit"
    done

    systemctl daemon-reload
}

# --- Commands -----------------------------------------------------------------

enable() {
    install_packages
    download_all || fail "Cloudflare-only mode was not enabled"
    load_allowlist
    prepare_ruleset
    apply_caddy_settings

    info "Installing the firewall rules"
    install_ruleset
    install_units
    systemctl enable --quiet cloudflare-firewall.service
    systemctl restart cloudflare-firewall.service
    systemctl enable --quiet --now cloudflare-update.timer

    nft list table "${TABLE[@]}" > /dev/null || fail "the firewall rules did not load; see: systemctl status cloudflare-firewall"

    info "Cloudflare-only mode is enabled"
    echo "    Ports 80 and 443 now accept connections only from Cloudflare."
    echo "    The address ranges are updated weekly: journalctl -u cloudflare-update"
}

update() {
    is_enabled || fail "Cloudflare-only mode is not enabled; run: sudo ./cloudflare.sh enable"

    download_all || fail "keeping the current address ranges"

    if ! ranges_changed; then
        info "Cloudflare's address ranges have not changed"
        return
    fi

    load_allowlist
    prepare_ruleset
    apply_caddy_settings

    info "Updating the firewall rules"
    install_ruleset
    systemctl reload cloudflare-firewall.service

    info "Updated Cloudflare's address ranges"
}

disable() {
    # Caddy stops trusting Cloudflare's headers before the firewall opens, so
    # direct visitors can never set their own address
    remove_caddy_settings

    info "Removing the firewall rules"
    systemctl disable --quiet --now cloudflare-update.timer 2> /dev/null || true
    systemctl disable --quiet --now cloudflare-firewall.service 2> /dev/null || true
    nft delete table "${TABLE[@]}" 2> /dev/null || true

    local unit
    for unit in "${UNITS[@]}"; do
        rm -f "/etc/systemd/system/$unit"
    done
    systemctl daemon-reload

    rm -f "$RULESET"
    rm -rf "$CLOUDFLARE_DIR"

    info "Cloudflare-only mode is disabled"
    echo "    Ports 80 and 443 accept connections from anywhere."
    echo "    The allowlist was cleared; enabling the mode again starts with it empty."
}

allowlist() {
    is_enabled || fail "Cloudflare-only mode is not enabled; run: sudo ./cloudflare.sh enable"
    load_allowlist

    local action="${1:-}" address="${2:-}"

    case "$action" in
        "")
            show_allowlist
            ;;
        add)
            valid_address "$address" || fail "'$address' is not an IPv4 or IPv6 address or range"

            if grep -qxF "$address" <<< "$ALLOWLIST"; then
                info "$address is already on the allowlist"
                return
            fi

            ALLOWLIST="$(printf '%s\n%s\n' "$ALLOWLIST" "$address" | sed '/^$/d')"
            apply_allowlist "'$address' is not a valid address or range"
            info "Added $address: it can reach ports 80 and 443 directly"
            ;;
        remove)
            [[ -n "$address" ]] || usage
            grep -qxF "$address" <<< "$ALLOWLIST" || fail "$address is not on the allowlist"

            ALLOWLIST="$(grep -vxF "$address" <<< "$ALLOWLIST" || true)"
            apply_allowlist
            info "Removed $address from the allowlist"
            echo "    Addresses that are neither Cloudflare's nor on the allowlist are blocked."
            ;;
        *)
            usage
            ;;
    esac
}

# Reloads the firewall with the current Cloudflare ranges and the changed
# allowlist. The allowlist is not trusted by Caddy, so an allowed address
# appears in the logs as itself and cannot claim to be someone else.
apply_allowlist() {
    load_current_ranges
    prepare_ruleset "$@"
    install_ruleset
    systemctl reload cloudflare-firewall.service
}

status() {
    if ! is_enabled; then
        echo "Cloudflare-only mode: disabled"
        return
    fi

    echo "Cloudflare-only mode: enabled"

    if nft list table "${TABLE[@]}" > /dev/null 2>&1; then
        echo "Firewall rules:       loaded"
    else
        echo "Firewall rules:       NOT LOADED (see: systemctl status cloudflare-firewall)"
    fi

    if [[ -f "$CADDY_SETTINGS" ]]; then
        echo "Caddy:                trusts Cloudflare's proxies"
    else
        echo "Caddy:                NOT CONFIGURED (run: sudo ./cloudflare.sh enable)"
    fi

    if [[ -f "$CLOUDFLARE_DIR/ips-v4.txt" ]]; then
        echo "Address ranges:       $(wc -l < "$CLOUDFLARE_DIR/ips-v4.txt") IPv4, $(wc -l < "$CLOUDFLARE_DIR/ips-v6.txt") IPv6, downloaded $(date -r "$CLOUDFLARE_DIR/ips-v4.txt" '+%Y-%m-%d')"
    fi

    load_allowlist
    if [[ -z "$ALLOWLIST" ]]; then
        echo "Allowlist:            empty"
    else
        echo "Allowlist:            $(paste -sd ',' <<< "$ALLOWLIST" | sed 's/,/, /g')"
    fi

    echo "Next update check:    $(systemctl show cloudflare-update.timer --property=NextElapseUSecRealtime --value)"
}

usage() {
    cat >&2 << EOF
Usage: sudo $0 enable|update|disable|status
       sudo $0 allowlist [add|remove <address>]
EOF
    exit 1
}

main() {
    [[ $# -ge 1 ]] || usage

    case "$1" in
        enable | update | disable | status) [[ $# -eq 1 ]] || usage ;;
        allowlist) [[ $# -le 3 ]] || usage ;;
        *) usage ;;
    esac

    check_system

    # Never apply two changes at once, for example the weekly update and a
    # manual enable
    exec 9> /run/cloudflare-only.lock
    flock 9

    case "$1" in
        enable) enable ;;
        update) update ;;
        disable) disable ;;
        status) status ;;
        allowlist) shift && allowlist "$@" ;;
    esac
}

main "$@"
exit
