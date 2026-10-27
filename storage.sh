#!/usr/bin/env bash
#
# Manages this server's storage: a Vultr file system, mounted at
# /mnt/virtual, where projects keep the files of the Compose volumes listed
# in VOLUMES in their config files, rather than on the root disk. Each
# server keeps its files in its own directory there, named after its
# hostname, so servers that attach the same file system never use each
# other's: /mnt/virtual/<hostname>/<project>/<volume>. Run from the clone:
#
#   ./storage.sh setup [--tag <mount tag>] [--take-over]
#                               Mounts the file system at /mnt/virtual now
#                               and at every boot, and claims this server's
#                               directory on it. On a local copy, claims the
#                               directory on what you mounted there.
#   ./storage.sh add <project> <volume>
#                               Keeps the volume's files on storage, and
#                               deploys the project
#   ./storage.sh remove <project> <volume>
#                               Keeps the volume on the root disk again, and
#                               deploys the project, if its directory on
#                               storage is empty; otherwise prints how to
#                               move its files first
#   ./storage.sh detach [--yes] Stops using the file system on this server,
#                               once no project keeps volumes on it: gives
#                               up the server's directory, unmounts it, and
#                               removes it from /etc/fstab. As root on a
#                               server.
#
# Deploys check the storage and set up each volume; see "Storage" in
# docs/how-it-works.md.

set -euo pipefail

STORAGE_ROOT="/mnt/virtual"
# The file in a server's directory on storage naming the machine that uses it
CLAIM_FILE=".wetfish-server"
NAME_PATTERN='^[a-z][a-z0-9-]*$'
VOLUME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9_.-]*$'
# Vultr's mount tags are numbers; other virtiofs tags are plain names
TAG_PATTERN='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
# Hostnames name each server's directory on storage
HOSTNAME_PATTERN='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
FSTAB_COMMENT="# Storage for projects, added by"

# All work happens in functions called from the last line, so a `git pull`
# that changes this file cannot affect a run in progress.

# --- Output -------------------------------------------------------------------

info() {
    echo "==> $*"
}

warn() {
    echo "Warning: $*" >&2
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    echo "Usage: ./storage.sh setup [--tag <mount tag>] [--take-over] | detach [--yes]" >&2
    echo "       ./storage.sh add <project> <volume> | remove <project> <volume>" >&2
    exit 1
}

# --- Settings -----------------------------------------------------------------

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

    SERVER_HOSTNAME="$(file_value "$INSTALL_DIR/.env" SERVER_HOSTNAME)"
    [[ "$SERVER_HOSTNAME" =~ $HOSTNAME_PATTERN ]] || fail "SERVER_HOSTNAME in .env is missing or not a valid hostname; run setup.sh"

    SERVER_DIR="$STORAGE_ROOT/$SERVER_HOSTNAME"
}

on_server() {
    [[ "$(id -u)" -eq 0 && -d /run/systemd/system ]]
}

# Succeeds if a file system is mounted at /mnt/virtual
mounted() {
    findmnt --noheadings --mountpoint "$STORAGE_ROOT" > /dev/null 2>&1
}

# Succeeds if a directory has nothing in it
empty_dir() {
    [[ -z "$(find "$1" -mindepth 1 -print -quit)" ]]
}

machine_id() {
    local id
    id="$(cat /etc/machine-id 2> /dev/null || true)"
    [[ "$id" =~ ^[0-9a-f]{32}$ ]] || fail "/etc/machine-id is missing or not valid, so this machine can't claim its directory on storage"
    echo "$id"
}

# Succeeds if this server's directory on storage exists and is claimed by
# this machine
claimed() {
    [[ -d "$SERVER_DIR" && ! -L "$SERVER_DIR" && -f "$SERVER_DIR/$CLAIM_FILE" ]] \
        && [[ "$(file_value "$SERVER_DIR/$CLAIM_FILE" MACHINE_ID)" == "$(machine_id)" ]]
}

# Fails unless the storage is mounted and this server's directory on it is
# claimed by this machine
require_storage() {
    mounted || fail "nothing is mounted at $STORAGE_ROOT; set up storage with ./storage.sh setup, or mount it"
    claimed || fail "$SERVER_DIR is not claimed by this server; run ./storage.sh setup"
}

# Reads the project's settings and the volume to add or remove
load_project() {
    NAME="$1"
    VOLUME="$2"
    CONFIG_FILE="$INSTALL_DIR/config/$NAME.conf"

    [[ "$NAME" =~ $NAME_PATTERN && -f "$CONFIG_FILE" ]] || fail "$NAME is not on this server (no config/$NAME.conf)"
    [[ "$VOLUME" =~ $VOLUME_PATTERN ]] || fail "'$VOLUME' is not a valid Compose volume name"

    VOLUMES="$(file_value "$CONFIG_FILE" VOLUMES)"
    DIR="$SERVER_DIR/$NAME/$VOLUME"
    PLAIN_VOLUME="${NAME}_$VOLUME"
    STORAGE_VOLUME="storage.$NAME.$VOLUME"
}

listed() {
    [[ " $VOLUMES " == *" $VOLUME "* ]]
}

# Writes VOLUMES to the project's config file, or removes it when no
# volumes are left; the rest of the file is kept as it is
write_volumes() {
    local volumes tmp
    volumes="$(echo "$1" | xargs)"
    tmp="$(mktemp "$CONFIG_FILE.XXXXXX")"

    {
        grep -vE '^VOLUMES=' "$CONFIG_FILE" || true
        [[ -z "$volumes" ]] || echo "VOLUMES=$volumes"
    } > "$tmp"

    chmod 600 "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

# --- Setting up the file system -----------------------------------------------

# The mount tag of the file system /etc/fstab mounts at /mnt/virtual, if any
fstab_tag() {
    awk -v target="$STORAGE_ROOT" '$1 !~ /^#/ && $2 == target { print $1 }' /etc/fstab
}

# Mounts the file system at /mnt/virtual and adds it to /etc/fstab, unless
# it already is
mount_storage() {
    local tag="$1" current other

    current="$(fstab_tag)"
    if [[ -n "$current" ]]; then
        [[ -z "$tag" || "$tag" == "$current" ]] \
            || fail "/etc/fstab already mounts $current at $STORAGE_ROOT; to use another file system, run ./storage.sh detach first"
        if mounted; then
            info "$current is mounted at $STORAGE_ROOT"
            return
        fi
        info "Storage ($current) is in /etc/fstab but not mounted; mounting it"
        mount "$STORAGE_ROOT" || fail "could not mount $current at $STORAGE_ROOT; check in Vultr that the file system is attached to this server"
        return
    fi

    # The empty directory underneath must be made immutable, which can't
    # be done while something is mounted over it
    if mounted; then
        fail "something is mounted at $STORAGE_ROOT but not in /etc/fstab, perhaps by hand. Unmount it (umount $STORAGE_ROOT) and run ./storage.sh setup again."
    fi

    if [[ -z "$tag" ]]; then
        [[ -t 0 ]] || fail "pass the file system's mount tag with --tag"
        read -r -p "The file system's mount tag, shown on its page in Vultr: " tag
    fi

    [[ "$tag" =~ $TAG_PATTERN ]] || fail "'$tag' is not a valid mount tag"

    other="$(awk -v tag="$tag" '$1 !~ /^#/ && $1 == tag { print $2 }' /etc/fstab)"
    [[ -z "$other" ]] || fail "/etc/fstab already mounts $tag at $other"

    mkdir -p "$STORAGE_ROOT"

    # Files here were written to the root disk, perhaps while storage was
    # missing, and mounting over them would hide them
    empty_dir "$STORAGE_ROOT" \
        || fail "$STORAGE_ROOT holds files on the root disk, perhaps written while storage was missing. Move them somewhere else, and run ./storage.sh setup again."

    # Nothing, not even root, can create files in the empty directory while
    # the file system isn't mounted over it, so a missing mount makes a
    # project's containers fail to start instead of writing to the root disk
    if ! lsattr -d "$STORAGE_ROOT" | cut -d ' ' -f 1 | grep -q 'i'; then
        info "Making the empty $STORAGE_ROOT on the root disk immutable"
        chattr +i "$STORAGE_ROOT" \
            || fail "could not make $STORAGE_ROOT immutable; the root disk's file system must support it, as ext4 and XFS do"
    fi

    info "Mounting $tag at $STORAGE_ROOT"
    mount -t virtiofs "$tag" "$STORAGE_ROOT" \
        || fail "could not mount $tag; check the mount tag in Vultr, and that the file system is attached to this server"

    # nofail: a missing file system doesn't stop the boot or other projects.
    # x-systemd.before: it is mounted before Docker starts any container.
    info "Adding it to /etc/fstab, so it is mounted at every boot"
    {
        echo
        echo "$FSTAB_COMMENT $INSTALL_DIR/storage.sh"
        echo "$tag $STORAGE_ROOT virtiofs defaults,nofail,x-systemd.before=docker.service 0 0"
    } >> /etc/fstab
    systemctl daemon-reload

    [[ "$(fstab_tag)" == "$tag" ]] || fail "/etc/fstab does not list $tag at $STORAGE_ROOT as expected; check the file"
}

write_claim() {
    local tmp
    tmp="$(mktemp "$SERVER_DIR/$CLAIM_FILE.XXXXXX")"
    {
        echo "# This directory holds the files of $SERVER_HOSTNAME's projects. Deploys on"
        echo "# any other machine refuse to use it; see \"Storage\" in wetfish/server's"
        echo "# docs/how-it-works.md."
        echo "MACHINE_ID=$(machine_id)"
        echo "HOSTNAME=$SERVER_HOSTNAME"
        echo "CLAIMED=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$SERVER_DIR/$CLAIM_FILE"
}

# Claims this server's directory on storage, creating it if needed. A
# directory claimed by another machine, or holding files without a claim,
# is only taken over when asked to.
claim_server_dir() {
    local take_over="$1" claim="$SERVER_DIR/$CLAIM_FILE" owner owner_host owner_date

    [[ ! -L "$SERVER_DIR" ]] || fail "$SERVER_DIR is a symbolic link; it must be a directory"

    if [[ ! -e "$SERVER_DIR" ]]; then
        mkdir "$SERVER_DIR" || fail "could not create $SERVER_DIR on the storage mounted at $STORAGE_ROOT; it must be writable by $(id -un)"
        write_claim
        info "Claimed $SERVER_DIR for this server"
        return
    fi

    [[ -d "$SERVER_DIR" ]] || fail "$SERVER_DIR exists but is not a directory"

    if [[ -f "$claim" ]]; then
        owner="$(file_value "$claim" MACHINE_ID)"
        if [[ "$owner" == "$(machine_id)" ]]; then
            info "$SERVER_DIR is claimed by this server"
            return
        fi

        owner_host="$(file_value "$claim" HOSTNAME)"
        owner_date="$(file_value "$claim" CLAIMED)"
        [[ "$take_over" == true ]] \
            || fail "$SERVER_DIR is claimed by another machine (${owner_host:-unknown}, since ${owner_date:-an unknown date}), which may still use it. If it no longer does, such as after moving this hostname to a new server, run: ./storage.sh setup --take-over"
        warn "taking over $SERVER_DIR from another machine (${owner_host:-unknown}); make sure it no longer uses this storage"
    elif ! empty_dir "$SERVER_DIR"; then
        [[ "$take_over" == true ]] \
            || fail "$SERVER_DIR holds files but no claim. If they belong to this server, run: ./storage.sh setup --take-over"
    fi

    write_claim
    info "Claimed $SERVER_DIR for this server"
}

setup() {
    local tag="$1" take_over="$2"

    if on_server; then
        mount_storage "$tag"
    else
        # A local copy has no Vultr file system; a stand-in mounted by hand
        # gets its directory claimed the same way
        [[ -z "$tag" ]] || fail "--tag is only for servers, which mount the file system themselves"
        mounted || fail "nothing is mounted at $STORAGE_ROOT. On a local copy, mount a stand-in there first; see \"Storage on a Local Copy\" in docs/how-it-works.md."
    fi

    claim_server_dir "$take_over"

    echo
    echo "Storage is set up: this server keeps its projects' files in $SERVER_DIR."
    echo "Keep a project's volume there with: ./storage.sh add <project> <volume>"
}

# --- Adding and removing a project's volume -----------------------------------

# Prints what a Docker volume holds: empty, files, or unreadable, when the
# user running this, such as yourself on a local copy, can't look inside
volume_contents() {
    local path
    path="$(docker volume inspect --format '{{.Mountpoint}}' "$1" 2> /dev/null)" || { echo unreadable; return; }

    if [[ ! -r "$path" || ! -x "$path" ]]; then
        echo unreadable
    elif empty_dir "$path"; then
        echo empty
    else
        echo files
    fi
}

# Prints the names of the containers, running or not, that mount a Docker
# volume, separated by spaces
volume_users() {
    docker ps --all --filter "volume=$1" --format '{{.Names}}' | xargs
}

add() {
    local users

    load_project "$1" "$2"

    require_storage
    ! listed || fail "$NAME already keeps $VOLUME on storage"

    info "Keeping $NAME's $VOLUME volume on storage, in $DIR"
    write_volumes "$VOLUMES $VOLUME"

    if ! "$INSTALL_DIR/apply.sh"; then
        write_volumes "$VOLUMES"
        fail "$VOLUME was not added"
    fi

    echo
    if ! "$INSTALL_DIR/deploy.sh" "$NAME"; then
        echo >&2
        echo "config/$NAME.conf now keeps $VOLUME on storage, so deploys of $NAME refuse" >&2
        echo "until the problem above is fixed. To undo: ./storage.sh remove $NAME $VOLUME" >&2
        exit 1
    fi

    # The deploy only switched to storage because the project's own volume
    # was empty or missing. It is no longer used, so an empty one is removed;
    # files that reached it while the containers were replaced are kept.
    if docker volume inspect "$PLAIN_VOLUME" > /dev/null 2>&1; then
        users="$(volume_users "$PLAIN_VOLUME")"
        if [[ -n "$users" ]]; then
            warn "$users still use $PLAIN_VOLUME rather than storage. Run ./deploy.sh $NAME, and once nothing uses it, copy any files it holds into $DIR, then: docker volume rm $PLAIN_VOLUME"
            exit 1
        fi

        case "$(volume_contents "$PLAIN_VOLUME")" in
            empty) docker volume rm "$PLAIN_VOLUME" > /dev/null || true ;;
            files) warn "files reached $PLAIN_VOLUME while $NAME switched to storage. Copy them into $DIR, then: docker volume rm $PLAIN_VOLUME" ;;
            *) warn "$PLAIN_VOLUME is no longer used, but $(id -un) can't read it to check whether it is empty. Check with sudo ls -A \"\$(docker volume inspect --format '{{.Mountpoint}}' $PLAIN_VOLUME)\", copy any files into $DIR, then: docker volume rm $PLAIN_VOLUME" ;;
        esac
    fi

    echo
    echo "$NAME keeps its $VOLUME volume in $DIR. Make it writable by the user"
    echo "$NAME's containers run as, if it isn't already; see \"Storage\" in"
    echo "docs/how-it-works.md."
}

# Prints how to move a volume's files from storage back to the root disk
print_move_back() {
    cat << EOF >&2

$DIR holds files, so $VOLUME was left on storage. To keep the
files, move them into a volume on the root disk first, as root, while $NAME
is stopped (its site shows the unavailable page):

  docker compose --project-name $NAME down
  docker volume create --label com.docker.compose.project=$NAME --label com.docker.compose.volume=$VOLUME $PLAIN_VOLUME
  cp -a $DIR/. "\$(docker volume inspect --format '{{.Mountpoint}}' $PLAIN_VOLUME)/"

Once the copy is checked, empty the directory, and run this again:

  find $DIR -mindepth 1 -delete
  ./storage.sh remove $NAME $VOLUME

Meanwhile deploys of $NAME refuse, so it stays stopped until the last step.
EOF
}

remove() {
    local remaining="" volume users

    load_project "$1" "$2"

    listed || fail "$NAME doesn't keep $VOLUME on storage (VOLUMES in config/$NAME.conf)"
    mounted || fail "nothing is mounted at $STORAGE_ROOT, so whether $DIR is empty can't be checked; mount it first"
    claimed || fail "$SERVER_DIR is not claimed by this server, so its files may not be this server's; run ./storage.sh setup"

    if [[ -d "$DIR" ]] && ! empty_dir "$DIR"; then
        print_move_back
        exit 1
    fi

    for volume in $VOLUMES; do
        [[ "$volume" == "$VOLUME" ]] || remaining+=" $volume"
    done

    info "Keeping $NAME's $VOLUME volume on the root disk again"
    write_volumes "$remaining"

    if ! "$INSTALL_DIR/apply.sh"; then
        write_volumes "$VOLUMES"
        fail "$VOLUME was not removed"
    fi

    echo
    if ! "$INSTALL_DIR/deploy.sh" "$NAME"; then
        echo >&2
        echo "config/$NAME.conf no longer keeps $VOLUME on storage. Once ./deploy.sh $NAME" >&2
        echo "succeeds, check that $DIR is still empty, then remove it" >&2
        echo "and the volume that bound it: rmdir $DIR; docker volume rm $STORAGE_VOLUME" >&2
        exit 1
    fi

    # A container still using the storage volume would keep writing to the
    # directory, so neither is removed while one does, even if it is empty
    users="$(volume_users "$STORAGE_VOLUME")"
    if [[ -n "$users" ]]; then
        warn "$users still use $STORAGE_VOLUME, so $DIR and the volume were kept. Run ./deploy.sh $NAME, and once nothing uses the volume, copy any files in $DIR into $PLAIN_VOLUME, then: rmdir $DIR; docker volume rm $STORAGE_VOLUME"
        exit 1
    fi

    # rmdir only removes an empty directory, so files that reached it while
    # the containers were replaced are kept, along with the volume
    if [[ -d "$DIR" ]] && ! rmdir "$DIR" 2> /dev/null; then
        warn "files reached $DIR while $NAME switched back to the root disk. Copy them into $PLAIN_VOLUME, then remove the directory and: docker volume rm $STORAGE_VOLUME"
        exit 1
    fi

    if docker volume inspect "$STORAGE_VOLUME" > /dev/null 2>&1; then
        docker volume rm "$STORAGE_VOLUME" > /dev/null || warn "could not remove the Docker volume $STORAGE_VOLUME; it is no longer used"
    fi
    rmdir "$SERVER_DIR/$NAME" 2> /dev/null || true

    echo
    echo "$NAME keeps its $VOLUME volume on the root disk again, in $PLAIN_VOLUME."
}

# --- Detaching the file system ------------------------------------------------

# Gives up this server's directory on storage, if nothing but the claim is
# left in it; otherwise keeps the claim, so the files stay this server's
release_claim() {
    claimed || return 0

    if [[ -z "$(find "$SERVER_DIR" -mindepth 1 ! -name "$CLAIM_FILE" -print -quit)" ]]; then
        rm -f "$SERVER_DIR/$CLAIM_FILE"
        rmdir "$SERVER_DIR"
        info "Gave up $SERVER_DIR"
    else
        warn "$SERVER_DIR still holds files, so it stays claimed by this server on the file system. They are not deleted."
    fi
}

detach() {
    local confirmed="$1" current conf projects=() volumes reply tmp

    on_server || fail "./storage.sh detach runs as root on a server. On a local copy, unmount the stand-in yourself."

    current="$(fstab_tag)"
    [[ -n "$current" ]] || mounted || fail "storage is not set up on this server"

    # Projects still keeping volumes on storage would refuse to deploy, and
    # their containers would lose their files
    for conf in "$INSTALL_DIR"/config/*.conf; do
        [[ -f "$conf" ]] || continue
        if [[ -n "$(file_value "$conf" VOLUMES)" ]]; then
            projects+=("$(basename "$conf" .conf)")
        fi
    done
    [[ ${#projects[@]} -eq 0 ]] \
        || fail "these projects still keep volumes on storage: ${projects[*]}. Remove each first with ./storage.sh remove <project> <volume>, moving their files as it explains."

    # Left behind by removed projects, and still binding directories there
    volumes="$(docker volume ls --quiet --filter label=org.wetfish.server.volume | xargs)"
    [[ -z "$volumes" ]] \
        || fail "the Docker volumes $volumes still bind directories on storage, such as from removed projects. Copy any files you need out of them, then remove them with docker volume rm, and run this again."

    if ! $confirmed; then
        [[ -t 0 ]] || fail "pass --yes to detach storage without a terminal to confirm on"
        read -r -p "Unmount ${current:-the storage} from $STORAGE_ROOT and remove it from /etc/fstab? [y/N]: " reply
        [[ "$reply" =~ ^[Yy] ]] || fail "storage was not detached"
    fi

    if mounted; then
        release_claim
        info "Unmounting $STORAGE_ROOT"
        umount "$STORAGE_ROOT" || fail "could not unmount $STORAGE_ROOT; check what uses it with: fuser -vm $STORAGE_ROOT"
    fi

    if [[ -n "$current" ]]; then
        info "Removing it from /etc/fstab, keeping the previous file as /etc/fstab.before-storage-detach"
        cp -p /etc/fstab /etc/fstab.before-storage-detach
        tmp="$(mktemp)"
        awk -v target="$STORAGE_ROOT" -v comment="$FSTAB_COMMENT" \
            'index($0, comment) == 1 { next } $1 !~ /^#/ && $2 == target { next } { print }' \
            /etc/fstab > "$tmp"
        # Written in place, keeping the file's owner and permissions
        cat "$tmp" > /etc/fstab
        rm -f "$tmp"
        systemctl daemon-reload
    fi

    chattr -i "$STORAGE_ROOT" 2> /dev/null || true
    rmdir "$STORAGE_ROOT" 2> /dev/null || warn "$STORAGE_ROOT is not empty, so it was kept"

    echo
    echo "Storage is detached from this server. The file system and anything left on"
    echo "it are unchanged; detach it from this server in Vultr if nothing else needs it."
}

# --- Main ---------------------------------------------------------------------

main() {
    local tag="" take_over=false confirmed=false

    [[ $# -ge 1 ]] || usage
    check_system

    # One change to storage at a time
    mkdir -p "$GENERATED_DIR"
    exec 9> "$GENERATED_DIR/storage.lock"
    flock 9

    case "$1" in
        setup)
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --tag)
                        [[ $# -ge 2 ]] || usage
                        tag="$2"
                        shift 2
                        ;;
                    --tag=*)
                        tag="${1#*=}"
                        shift
                        ;;
                    --take-over)
                        take_over=true
                        shift
                        ;;
                    *) usage ;;
                esac
            done
            setup "$tag" "$take_over"
            ;;
        add)
            [[ $# -eq 3 ]] || usage
            add "$2" "$3"
            ;;
        remove)
            [[ $# -eq 3 ]] || usage
            remove "$2" "$3"
            ;;
        detach)
            [[ $# -le 2 ]] || usage
            case "${2:-}" in
                "") ;;
                -y | --yes) confirmed=true ;;
                *) usage ;;
            esac
            detach "$confirmed"
            ;;
        *) usage ;;
    esac
}

main "$@"
exit
