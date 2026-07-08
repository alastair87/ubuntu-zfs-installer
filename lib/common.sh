#!/usr/bin/env bash

PHASES_COMPLETED=0
CURRENT_PHASE=""
RESUME_EXECUTION=1

log_info() {
    printf '[INFO] %s\n' "$*" | tee -a "$LOG_FILE"
}

log_warn() {
    printf '[WARN] %s\n' "$*" | tee -a "$LOG_FILE" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$*" | tee -a "$LOG_FILE" >&2
}

die() {
    log_error "$*"
    exit 1
}

on_error() {
    local exit_code=$?
    log_error "Command failed in phase '${CURRENT_PHASE:-unknown}' with exit code $exit_code"
    exit "$exit_code"
}

install_traps() {
    mkdir -p -- "$(dirname -- "$LOG_FILE")"
    : > "$LOG_FILE"
    if (( VERBOSE )); then
        set -x
    fi
}

run_cmd() {
    if (( DRY_RUN )); then
        printf '[DRY-RUN] ' | tee -a "$LOG_FILE"
        printf '%q ' "$@" | tee -a "$LOG_FILE"
        printf '\n' | tee -a "$LOG_FILE"
        return 0
    fi

    printf '[RUN] ' | tee -a "$LOG_FILE"
    printf '%q ' "$@" | tee -a "$LOG_FILE"
    printf '\n' | tee -a "$LOG_FILE"
    "$@" 2>&1 | tee -a "$LOG_FILE"
}

run_cmd_redacted() {
    local display=$1
    shift

    if (( DRY_RUN )); then
        printf '[DRY-RUN] %s\n' "$display" | tee -a "$LOG_FILE"
        return 0
    fi

    printf '[RUN] %s\n' "$display" | tee -a "$LOG_FILE"
    "$@" 2>&1 | tee -a "$LOG_FILE"
}

run_phase() {
    local name=$1
    shift

    if [[ -n "$START_PHASE" && "$RESUME_EXECUTION" -eq 1 ]]; then
        if [[ "$name" != "$START_PHASE" ]]; then
            log_info "Skipping phase $name because --start-phase=$START_PHASE"
            return
        fi
        RESUME_EXECUTION=0
    fi

    CURRENT_PHASE=$name
    PHASES_COMPLETED=$((PHASES_COMPLETED + 1))
    log_info "===== Phase $PHASES_COMPLETED: $name ====="
    "$@"
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This installer must run as root"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_option_value() {
    local option=$1
    local value=${2-}
    [[ -n "$value" && "$value" != --* ]] || die "Missing value for $option"
}

require_bool() {
    local value=$1
    local name=$2
    [[ "$value" == "0" || "$value" == "1" ]] || die "Invalid $name value, expected 0 or 1: $value"
}

require_uefi() {
    [[ -d /sys/firmware/efi/efivars ]] || die "UEFI firmware was not detected"
}

require_network() {
    if (( DRY_RUN )); then
        return
    fi
    run_cmd apt-cache policy >/dev/null
}

require_nonempty() {
    local value=$1
    local name=$2
    [[ -n "$value" ]] || die "Missing required value: $name"
}

require_disk_by_id() {
    local path=$1
    [[ "$path" == /dev/disk/by-id/* ]] || die "Disk must be specified with /dev/disk/by-id/*"
    [[ "$path" =~ ^/dev/disk/by-id/[A-Za-z0-9._:+@=-]+$ ]] || die "Disk path contains unsupported characters: $path"
}

require_size_string() {
    local value=$1
    local name=$2
    [[ "$value" =~ ^[1-9][0-9]*([KMGTP]i?B?|[KMGTP])$ ]] || die "Invalid $name value: $value"
}

require_swap_size() {
    local value=$1
    local name=$2

    if [[ "$value" == "0" ]]; then
        return
    fi

    require_size_string "$value" "$name"
}

ensure_disk_exists() {
    local path=$1
    [[ -b "$path" ]] || die "Disk path is not a block device: $path"
}

ensure_disk_not_mounted() {
    local path=$1
    local node

    while IFS= read -r node; do
        if findmnt --source "$node" >/dev/null 2>&1; then
            die "Disk or child partition is currently mounted: $node"
        fi
    done < <(lsblk -nrpo NAME "$path")
}

ensure_directory_empty_or_absent() {
    local path=$1
    if [[ ! -d "$path" ]]; then
        return
    fi
    if find "$path" -mindepth 1 -maxdepth 1 | read -r _; then
        die "Target mountpoint must be empty before running: $path"
    fi
}

require_hostname() {
    local value=$1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "Invalid hostname: $value"
}

require_username() {
    local value=$1
    [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: $value"
}

require_password_hash() {
    local value=$1
    [[ -z "$value" || "$value" =~ ^[!*\$A-Za-z0-9./+=,-]+$ ]] || die "Invalid user-password-hash value"
}

require_codename() {
    local value=$1
    [[ "$value" =~ ^[a-z][a-z0-9-]*$ ]] || die "Invalid Ubuntu codename: $value"
}

require_zpool_name() {
    local value=$1
    local name=$2
    [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "Invalid $name value: $value"
    case "$value" in
        mirror|raidz|raidz[0-9]|draid|spare|log|cache)
            die "Invalid reserved $name value: $value"
            ;;
    esac
}

require_mapper_name() {
    local value=$1
    local name=$2
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ ]] || die "Invalid $name value: $value"
}

require_absolute_path() {
    local value=$1
    local name=$2
    [[ "$value" =~ ^/[A-Za-z0-9._+/@:-]*$ ]] || die "Invalid $name path: $value"
}

require_phase() {
    local value=$1
    shift
    local phase

    [[ -n "$value" ]] || return 0
    for phase in "$@"; do
        if [[ "$value" == "$phase" ]]; then
            return
        fi
    done

    die "Unknown start phase: $value"
}

write_target_file() {
    local relative_path=$1
    local content=$2
    local target_path="$TARGET_MNT/$relative_path"

    run_cmd mkdir -p -- "$(dirname -- "$target_path")"
    if (( DRY_RUN )); then
        log_info "Would write $target_path"
        return
    fi
    printf '%b' "$content" > "$target_path"
}

append_target_file() {
    local relative_path=$1
    local content=$2
    local target_path="$TARGET_MNT/$relative_path"

    run_cmd mkdir -p -- "$(dirname -- "$target_path")"
    if (( DRY_RUN )); then
        log_info "Would append to $target_path"
        return
    fi
    printf '%b' "$content" >> "$target_path"
}

run_in_chroot() {
    local command=$1
    run_in_chroot_cmd bash -lc "$command"
}

run_in_chroot_cmd() {
    run_cmd chroot "$TARGET_MNT" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        DISK="$DISK" \
        PART_EFI="$PART_EFI" \
        PART_SWAP="$PART_SWAP" \
        PART_BPOOL="$PART_BPOOL" \
        PART_RPOOL="$PART_RPOOL" \
        SWAP_ENABLED="$SWAP_ENABLED" \
        HOSTNAME_VALUE="$HOSTNAME_VALUE" \
        USERNAME_VALUE="$USERNAME_VALUE" \
        UBUNTU_CODENAME="$UBUNTU_CODENAME" \
        ROOT_POOL_NAME="$ROOT_POOL_NAME" \
        BOOT_POOL_NAME="$BOOT_POOL_NAME" \
        ENCRYPTION_MODE="$ENCRYPTION_MODE" \
        LUKS_NAME="$LUKS_NAME" \
        "$@"
}

run_in_chroot_cmd_redacted() {
    local display=$1
    shift

    run_cmd_redacted "chroot $TARGET_MNT $display" \
        chroot "$TARGET_MNT" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        DISK="$DISK" \
        PART_EFI="$PART_EFI" \
        PART_SWAP="$PART_SWAP" \
        PART_BPOOL="$PART_BPOOL" \
        PART_RPOOL="$PART_RPOOL" \
        SWAP_ENABLED="$SWAP_ENABLED" \
        HOSTNAME_VALUE="$HOSTNAME_VALUE" \
        USERNAME_VALUE="$USERNAME_VALUE" \
        UBUNTU_CODENAME="$UBUNTU_CODENAME" \
        ROOT_POOL_NAME="$ROOT_POOL_NAME" \
        BOOT_POOL_NAME="$BOOT_POOL_NAME" \
        ENCRYPTION_MODE="$ENCRYPTION_MODE" \
        LUKS_NAME="$LUKS_NAME" \
        "$@"
}

get_partition_uuid() {
    local partition=$1
    if (( DRY_RUN )); then
        printf 'dryrun-%s\n' "$(basename -- "$partition")"
        return
    fi
    blkid -s UUID -o value "$partition"
}

cleanup_mounts() {
    if (( DRY_RUN )); then
        log_info "Would unmount target tree and export pools"
        return
    fi

    if findmnt -R "$TARGET_MNT" >/dev/null 2>&1; then
        while IFS= read -r mountpoint; do
            umount -lf "$mountpoint" 2>/dev/null || true
        done < <(findmnt -R -n -o TARGET "$TARGET_MNT" | sort -r)
    fi
    zpool export "$ROOT_POOL_NAME" 2>/dev/null || true
    zpool export "$BOOT_POOL_NAME" 2>/dev/null || true
    if [[ "$ENCRYPTION_MODE" == "luks" ]]; then
        cryptsetup close swap 2>/dev/null || true
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    fi
}
