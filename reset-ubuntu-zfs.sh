#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/partition.sh
source "$SCRIPT_DIR/lib/partition.sh"

trap on_error ERR

main() {
    init_defaults
    parse_args "$@"
    validate_runtime_flags
    install_traps

    validate_inputs
    confirm_destructive_action

    run_phase "teardown-installer-state" phase_teardown_installer_state
    run_phase "wipe-disk" phase_wipe_disk
    run_phase "finalize-reset" phase_finalize_reset

    print_completion_summary
}

init_defaults() {
    DISK=""
    TARGET_MNT="/mnt"
    ROOT_POOL_NAME="rpool"
    BOOT_POOL_NAME="bpool"
    LUKS_NAME="cryptroot"
    ENCRYPTION_MODE="luks"
    DRY_RUN=0
    VERBOSE=0
    FORCE=0
    START_PHASE=""
    LOG_FILE="$SCRIPT_DIR/reset.log"
}

usage() {
    cat <<'EOF'
Usage:
  ./reset-ubuntu-zfs.sh --disk /dev/disk/by-id/... [options]
  ./reset-ubuntu-zfs.sh /dev/disk/by-id/... [options]

Required options:
  --disk PATH                Target disk path under /dev/disk/by-id

Optional options:
  --target-mnt PATH          Target mountpoint used by installer (default: /mnt)
  --root-pool-name NAME      Root pool name to export (default: rpool)
  --boot-pool-name NAME      Boot pool name to export (default: bpool)
  --luks-name NAME           LUKS mapper name to close (default: cryptroot)
  --dry-run                  Print commands without executing them
  --verbose                  Enable shell tracing during command execution
  --start-phase NAME         Resume from a named phase
  --force                    Skip interactive destructive confirmation
  --help                     Show this message

Phases:
  teardown-installer-state
  wipe-disk
  finalize-reset
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk)
                require_option_value "$1" "${2-}"
                DISK=$2
                shift 2
                ;;
            --target-mnt)
                require_option_value "$1" "${2-}"
                TARGET_MNT=$2
                shift 2
                ;;
            --root-pool-name)
                require_option_value "$1" "${2-}"
                ROOT_POOL_NAME=$2
                shift 2
                ;;
            --boot-pool-name)
                require_option_value "$1" "${2-}"
                BOOT_POOL_NAME=$2
                shift 2
                ;;
            --luks-name)
                require_option_value "$1" "${2-}"
                LUKS_NAME=$2
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --start-phase)
                require_option_value "$1" "${2-}"
                START_PHASE=$2
                shift 2
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                if [[ -z "$DISK" && "$1" != --* ]]; then
                    DISK=$1
                    shift
                    continue
                fi
                die "Unknown argument: $1"
                ;;
        esac
    done
}

validate_runtime_flags() {
    require_bool "$DRY_RUN" "dry-run"
    require_bool "$VERBOSE" "verbose"
    require_bool "$FORCE" "force"
}

validate_inputs() {
    require_nonempty "$DISK" "disk"
    require_nonempty "$TARGET_MNT" "target-mnt"
    require_disk_by_id "$DISK"
    require_absolute_path "$TARGET_MNT" "target-mnt"
    require_zpool_name "$ROOT_POOL_NAME" "root-pool-name"
    require_zpool_name "$BOOT_POOL_NAME" "boot-pool-name"
    require_mapper_name "$LUKS_NAME" "luks-name"
    require_phase "$START_PHASE" \
        teardown-installer-state \
        wipe-disk \
        finalize-reset

    [[ "$TARGET_MNT" != "/" ]] || die "Refusing to use / as target mountpoint"

    if (( ! DRY_RUN )); then
        require_root
        require_command wipefs
        require_command sgdisk
        require_command partprobe
        require_command udevadm
        require_command lsblk
        require_command findmnt
        ensure_disk_exists "$DISK"
    fi
}

confirm_destructive_action() {
    local summary
    summary=$(
        cat <<EOF
This will irreversibly reset installer state and destroy data on:
  disk: $DISK
  target-mnt: $TARGET_MNT
  root-pool-name: $ROOT_POOL_NAME
  boot-pool-name: $BOOT_POOL_NAME
  luks-name: $LUKS_NAME
EOF
    )

    if (( DRY_RUN )); then
        log_info "Skipping destructive confirmation because --dry-run was used"
        return
    fi

    if (( FORCE )); then
        log_warn "Skipping confirmation because --force was used"
        return
    fi

    printf '%s\n' "$summary"
    read -r -p "Type 'destroy $DISK' to continue: " response
    [[ "$response" == "destroy $DISK" ]] || die "Confirmation failed"
}

unmount_mounts_backed_by_disk() {
    local node mountpoint
    local -a mountpoints=()

    if (( DRY_RUN )); then
        log_info "Would unmount filesystems backed by $DISK"
        return
    fi

    while IFS= read -r node; do
        while IFS= read -r mountpoint; do
            [[ -n "$mountpoint" ]] || continue
            mountpoints+=("$mountpoint")
        done < <(findmnt -rn -S "$node" -o TARGET || true)
    done < <(lsblk -nrpo NAME "$DISK" || true)

    if (( ${#mountpoints[@]} == 0 )); then
        return
    fi

    while IFS= read -r mountpoint; do
        run_cmd umount -lf "$mountpoint" || true
    done < <(printf '%s\n' "${mountpoints[@]}" | sort -ru)
}

phase_teardown_installer_state() {
    log_info "Tearing down swap, mounts, pools, and crypto mappings"

    run_cmd swapoff --all || true
    cleanup_mounts
    unmount_mounts_backed_by_disk

    if command -v zpool >/dev/null 2>&1; then
        run_cmd zpool export -f "$ROOT_POOL_NAME" || true
        run_cmd zpool export -f "$BOOT_POOL_NAME" || true
    fi

    if command -v cryptsetup >/dev/null 2>&1; then
        if [[ -e /dev/mapper/swap ]]; then
            run_cmd cryptsetup close swap || true
        fi

        if [[ -e "/dev/mapper/$LUKS_NAME" ]]; then
            # Deferred close avoids repeated busy retries when dm users are still draining.
            run_cmd cryptsetup close --deferred "$LUKS_NAME" || true
        fi
    fi

    if command -v dmsetup >/dev/null 2>&1; then
        if [[ -e /dev/mapper/swap ]]; then
            run_cmd dmsetup remove --force swap || true
        fi

        if [[ -e "/dev/mapper/$LUKS_NAME" ]]; then
            run_cmd dmsetup remove --force "$LUKS_NAME" || true
        fi
    fi

    unmount_mounts_backed_by_disk
}

phase_wipe_disk() {
    wipe_existing_storage "$DISK"
    refresh_partition_table "$DISK"
}

phase_finalize_reset() {
    local cache_backup
    local -a disk_nodes

    log_info "Clearing transient local ZFS cache"
    if [[ -e /etc/zfs/zpool.cache ]]; then
        cache_backup="/etc/zfs/zpool.cache.$(date +%Y%m%d%H%M%S).bak"
        run_cmd cp -a /etc/zfs/zpool.cache "$cache_backup"
        run_cmd rm -f /etc/zfs/zpool.cache
        log_info "Backed up ZFS cache to $cache_backup"
    else
        log_info "No local ZFS cache found at /etc/zfs/zpool.cache"
    fi

    if (( DRY_RUN )); then
        log_info "Would verify post-reset state"
        return
    fi

    log_info "Post-reset verification"
    mapfile -t disk_nodes < <(lsblk -nrpo NAME "$DISK")
    if (( ${#disk_nodes[@]} > 1 )); then
        log_warn "Partitions still visible on $DISK (kernel may need additional settle time)"
    else
        log_info "No child partitions detected for $DISK"
    fi

    if command -v zpool >/dev/null 2>&1; then
        if zpool list -H "$ROOT_POOL_NAME" >/dev/null 2>&1; then
            log_warn "Pool still present: $ROOT_POOL_NAME"
        fi
        if zpool list -H "$BOOT_POOL_NAME" >/dev/null 2>&1; then
            log_warn "Pool still present: $BOOT_POOL_NAME"
        fi
    fi

    if [[ -e "/dev/mapper/$LUKS_NAME" ]]; then
        log_warn "Mapper still present: /dev/mapper/$LUKS_NAME"
    fi

    if [[ -e /dev/mapper/swap ]]; then
        log_warn "Mapper still present: /dev/mapper/swap"
    fi
}

print_completion_summary() {
    cat <<EOF

Reset complete.

Disk wiped: $DISK
Target mountpoint: $TARGET_MNT
Root pool (export attempted): $ROOT_POOL_NAME
Boot pool (export attempted): $BOOT_POOL_NAME
LUKS mapper (close attempted): $LUKS_NAME

Review $LOG_FILE before re-running the installer.
EOF
}

main "$@"
