#!/usr/bin/env bash
#
# Deploys a project: fetches the latest commit of its branch into
# projects/<name>, builds its images from that commit while the running
# containers keep serving the site, then replaces the containers. Run from
# the clone, as root on a server or as yourself on your own computer:
#
#   ./deploy.sh glitch            Deploy the latest commit of glitch's branch
#   ./deploy.sh glitch <commit>   Deploy an earlier commit of the branch, such
#                                 as to roll back; the next push deploys the
#                                 latest commit again
#   ./deploy.sh --watch           Deploy each project whenever the webhook
#                                 asks, as a server's systemd units do; stop
#                                 with Ctrl-C
#
# On a server, systemd runs `deploy.sh <name>` when the project's webhook
# fires. See "Deploys" in docs/how-it-works.md.

set -euo pipefail

# All work happens in functions called from the last line, so a deploy
# that updates this repository cannot affect a run in progress.

# How many releases of each project keep their images, for a rollback
KEEP_RELEASES=3

# How long the new containers have to pass their health checks, in seconds
HEALTH_TIMEOUT=300

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    echo "Usage: ./deploy.sh <project> [<commit>] | --watch" >&2
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
    GENERATED_DIR="$INSTALL_DIR/generated"

    [[ -f "$INSTALL_DIR/.env" ]] || fail "$INSTALL_DIR/.env is missing; run setup.sh first"
    command -v jq > /dev/null || fail "jq is missing; run setup.sh, or install jq"

    case "$(file_value "$INSTALL_DIR/.env" SERVER_ENVIRONMENT)" in
        staging) DEFAULT_BRANCH="main" ;;
        production) DEFAULT_BRANCH="release" ;;
        *) fail "SERVER_ENVIRONMENT in .env must be staging or production; run setup.sh" ;;
    esac
}

# Reads the project's settings from config/<name>.conf
load_project() {
    NAME="$1"
    local file="$INSTALL_DIR/config/$NAME.conf" upstream

    [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ && -f "$file" ]] || fail "$NAME is not on this server (no config/$NAME.conf)"

    REPO="$(file_value "$file" REPO)"
    BRANCH="$(file_value "$file" BRANCH)"
    BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
    upstream="$(file_value "$file" UPSTREAM)"
    WEB_SERVICE="${upstream:-nginx:80}"
    WEB_SERVICE="${WEB_SERVICE%%:*}"

    # A project with a database password uses the shared database
    USES_DATABASE=false
    [[ -z "$(file_value "$file" DATABASE_PASSWORD)" ]] || USES_DATABASE=true

    PROJECT_DIR="$INSTALL_DIR/projects/$NAME"
    PROJECT_GENERATED="$GENERATED_DIR/projects/$NAME"
    OVERRIDE="$PROJECT_GENERATED/compose.server.yml"

    # The commits deployed, newest last; the last one is running
    RELEASES="$PROJECT_GENERATED/releases"

    # The project's own maintenance pages, and the flag that tells Caddy a
    # deploy is replacing its containers (the maintenance snippet in
    # caddy/Caddyfile)
    PAGES_DIR="$GENERATED_DIR/maintenance/$NAME"
}

# Prints the project's Compose file
compose_file() {
    local file
    for file in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [[ -f "$PROJECT_DIR/$file" ]]; then
            echo "$PROJECT_DIR/$file"
            return
        fi
    done
    return 1
}

# Runs docker compose on the project's Compose file and the generated one.
# The project's docker-compose.override.yml, for local development, is left
# out, since the files are named explicitly.
compose() {
    docker compose --project-name "$NAME" --file "$PROJECT_COMPOSE" --file "$OVERRIDE" "$@"
}

# Prints the services the project builds from its repository, one per line
built_services() {
    docker compose --project-name "$NAME" --file "$PROJECT_COMPOSE" config --format json \
        | jq -r '.services | to_entries[] | select(.value.build != null) | .key'
}

# Prints the services that join the project's database network, one per
# line: all of them, if the project uses the shared database, except those
# that share another container's network
database_services() {
    [[ "$USES_DATABASE" == true ]] || return 0

    docker compose --project-name "$NAME" --file "$PROJECT_COMPOSE" config --format json \
        | jq -r '.services | to_entries[] | select(.value.network_mode == null) | .key'
}

# The image a built service runs: named after the project and service, and
# tagged with the first 12 characters of the commit
image_name() {
    local service="${1,,}"
    echo "$NAME-$service:${COMMIT:0:12}"
}

# Writes the Compose file each deploy adds to the project's own:
#
# - Connects the project's web service to the shared web network, where
#   Caddy reaches it as <name>-<service>. Nothing else in the project joins
#   it, so projects cannot reach each other's databases.
# - If the project uses the shared database, connects its services to its
#   own database network, <name>-database, where they reach the database as
#   shared-mariadb. Only this project's containers join that network.
# - Tags each image the project builds with the commit, and labels it with
#   the full commit, so the images of earlier releases stay available for a
#   rollback and every container shows the commit it runs.
write_override() {
    local service web database

    mkdir -p "$PROJECT_GENERATED"
    {
        echo "# Generated by deploy.sh for $NAME at commit $COMMIT. Connects the"
        echo "# $WEB_SERVICE service to the shared web network, the services that use"
        echo "# the shared database to the project's database network, and tags the"
        echo "# images the project builds with the commit."
        echo "services:"

        for service in $(printf '%s\n' "$WEB_SERVICE" $BUILT_SERVICES $DATABASE_SERVICES | sort -u); do
            echo "  \"$service\":"

            web=false
            database=false
            if [[ "$service" == "$WEB_SERVICE" ]]; then
                web=true
            fi
            if grep -qxF "$service" <<< "$DATABASE_SERVICES"; then
                database=true
            fi

            if $web || $database; then
                echo "    networks:"
                echo "      default: {}"
            fi

            if $web; then
                echo "      web:"
                echo "        aliases:"
                echo "          - $NAME-$WEB_SERVICE"
            fi

            if $database; then
                echo "      database: {}"
            fi

            if grep -qxF "$service" <<< "$BUILT_SERVICES"; then
                echo "    image: $(image_name "$service")"
                echo "    build:"
                echo "      labels:"
                echo "        org.opencontainers.image.revision: $COMMIT"
            fi
        done

        echo
        echo "networks:"
        echo "  web:"
        echo "    external: true"

        if [[ "$USES_DATABASE" == true ]]; then
            echo "  database:"
            echo "    name: $NAME-database"
            echo "    external: true"
        fi
    } > "$OVERRIDE"
}

# Succeeds if a path holds files tracked in the project's repository: a
# tracked file, a directory with tracked files in it, or a directory that
# contains the whole clone. Symbolic links are checked both as given and
# resolved.
is_tracked() {
    local path dir relative

    for path in "$1" "$(realpath -m "$1")"; do
        path="${path%/}"

        for dir in "$PROJECT_DIR" "$(realpath -m "$PROJECT_DIR")"; do
            if [[ -z "$path" || "$dir/" == "$path/"* ]]; then
                return 0
            fi

            if [[ "$path" == "$dir/"* ]]; then
                relative="${path#"$dir/"}"
                if [[ -n "$(GIT_LITERAL_PATHSPECS=1 git -C "$PROJECT_DIR" ls-files --recurse-submodules -- "$relative" | head -n 1)" ]]; then
                    return 0
                fi
            fi
        done
    done

    return 1
}

# Refuses to deploy a project that mounts files from its repository into its
# containers. The running site must come only from the images built from
# one commit: a mounted directory would change as soon as the clone checks
# out a new commit, before the new images are built. Files the repository
# does not track, such as a .env with secrets, can still be mounted.
check_mounts() {
    local config entry source found=()

    config="$(compose config --format json)" || fail "the Compose configuration of $NAME is not valid"

    while IFS=$'\t' read -r entry source; do
        [[ -n "$source" ]] || continue
        if is_tracked "$source"; then
            found+=("$entry mounts ${source#"$PROJECT_DIR/"}")
        fi
    done < <(jq -r '
        (.services | to_entries[] | .key as $service
            | (.value.volumes // [])[] | select(.type == "bind")
            | ["the \($service) service", .source]),
        ((.configs // {}) | to_entries[] | select(.value.file != null)
            | ["the \(.key) config", .value.file]),
        ((.secrets // {}) | to_entries[] | select(.value.file != null)
            | ["the \(.key) secret", .value.file])
        | @tsv' <<< "$config")

    if [[ ${#found[@]} -gt 0 ]]; then
        printf '  %s\n' "${found[@]}" >&2
        fail "$NAME mounts files from its repository, but servers run code only from images. Build these files into an image, and keep mounts for local development in docker-compose.override.yml. The running containers were left unchanged."
    fi
}

# Waits until every container of the project is running and passes its
# health check, if it has one. A container that exited on its own with
# status 0, such as a one-off migration, counts as done. (`docker compose up
# --wait` would fail on such a container.)
wait_until_healthy() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT)) ids name state code health pending failed

    log "Waiting for $NAME's containers to start and pass their health checks"

    while true; do
        pending=()
        failed=()
        mapfile -t ids < <(compose ps --all --quiet)
        [[ ${#ids[@]} -gt 0 ]] || return 0

        while read -r name state code health; do
            name="${name#/}"
            case "$state:$health" in
                running: | running:healthy) ;;
                running:unhealthy) failed+=("$name is unhealthy") ;;
                exited:*)
                    [[ "$code" == "0" ]] || failed+=("$name exited with status $code")
                    ;;
                dead:*) failed+=("$name is dead") ;;
                *) pending+=("$name ($state${health:+, $health})") ;;
            esac
        done < <(docker inspect --format '{{.Name}} {{.State.Status}} {{.State.ExitCode}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "${ids[@]}")

        if [[ ${#failed[@]} -gt 0 ]]; then
            printf '  %s\n' "${failed[@]}" >&2
            return 1
        fi

        [[ ${#pending[@]} -gt 0 ]] || return 0

        if [[ $SECONDS -ge $deadline ]]; then
            printf '  %s did not become ready\n' "${pending[@]}" >&2
            return 1
        fi

        sleep 2
    done
}

# Copies the project's own maintenance pages from the commit being deployed,
# maintenance/updating.html and maintenance/unavailable.html, for Caddy to
# show instead of the shared ones in caddy/pages/. A page the commit doesn't
# have is removed, so the shared one is shown.
publish_pages() {
    local page

    mkdir -p "$PAGES_DIR"
    for page in updating.html unavailable.html; do
        if git -C "$PROJECT_DIR" ls-tree "$COMMIT" -- "maintenance/$page" | grep -qE '^100(644|755) blob '; then
            git -C "$PROJECT_DIR" cat-file blob "$COMMIT:maintenance/$page" > "$PAGES_DIR/$page.new"
            chmod 644 "$PAGES_DIR/$page.new"
            mv "$PAGES_DIR/$page.new" "$PAGES_DIR/$page"
        else
            rm -f "$PAGES_DIR/$page"
        fi
    done
}

# While the flag exists, Caddy shows the updating page rather than the
# unavailable one when the project can't answer
deploying_on() {
    mkdir -p "$PAGES_DIR"
    touch "$PAGES_DIR/deploying"
}

deploying_off() {
    if [[ -n "${PAGES_DIR:-}" ]]; then
        rm -f "$PAGES_DIR/deploying"
    fi
}

# Records the commit now running, keeping the newest releases
record_release() {
    {
        grep -vxF "$COMMIT" "$RELEASES" 2> /dev/null || true
        echo "$COMMIT"
    } | tail -n "$KEEP_RELEASES" > "$RELEASES.new"
    mv "$RELEASES.new" "$RELEASES"
}

# Removes the images of releases no longer recorded, including the ones
# Compose tagged latest before deploys tagged them with commits, and
# leftover build layers
remove_old_images() {
    local service repository tag keep=()

    mapfile -t keep < <(cut -c 1-12 "$RELEASES")

    for service in $BUILT_SERVICES; do
        repository="$(image_name "$service")"
        repository="${repository%:*}"

        docker image ls --format '{{.Tag}}' "$repository" | while read -r tag; do
            [[ "$tag" != "<none>" ]] || continue
            printf '%s\n' "${keep[@]}" | grep -qxF "$tag" && continue
            docker image rm "$repository:$tag" > /dev/null || true
        done
    done

    docker image prune --force > /dev/null
}

# Deploys a commit: FETCH_HEAD, or a full commit hash
deploy_commit() {
    local previous

    # Discards changes to tracked files; untracked files, such as the
    # project's own .env, are kept. The running containers don't use the
    # clone's files, so this changes nothing on the site until they are
    # replaced below.
    git -C "$PROJECT_DIR" checkout --quiet --force -B "$BRANCH" "$1"
    git -C "$PROJECT_DIR" submodule --quiet update --init --recursive
    COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    log "Deploying $NAME $(git -C "$PROJECT_DIR" log -1 --format='%h %s')"

    PROJECT_COMPOSE="$(compose_file)" || fail "projects/$NAME has no docker-compose.yml or compose.yaml"
    BUILT_SERVICES="$(built_services)" || fail "the Compose configuration of $NAME is not valid"
    DATABASE_SERVICES="$(database_services)" || fail "the Compose configuration of $NAME is not valid"
    write_override
    check_mounts

    # Starts the shared database if needed, and creates the project's
    # network, database, and user before its containers need them
    if [[ "$USES_DATABASE" == true ]]; then
        "$INSTALL_DIR/database.sh" prepare "$NAME" \
            || fail "preparing $NAME's database failed; the running containers were left unchanged"
    fi

    # The site keeps running the old containers while the images are pulled
    # and built, and a failure leaves them running
    log "Pulling the images $NAME uses without building them"
    compose pull --ignore-buildable --policy missing --quiet \
        || fail "pulling $NAME's images failed; the running containers were left unchanged"

    log "Building $NAME's images"
    compose build || fail "building $NAME's images failed; the running containers were left unchanged"

    # Until the new containers are ready, visitors who reach an unavailable
    # site see that it is being updated
    publish_pages
    deploying_on

    log "Switching $NAME to the new containers"
    compose up --detach --no-build --remove-orphans

    if ! wait_until_healthy; then
        deploying_off
        previous="$(tail -n 1 "$RELEASES" 2> /dev/null || true)"
        echo "The new containers of $NAME are running, but not all of them are ready." >&2
        if [[ -n "$previous" && "$previous" != "$COMMIT" ]]; then
            echo "To go back to the previous release: ./deploy.sh $NAME ${previous:0:12}" >&2
        fi
        fail "deploying $NAME ${COMMIT:0:12} failed"
    fi

    deploying_off
    record_release
    remove_old_images

    log "Deployed $NAME ${COMMIT:0:12}"
}

# Prints the full hash of a commit on the project's branch, as fetched
branch_commit() {
    local commit

    [[ "$1" =~ ^[0-9a-f]{7,40}$ ]] || fail "$1 is not a commit hash"
    commit="$(git -C "$PROJECT_DIR" rev-parse --quiet --verify "$1^{commit}")" \
        || fail "$NAME has no commit $1"
    git -C "$PROJECT_DIR" merge-base --is-ancestor "$commit" FETCH_HEAD \
        || fail "commit $1 is not on $NAME's $BRANCH branch"

    echo "$commit"
}

# Clones the project the first time, then fetches its branch. Prints
# nothing; the fetched commit is left in FETCH_HEAD.
fetch() {
    if [[ ! -d "$PROJECT_DIR/.git" ]]; then
        log "Cloning $REPO into projects/$NAME"
        mkdir -p "$(dirname "$PROJECT_DIR")"
        git clone --quiet --no-checkout "$REPO" "$PROJECT_DIR"
    fi

    # The repository may have been changed in config/<name>.conf
    git -C "$PROJECT_DIR" remote set-url origin "$REPO"
    git -C "$PROJECT_DIR" fetch --quiet origin "$BRANCH" || fail "could not fetch the $BRANCH branch of $REPO"
}

deploy() {
    local commit
    load_project "$1"

    # A deploy that stops early never leaves the updating page on
    trap deploying_off EXIT

    # One deploy per project at a time; a request that arrives meanwhile
    # waits, and then deploys whatever is newest
    mkdir -p "$GENERATED_DIR/locks"
    exec 9> "$GENERATED_DIR/locks/$NAME.lock"
    flock 9

    log "Fetching the latest commit of $NAME's $BRANCH branch"
    fetch

    # An earlier commit, deployed by hand. Commits pushed meanwhile are left
    # for the next push to deploy.
    if [[ -n "${2:-}" ]]; then
        commit="$(branch_commit "$2")"
        deploy_commit "$commit"
        log "The next push to $BRANCH deploys its latest commit again"
        return
    fi

    deploy_commit FETCH_HEAD

    # Deploy again if more commits were pushed during the deploy
    while fetch && [[ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" != "$(git -C "$PROJECT_DIR" rev-parse FETCH_HEAD)" ]]; do
        log "New commits arrived during the deploy"
        deploy_commit FETCH_HEAD
    done
}

# Deploys each project whose trigger file the webhook writes, the way a
# server's systemd path units do. Requests made before the watch started are
# not deployed.
watch() {
    local triggers="$GENERATED_DIR/triggers" file name stamp
    local -A seen=()

    for file in "$triggers"/*; do
        [[ -f "$file" ]] && seen[$(basename "$file")]="$(date -r "$file" +%s%N)"
    done

    log "Watching $triggers for deploy requests; stop with Ctrl-C"

    while true; do
        for file in "$triggers"/*; do
            [[ -f "$file" ]] || continue
            name="$(basename "$file")"
            stamp="$(date -r "$file" +%s%N)"
            [[ "${seen[$name]:-}" != "$stamp" ]] || continue
            seen[$name]="$stamp"

            # A failed deploy is reported, and the watch goes on
            "$INSTALL_DIR/deploy.sh" "$name" || log "Deploying $name failed"
        done
        sleep 2
    done
}

main() {
    [[ $# -ge 1 && $# -le 2 ]] || usage

    check_system

    case "$1" in
        --watch)
            [[ $# -eq 1 ]] || usage
            watch
            ;;
        -*) usage ;;
        *) deploy "$@" ;;
    esac
}

main "$@"
exit
