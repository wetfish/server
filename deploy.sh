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

# Where the server's storage is mounted; a project's volumes listed in
# VOLUMES keep their files in <STORAGE_ROOT>/<hostname>/<name>/<volume>,
# in the directory storage.sh setup claimed for this server
STORAGE_ROOT="/mnt/virtual"
CLAIM_FILE=".wetfish-server"
VOLUME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9_.-]*$'

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

    SERVER_HOSTNAME="$(file_value "$INSTALL_DIR/.env" SERVER_HOSTNAME)"
    [[ -n "$SERVER_HOSTNAME" ]] || fail "SERVER_HOSTNAME is not set in .env; run setup.sh"
    SERVER_DIR="$STORAGE_ROOT/$SERVER_HOSTNAME"
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

    # The volumes the project keeps on the server's storage
    STORAGE_VOLUMES="$(file_value "$file" VOLUMES)"

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

# Prints each service that mounts named volumes, a tab, and the Docker
# volume each of them uses, as <volume>=<Docker volume> separated by
# spaces: the storage volume for those listed in VOLUMES, and otherwise the
# project's own. One service per line.
volume_mounts() {
    docker compose --project-name "$NAME" --file "$PROJECT_COMPOSE" config --format json \
        | jq -r --arg name "$NAME" --arg storage " $STORAGE_VOLUMES " '
            .volumes as $volumes
            | .services | to_entries[] | .key as $service
            | [(.value.volumes // [])[] | select(.type == "volume" and (.source // "") != "") | .source]
            | unique | select(length > 0)
            | map(. as $volume | "\($volume)=" + (
                if ($storage | contains(" \($volume) ")) then "storage.\($name).\($volume)"
                else ($volumes[$volume].name // "\($name)_\($volume)") end))
            | [$service, join(" ")] | @tsv'
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
# - Replaces each volume the project keeps on the server's storage with the
#   Docker volume that binds its directory there. It is external, so
#   Compose never offers to recreate it, which would lose its files.
# - Labels each service that mounts named volumes with the Docker volumes
#   it uses. The label changes whenever a volume moves onto storage or off
#   it, which makes Compose replace the service's containers. Compose
#   doesn't always do that for a changed volume by itself, and a container
#   left running would keep using the old volume.
write_override() {
    local service web database volume mounts mount_services

    mount_services="$(cut -f 1 <<< "$VOLUME_MOUNTS")"

    mkdir -p "$PROJECT_GENERATED"
    {
        echo "# Generated by deploy.sh for $NAME at commit $COMMIT. Connects the"
        echo "# $WEB_SERVICE service to the shared web network, the services that use"
        echo "# the shared database to the project's database network, tags the"
        echo "# images the project builds with the commit, and keeps the volumes"
        echo "# listed in VOLUMES on the server's storage."
        echo "services:"

        for service in $(printf '%s\n' "$WEB_SERVICE" $BUILT_SERVICES $DATABASE_SERVICES $mount_services | sed '/^$/d' | sort -u); do
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

            mounts="$(awk -F '\t' -v service="$service" '$1 == service { print $2 }' <<< "$VOLUME_MOUNTS")"
            if [[ -n "$mounts" ]]; then
                echo "    labels:"
                echo "      org.wetfish.server.volumes: \"$mounts\""
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

        if [[ -n "$STORAGE_VOLUMES" ]]; then
            echo
            echo "volumes:"
            for volume in $STORAGE_VOLUMES; do
                echo "  \"$volume\":"
                echo "    name: $(storage_volume "$volume")"
                echo "    external: true"
            done
        fi
    } > "$OVERRIDE"
}

# The Docker volume that binds a volume's directory on the server's storage.
# Its name can't be that of any volume Compose creates, <project>_<volume>,
# since project names never contain '.', so the project's own volume stays
# separate from it.
storage_volume() {
    echo "storage.$NAME.$1"
}

# Prints what a Docker volume holds: empty, files, or unreadable, when the
# user running this, such as yourself on a local copy, can't look inside
volume_contents() {
    local path
    path="$(docker volume inspect --format '{{.Mountpoint}}' "$1" 2> /dev/null)" || { echo unreadable; return; }

    if [[ ! -r "$path" || ! -x "$path" ]]; then
        echo unreadable
    elif [[ -z "$(find "$path" -mindepth 1 -print -quit)" ]]; then
        echo empty
    else
        echo files
    fi
}

# Fails unless this server's directory on storage is claimed by this
# machine, so two servers given the same hostname never share files
check_claim() {
    local claim="$SERVER_DIR/$CLAIM_FILE" id owner

    id="$(cat /etc/machine-id 2> /dev/null || true)"
    [[ -n "$id" ]] || fail "/etc/machine-id is missing, so this machine's claim on $SERVER_DIR can't be checked; the running containers were left unchanged"

    [[ -f "$claim" ]] \
        || fail "$SERVER_DIR has no claim; run ./storage.sh setup on this server; the running containers were left unchanged"

    owner="$(file_value "$claim" MACHINE_ID)"
    [[ "$owner" == "$id" ]] \
        || fail "$SERVER_DIR is claimed by another machine ($(file_value "$claim" HOSTNAME), since $(file_value "$claim" CLAIMED)), which may still use it. If it no longer does, run ./storage.sh setup --take-over; the running containers were left unchanged"
}

# Prints how to move the files of the project's own volume onto storage
print_move_to_storage() {
    local volume="$1" plain="$2" dir="$3" contents="$4"

    if [[ "$contents" == unreadable ]]; then
        cat << EOF >&2

$plain exists, but $(id -un) can't read it to check whether it holds
files from before $volume was kept on storage. See what it holds, as root:

  sudo ls -A "\$(docker volume inspect --format '{{.Mountpoint}}' $plain)"

If it is empty, remove it and deploy:

  docker compose --project-name $NAME down
  docker volume rm $plain
  ./deploy.sh $NAME

If it holds files, move them into
$dir first, as below.
EOF
    fi

    [[ "$contents" == unreadable ]] || echo -e "\n$plain holds files from before $volume was kept on storage." >&2

    cat << EOF >&2

To move its files onto storage, stop $NAME, whose site then shows the
unavailable page, and copy them as root:

  docker compose --project-name $NAME down
  cp -a "\$(docker volume inspect --format '{{.Mountpoint}}' $plain)/." $dir/

Once the copy is checked, remove the old volume and deploy:

  docker volume rm $plain
  ./deploy.sh $NAME

To keep $volume on the root disk instead: ./storage.sh remove $NAME $volume
EOF
}

# Prepares the volumes the project keeps on the server's storage, before
# anything is pulled or built, so a problem leaves the running containers
# unchanged. Each volume's files go in <SERVER_DIR>/<name>/<volume>,
# through a Docker volume that binds the directory. Refuses if the storage
# isn't mounted, if this server's directory on it is missing or claimed by
# another machine, if the project's Compose file defines the volume in a way
# an external volume can't be, or if the project's own volume still holds
# files, which would otherwise be left behind.
prepare_storage() {
    [[ -n "$STORAGE_VOLUMES" ]] || return 0

    local config volume custom keys dir plain storage details contents
    local unchanged="the running containers were left unchanged"

    log "Preparing $NAME's volumes on the server's storage"

    findmnt --noheadings --mountpoint "$STORAGE_ROOT" > /dev/null 2>&1 \
        || fail "$NAME keeps files on the server's storage, but nothing is mounted at $STORAGE_ROOT. Mount it (mount $STORAGE_ROOT, or ./storage.sh setup) and deploy again; $unchanged."

    # Only storage.sh setup creates this server's directory, so a deploy
    # after the hostname changes refuses rather than starting empty
    [[ -d "$SERVER_DIR" && ! -L "$SERVER_DIR" ]] \
        || fail "$NAME keeps files on the server's storage, but $SERVER_DIR, this server's directory on it, doesn't exist. Run ./storage.sh setup to create it, or, if this server's hostname changed, rename its old directory on storage to $SERVER_HOSTNAME first; $unchanged."
    check_claim

    config="$(docker compose --project-name "$NAME" --file "$PROJECT_COMPOSE" config --format json)" \
        || fail "the Compose configuration of $NAME is not valid"

    for volume in $STORAGE_VOLUMES; do
        [[ "$volume" =~ $VOLUME_PATTERN ]] || fail "config/$NAME.conf: '$volume' in VOLUMES is not a valid Compose volume name"

        jq -e --arg volume "$volume" '(.volumes // {}) | has($volume)' <<< "$config" > /dev/null \
            || fail "config/$NAME.conf keeps the $volume volume on storage, but $NAME's Compose file defines no $volume volume under its top-level volumes; $unchanged"

        # The volume is replaced with an external one, which can have
        # nothing but a name. The project's own name for it would also
        # point to files the storage volume doesn't have.
        custom="$(jq -r --arg volume "$volume" '.volumes[$volume].name // ""' <<< "$config")"
        [[ -z "$custom" || "$custom" == "${NAME}_$volume" ]] \
            || fail "$NAME's Compose file names the $volume volume $custom; remove its name, which a volume on storage can't have; $unchanged"

        keys="$(jq -r --arg volume "$volume" '(.volumes[$volume] // {}) | keys_unsorted - ["name"] | join(", ")' <<< "$config")"
        [[ -z "$keys" ]] \
            || fail "$NAME's Compose file sets $keys on the $volume volume; remove them, since a volume on storage can't have them; $unchanged"

        # Created only now that the storage is known to be mounted, so it is
        # never created on the root disk
        dir="$SERVER_DIR/$NAME/$volume"
        mkdir -p "$dir" 2> /dev/null \
            || fail "could not create $dir. The storage mounted at $STORAGE_ROOT must be writable by $(id -un), who runs this deploy, and not immutable (lsattr -d $STORAGE_ROOT shows an 'i' if it is); $unchanged"
        [[ "$(realpath "$dir")" == "$dir" && "$(findmnt --noheadings --first-only --output TARGET --target "$dir")" == "$STORAGE_ROOT" ]] \
            || fail "$dir is not a directory on the storage mounted at $STORAGE_ROOT, such as because of a symbolic link; $unchanged"

        plain="${NAME}_$volume"
        if docker volume inspect "$plain" > /dev/null 2>&1; then
            contents="$(volume_contents "$plain")"
            if [[ "$contents" != empty ]]; then
                print_move_to_storage "$volume" "$plain" "$dir" "$contents"
                if [[ "$contents" == unreadable ]]; then
                    fail "$NAME's $plain volume exists, and $(id -un) can't check whether it holds files; $unchanged"
                fi
                fail "$NAME's $plain volume still holds files; $unchanged"
            fi
        fi

        storage="$(storage_volume "$volume")"
        if details="$(docker volume inspect "$storage" 2> /dev/null)"; then
            # Never deleted or recreated here, since it may hold files
            [[ "$(jq -r '.[0] | [.Driver, .Options.type, .Options.o, .Options.device] | map(. // "") | join(" ")' <<< "$details")" == "local none bind $dir" ]] \
                || fail "the Docker volume $storage exists but doesn't bind $dir. Check what it holds, remove it with docker volume rm $storage, and deploy again; $unchanged"
        fi
    done

    for volume in $STORAGE_VOLUMES; do
        storage="$(storage_volume "$volume")"
        if ! docker volume inspect "$storage" > /dev/null 2>&1; then
            docker volume create --driver local \
                --opt type=none --opt o=bind --opt device="$SERVER_DIR/$NAME/$volume" \
                --label "org.wetfish.server.project=$NAME" \
                --label "org.wetfish.server.volume=$volume" \
                "$storage" > /dev/null \
                || fail "creating the Docker volume $storage failed; $unchanged"
        fi
    done
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

    # Fills in the env files the commit's setup.conf asks for, and copies
    # config/<name>/ into the clone, before Compose reads the files
    "$INSTALL_DIR/configure-project.sh" --deploy "$NAME" "$COMMIT" \
        || fail "setting up $NAME's env files failed; the running containers were left unchanged"

    # setup.conf may have just given the project a database
    if [[ -n "$(file_value "$INSTALL_DIR/config/$NAME.conf" DATABASE_PASSWORD)" ]]; then
        USES_DATABASE=true
    fi

    PROJECT_COMPOSE="$(compose_file)" || fail "projects/$NAME has no docker-compose.yml or compose.yaml"
    BUILT_SERVICES="$(built_services)" || fail "the Compose configuration of $NAME is not valid"
    DATABASE_SERVICES="$(database_services)" || fail "the Compose configuration of $NAME is not valid"
    prepare_storage
    VOLUME_MOUNTS="$(volume_mounts)" || fail "the Compose configuration of $NAME is not valid"
    write_override
    check_mounts

    # Starts the shared database if needed, and creates the project's
    # network, database, and user before its containers need them, with
    # the tables of its schema if the database is new
    if [[ "$USES_DATABASE" == true ]]; then
        "$INSTALL_DIR/database.sh" prepare "$NAME" "$COMMIT" \
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
