#!/usr/bin/env bash
#
# Sets up the env files a project needs on this server, as its setup.conf
# describes, and keeps them in config/<name>/. add-project.sh runs it before
# a project's first deploy. Run it from the clone, as root on a server or as
# yourself on your own computer, when a newer setup.conf asks for a value
# that has to be entered by hand:
#
#   ./configure-project.sh glitch
#
# It reads setup.conf from the latest commit of the project's branch,
# generates secrets, fills in the project's database and domain, and asks
# for everything else. Values already set are kept; to change one, edit the
# file in config/<name>/ and deploy again.
#
# Each deploy runs it as `--deploy <name> <commit>`, which never asks: it
# fills in what it can generate, refuses if anything must be entered by
# hand, and copies the files into the project's clone. database.sh runs it
# as `--schema <name> <commit>`, which prints the SQL file setup.conf names
# for creating the project's tables. See "Project Setup" in
# docs/how-it-works.md.

set -euo pipefail

SETUP_FILE="setup.conf"
KEY_PATTERN='^[A-Za-z_][A-Za-z0-9_]*$'
# Env files live at a plain path inside the project's clone
PATH_PATTERN='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
# Written without quotes; anything else is single-quoted
PLAIN_VALUE_PATTERN='^[A-Za-z0-9._@:/+=,-]*$'

# All work happens in functions called from the last line, so a `git pull`
# that changes this file cannot affect a run in progress.

# --- Output and prompts -------------------------------------------------------

info() {
    echo "==> $*" >&2
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    echo "Usage: ./configure-project.sh <project>" >&2
    exit 1
}

# Reads KEY=value from a file without executing it, removing one pair of
# surrounding quotes
file_value() {
    local value
    value="$({ grep -E "^$2=" "$1" 2> /dev/null || true; } | tail -n 1 | cut -d '=' -f 2-)"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    echo "$value"
}

# Sets KEY=VALUE in an env file, replacing the line for the key, or
# appending one. The file is rewritten in place, so its permissions are kept.
set_env() {
    local file="$1" key="$2" value="$3"

    KEY="$key" VALUE="$value" awk '
        BEGIN { key = ENVIRON["KEY"]; line = key "=" ENVIRON["VALUE"] }
        !done && index($0, key "=") == 1 { print line; done = 1; next }
        { print }
        END { if (!done) print line }
    ' "$file" > "$file.tmp"

    cat "$file.tmp" > "$file"
    rm "$file.tmp"
}

has_key() {
    grep -qE "^$2=" "$1" 2> /dev/null
}

# Single-quotes a value unless it is plain, so Compose and other .env
# readers take it literally. Entered values never contain a single quote.
quote() {
    if [[ "$1" =~ $PLAIN_VALUE_PATTERN ]]; then
        echo "$1"
    else
        echo "'$1'"
    fi
}

# Asks for a value until it can be written to an env file. Prompt text goes
# to the terminal; the answer is printed to stdout.
ask_value() {
    local prompt="$1" default="$2" hidden="$3" reply

    while true; do
        if [[ "$hidden" == true ]]; then
            read -r -s -p "$prompt (leave empty to skip): " reply < /dev/tty
            echo > /dev/tty
        elif [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " reply < /dev/tty
            reply="${reply:-$default}"
        else
            read -r -p "$prompt: " reply < /dev/tty
        fi

        if [[ "$reply" == *"'"* || "$reply" =~ [[:cntrl:]] ]]; then
            echo "Values cannot contain a single quote (') or control characters." > /dev/tty
            continue
        fi

        echo "$reply"
        return
    done
}

# --- The project --------------------------------------------------------------

check_system() {
    INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
    GENERATED_DIR="$INSTALL_DIR/generated"

    [[ -f "$INSTALL_DIR/.env" ]] || fail "$INSTALL_DIR/.env is missing; run setup.sh first"
    command -v openssl > /dev/null || fail "openssl is missing; run setup.sh, or install openssl"

    case "$(file_value "$INSTALL_DIR/.env" SERVER_ENVIRONMENT)" in
        staging) DEFAULT_BRANCH="main" ;;
        production) DEFAULT_BRANCH="release" ;;
        *) fail "SERVER_ENVIRONMENT in .env must be staging or production; run setup.sh" ;;
    esac
}

load_project() {
    NAME="$1"
    CONFIG_FILE="$INSTALL_DIR/config/$NAME.conf"

    [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ && -f "$CONFIG_FILE" ]] || fail "$NAME is not on this server (no config/$NAME.conf)"

    REPO="$(file_value "$CONFIG_FILE" REPO)"
    BRANCH="$(file_value "$CONFIG_FILE" BRANCH)"
    BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
    read -r DOMAIN _ <<< "$(file_value "$CONFIG_FILE" DOMAINS)"

    PROJECT_DIR="$INSTALL_DIR/projects/$NAME"
    ENV_DIR="$INSTALL_DIR/config/$NAME"
}

# Clones the project the first time, as a deploy does, then fetches its
# branch and uses its latest commit
fetch() {
    if [[ ! -d "$PROJECT_DIR/.git" ]]; then
        info "Cloning $REPO into projects/$NAME"
        mkdir -p "$(dirname "$PROJECT_DIR")"
        git clone --quiet --no-checkout "$REPO" "$PROJECT_DIR"
    fi

    git -C "$PROJECT_DIR" remote set-url origin "$REPO"
    git -C "$PROJECT_DIR" fetch --quiet origin "$BRANCH" || fail "could not fetch the $BRANCH branch of $REPO"
    COMMIT="$(git -C "$PROJECT_DIR" rev-parse FETCH_HEAD)"
}

tracked() {
    [[ -n "$(git -C "$PROJECT_DIR" ls-tree "$COMMIT" -- "$1")" ]]
}

# Succeeds for a relative path of plain names, with no '.' or '..' parts
plain_path() {
    local part

    [[ "$1" =~ $PATH_PATTERN ]] || return 1
    for part in ${1//\// }; do
        [[ "$part" != "." && "$part" != ".." ]] || return 1
    done
}

# Reads setup.conf from the commit into the E_* lists, one entry per line:
#
#   <env file> <KEY> <how>
#
# and into SCHEMA_FILE the SQL file of a `schema <file>` line, if it has one.
# Stops at the first problem, before anything is changed. A project without
# setup.conf needs no setup.
read_setup() {
    E_FILE=()
    E_KEY=()
    E_KIND=()
    E_ARG=()
    USES_DATABASE=false
    SCHEMA_FILE=""

    git -C "$PROJECT_DIR" cat-file -e "$COMMIT:$SETUP_FILE" 2> /dev/null || return 0

    local line number=0 file key kind arg label
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        label="$SETUP_FILE, line $number"

        read -r file key kind arg <<< "$line"

        # SQL that creates the project's tables, run once in its database
        # when the server first creates it; see database.sh. It is read
        # from the commit, so it must be a file in the repository.
        if [[ "$file" == schema && -z "$kind" ]]; then
            [[ -z "$SCHEMA_FILE" ]] || fail "$label: setup.conf can name only one schema"
            plain_path "$key" || fail "$label: '$key' is not a plain path inside the repository"
            git -C "$PROJECT_DIR" ls-tree "$COMMIT" -- "$key" | grep -qE '^100(644|755) blob ' \
                || fail "$label: $key is not a file in the repository"
            SCHEMA_FILE="$key"
            USES_DATABASE=true
            continue
        fi

        plain_path "$file" || fail "$label: '$file' is not a plain path inside the repository"
        ! tracked "$file" || fail "$label: $file is tracked in the repository; env files hold secrets, so they must not be"
        [[ "$key" =~ $KEY_PATTERN ]] || fail "$label: '$key' is not a valid variable name"

        case "$kind" in
            database)
                [[ "$arg" =~ ^(host|port|name|user|password)$ ]] || fail "$label: expected database host, port, name, user, or password"
                USES_DATABASE=true
                ;;
            domain | url)
                [[ -z "$arg" ]] || fail "$label: $kind takes nothing after it"
                ;;
            random)
                [[ "$arg" == laravel-key ]] \
                    || { [[ "$arg" =~ ^(hex|base64)\ +([1-9][0-9]{0,2})$ ]] && ((BASH_REMATCH[2] >= 8 && BASH_REMATCH[2] <= 256)); } \
                    || fail "$label: expected random hex <bytes> or random base64 <bytes>, with 8 to 256 bytes, or random laravel-key"
                ;;
            ask | secret)
                # Shown on the terminal, so only printable characters
                arg="${arg//[^[:print:]]/}"
                [[ -n "$arg" ]] || fail "$label: $kind needs the text to ask with"
                ;;
            *)
                fail "$label: expected database, domain, url, random, ask, or secret after the variable name"
                ;;
        esac

        E_FILE+=("$file")
        E_KEY+=("$key")
        E_KIND+=("$kind")
        E_ARG+=("$arg")
    done < <(git -C "$PROJECT_DIR" cat-file blob "$COMMIT:$SETUP_FILE")
}

# The project's database password, generated into its config file the first
# time setup.conf asks for the database. deploy.sh then gives it a database.
database_password() {
    local password
    password="$(file_value "$CONFIG_FILE" DATABASE_PASSWORD)"

    if [[ -z "$password" ]]; then
        password="$(openssl rand -hex 24)"
        echo "DATABASE_PASSWORD=$password" >> "$CONFIG_FILE"
    fi

    echo "$password"
}

# The value of an entry that is filled in from this server's settings
derived_value() {
    case "$1:$2" in
        database:host) echo "shared-mariadb" ;;
        database:port) echo "3306" ;;
        database:name | database:user) echo "${NAME//-/_}" ;;
        database:password) echo "$DATABASE_PASSWORD" ;;
        domain:) echo "$DOMAIN" ;;
        url:) echo "https://$DOMAIN" ;;
    esac
}

# A random secret from OpenSSL's cryptographically secure generator: hex or
# base64 of the given number of bytes, or a Laravel APP_KEY, which is
# "base64:" and 32 bytes in base64, as `php artisan key:generate` writes it
# for Laravel's default cipher, AES-256-CBC
random_value() {
    local format bytes
    read -r format bytes <<< "$1"

    case "$format" in
        hex) openssl rand -hex "$bytes" ;;
        base64) openssl rand -base64 "$bytes" | tr -d '\n' ;;
        laravel-key) echo "base64:$(openssl rand -base64 32 | tr -d '\n')" ;;
    esac
}

# Works out every value before writing anything, so stopping partway, such
# as with Ctrl-C at a prompt, leaves the files as they were. Values from
# this server's settings are always written, so changing a domain or a
# database password and deploying updates them. Generated and entered values
# are written only if the file doesn't have them yet. Fills the V_* lists;
# MISSING lists what must be entered by hand when there is no one to ask.
plan_values() {
    local prompt="$1" i file kind stored default
    V_INDEX=()
    V_VALUE=()
    MISSING=()

    for i in "${!E_KEY[@]}"; do
        file="${E_FILE[$i]}"
        kind="${E_KIND[$i]}"
        stored="$ENV_DIR/$file"

        case "$kind" in
            database | domain | url)
                V_INDEX+=("$i")
                V_VALUE+=("$(derived_value "$kind" "${E_ARG[$i]}")")
                continue
                ;;
        esac

        # A generated secret is never empty, so an empty one, such as the
        # APP_KEY= that Laravel's .env.example holds, is generated
        if has_key "$stored" "${E_KEY[$i]}" \
            && [[ "$kind" != random || -n "$(file_value "$stored" "${E_KEY[$i]}")" ]]; then
            continue
        fi

        case "$kind" in
            random)
                V_INDEX+=("$i")
                V_VALUE+=("$(random_value "${E_ARG[$i]}")")
                ;;
            ask | secret)
                if [[ "$prompt" != true ]]; then
                    MISSING+=("$file ${E_KEY[$i]}")
                    continue
                fi

                # A file not set up yet starts from its example, whose value
                # is offered for plain values. Secrets get no default.
                default=""
                if [[ "$kind" == ask && ! -f "$stored" ]]; then
                    default="$(example "$file" | file_value /dev/stdin "${E_KEY[$i]}")"
                fi

                V_INDEX+=("$i")
                V_VALUE+=("$(ask_value "${E_ARG[$i]}" "$default" "$([[ "$kind" == secret ]] && echo true || echo false)")")
                ;;
        esac
    done
}

# Prints the commit's <file>.example, or nothing if it has none
example() {
    git -C "$PROJECT_DIR" cat-file blob "$COMMIT:$1.example" 2> /dev/null || true
}

# Writes the planned values into config/<name>/. A file not set up yet
# starts as a copy of the commit's <file>.example, if there is one. The
# files hold secrets, so only their owner can read them.
write_values() {
    local n i file stored

    (
        umask 077
        mkdir -p "$ENV_DIR"

        for n in "${!V_INDEX[@]}"; do
            i="${V_INDEX[$n]}"
            file="${E_FILE[$i]}"
            stored="$ENV_DIR/$file"

            if [[ ! -f "$stored" ]]; then
                mkdir -p "$(dirname "$stored")"
                example "$file" > "$stored"
            fi

            set_env "$stored" "${E_KEY[$i]}" "$(quote "${V_VALUE[$n]}")"
        done
    )
}

# Copies every file in config/<name>/ into the clone, where the project's
# Compose file reads it. Each one must land inside the clone, never through
# a symbolic link the repository contains, and never over a tracked file.
install_files() {
    local stored file target dir clone

    [[ -d "$ENV_DIR" ]] || return 0
    clone="$(realpath "$PROJECT_DIR")"

    while IFS= read -r -d '' stored; do
        file="${stored#"$ENV_DIR/"}"
        target="$PROJECT_DIR/$file"
        dir="$(realpath -m "$(dirname "$target")")"

        [[ "$file" =~ $PATH_PATTERN && "$file" != *..* ]] || fail "config/$NAME/$file is not a plain path"
        [[ "$dir/" == "$clone/"* || "$dir" == "$clone" ]] || fail "projects/$NAME/$file would be written outside the clone"
        [[ ! -L "$target" ]] || fail "projects/$NAME/$file is a symbolic link"
        ! tracked "$file" || fail "$file is tracked in $NAME's repository, so config/$NAME/$file cannot replace it"

        mkdir -p "$dir"
        install -m 600 "$stored" "$target"
    done < <(find "$ENV_DIR" -type f -print0)
}

print_missing() {
    echo "$NAME needs values that have to be entered by hand:" >&2
    printf '  %s\n' "${MISSING[@]}" >&2
}

# --- Main ---------------------------------------------------------------------

# Run by hand, or by add-project.sh: fetches the branch, and asks for
# anything not set yet
configure() {
    local prompt=false
    load_project "$1"

    # Never alongside a deploy of the same project, which fetches too
    mkdir -p "$GENERATED_DIR/locks"
    exec 9> "$GENERATED_DIR/locks/$NAME.lock"
    flock 9

    fetch
    read_setup

    if [[ ${#E_KEY[@]} -eq 0 && "$USES_DATABASE" != true ]]; then
        info "$NAME has no $SETUP_FILE, or it asks for nothing, so it needs no setup"
        return
    fi

    info "Setting up $NAME's env files from its $SETUP_FILE"
    [[ "$USES_DATABASE" != true ]] || DATABASE_PASSWORD="$(database_password)"

    # Values are asked for at a terminal; without one, only those that can
    # be generated are filled in
    [[ ! -t 0 ]] || prompt=true
    plan_values "$prompt"

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        print_missing
        fail "run ./configure-project.sh $NAME at a terminal to enter them"
    fi

    write_values
    info "$NAME's env files are in config/$NAME/"
}

# Run by deploy.sh, holding the project's lock, after checking out the commit
deploy() {
    load_project "$1"
    COMMIT="$(git -C "$PROJECT_DIR" rev-parse --verify "$2^{commit}")" || fail "$NAME has no commit $2"

    read_setup
    [[ "$USES_DATABASE" != true ]] || DATABASE_PASSWORD="$(database_password)"
    plan_values false

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        print_missing
        fail "enter them with ./configure-project.sh $NAME, then deploy again"
    fi

    write_values
    install_files
}

# Run by database.sh, after creating the project's database: prints the
# SQL file the commit's setup.conf names, or nothing
schema() {
    load_project "$1"
    COMMIT="$(git -C "$PROJECT_DIR" rev-parse --verify "$2^{commit}")" || fail "$NAME has no commit $2"

    read_setup
    echo "$SCHEMA_FILE"
}

main() {
    check_system

    case "${1:-}:$#" in
        --deploy:3) deploy "$2" "$3" ;;
        --schema:3) schema "$2" "$3" ;;
        -*) usage ;;
        *:1) configure "$1" ;;
        *) usage ;;
    esac
}

main "$@"
exit
