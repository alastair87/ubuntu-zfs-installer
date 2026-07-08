#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/partition.sh
source "$SCRIPT_DIR/lib/partition.sh"
# shellcheck source=lib/pools.sh
source "$SCRIPT_DIR/lib/pools.sh"
# shellcheck source=lib/chroot.sh
source "$SCRIPT_DIR/lib/chroot.sh"

trap on_error ERR

main() {
    init_defaults
    parse_config_arg "$@"
    load_config_file_if_present
    parse_args "$@"
    validate_runtime_flags
    finalize_config
    install_traps

    log_info "Starting install for Ubuntu $UBUNTU_CODENAME on $DISK"
    validate_environment
    validate_inputs
    confirm_destructive_action

    run_phase "prepare-live-environment" phase_prepare_live_environment
    run_phase "partition-disk" phase_partition_disk
    run_phase "create-pools" phase_create_pools
    run_phase "create-datasets" phase_create_datasets
    run_phase "bootstrap-system" phase_bootstrap_system
    run_phase "configure-target-system" phase_configure_target_system
    run_phase "finalize-install" phase_finalize_install

    print_completion_summary
}

init_defaults() {
    DISK=""
    HOSTNAME_VALUE=""
    USERNAME_VALUE=""
    USER_PASSWORD_HASH=""
    UBUNTU_CODENAME="resolute"
    ENCRYPTION_MODE="none"
    SWAP_SIZE="2G"
    BOOT_POOL_SIZE="2G"
    ROOT_POOL_NAME="rpool"
    BOOT_POOL_NAME="bpool"
    ESP_SIZE="512M"
    EFI_MOUNTPOINT="/boot/efi"
    TARGET_MNT="/mnt"
    LUKS_NAME="cryptroot"
    LUKS_CIPHER="aes-xts-plain64"
    LUKS_KEY_SIZE="512"
    LUKS_HASH="sha256"
    LUKS_TYPE="luks2"
    DRY_RUN=0
    VERBOSE=0
    ENABLE_SSH=0
    ENABLE_TMPFS_TMP=1
    ENABLE_DESKTOP=0
    CONFIG_FILE=""
    FORCE=0
    START_PHASE=""
    LOG_FILE="$SCRIPT_DIR/install.log"
    LIVE_PACKAGES=(debootstrap gdisk zfsutils-linux dosfstools)
    TARGET_BASE_PACKAGES=(
        locales
        tzdata
        keyboard-configuration
        console-setup
        sudo
        zfs-initramfs
        linux-image-generic
        grub-efi-amd64
        grub-efi-amd64-signed
        shim-signed
        dosfstools
    )
}

usage() {
    cat <<'EOF'
Usage:
  ./install-ubuntu-zfs.sh --disk /dev/disk/by-id/... --hostname HOST --username USER [options]

Required options:
  --disk PATH                Target disk path under /dev/disk/by-id
  --hostname NAME            Hostname for the installed system
  --username NAME            Initial non-root user to create

Optional options:
  --user-password-hash HASH  Encrypted password hash for the initial user; prompts if omitted
  --ubuntu-codename NAME     Ubuntu release codename for debootstrap (default: resolute)
  --encryption MODE          none or luks (default: none)
  --swap-size SIZE           Swap partition size, e.g. 2G, 8G (default: 2G)
  --boot-pool-size SIZE      Boot pool partition size (default: 2G)
  --esp-size SIZE            EFI system partition size (default: 512M)
  --root-pool-name NAME      Root pool name (default: rpool)
  --boot-pool-name NAME      Boot pool name (default: bpool)
  --luks-name NAME           Device mapper name for LUKS (default: cryptroot)
  --enable-ssh               Install openssh-server in target system
  --enable-desktop           Install ubuntu-desktop in target system
  --disable-tmpfs-tmp        Do not enable tmp.mount for /tmp
  --dry-run                  Print commands without executing them
  --verbose                  Enable shell tracing during command execution
  --config FILE              Load environment-style config file; CLI flags override it
  --start-phase NAME         Resume from a named phase
  --force                    Skip interactive destructive confirmation
  --help                     Show this message

Phases:
  prepare-live-environment
  partition-disk
  create-pools
  create-datasets
  bootstrap-system
  configure-target-system
  finalize-install
EOF
}

parse_config_arg() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                require_option_value "$1" "${2-}"
                CONFIG_FILE=$2
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            --)
                break
                ;;
            *)
                shift
                ;;
        esac
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk)
                require_option_value "$1" "${2-}"
                DISK=$2
                shift 2
                ;;
            --hostname)
                require_option_value "$1" "${2-}"
                HOSTNAME_VALUE=$2
                shift 2
                ;;
            --username)
                require_option_value "$1" "${2-}"
                USERNAME_VALUE=$2
                shift 2
                ;;
            --user-password-hash)
                require_option_value "$1" "${2-}"
                USER_PASSWORD_HASH=$2
                shift 2
                ;;
            --ubuntu-codename)
                require_option_value "$1" "${2-}"
                UBUNTU_CODENAME=$2
                shift 2
                ;;
            --encryption)
                require_option_value "$1" "${2-}"
                ENCRYPTION_MODE=$2
                shift 2
                ;;
            --swap-size)
                require_option_value "$1" "${2-}"
                SWAP_SIZE=$2
                shift 2
                ;;
            --boot-pool-size)
                require_option_value "$1" "${2-}"
                BOOT_POOL_SIZE=$2
                shift 2
                ;;
            --esp-size)
                require_option_value "$1" "${2-}"
                ESP_SIZE=$2
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
            --enable-ssh)
                ENABLE_SSH=1
                shift
                ;;
            --enable-desktop)
                ENABLE_DESKTOP=1
                shift
                ;;
            --disable-tmpfs-tmp)
                ENABLE_TMPFS_TMP=0
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --config)
                require_option_value "$1" "${2-}"
                CONFIG_FILE=$2
                shift 2
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
                die "Unknown argument: $1"
                ;;
        esac
    done
}

load_config_file_if_present() {
    if [[ -n "$CONFIG_FILE" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            die "Config file not found: $CONFIG_FILE"
        fi
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

finalize_config() {
    PART_EFI="${DISK}-part1"
    PART_SWAP="${DISK}-part2"
    PART_BPOOL="${DISK}-part3"
    PART_RPOOL="${DISK}-part4"
    TARGET_OS_PACKAGES=("${TARGET_BASE_PACKAGES[@]}")

    if [[ "$ENCRYPTION_MODE" == "luks" ]]; then
        TARGET_OS_PACKAGES+=(cryptsetup)
        LIVE_PACKAGES+=(cryptsetup)
    fi

    if [[ "$ENABLE_SSH" == "1" ]]; then
        TARGET_OS_PACKAGES+=(openssh-server)
    fi

    if [[ "$ENABLE_DESKTOP" == "1" ]]; then
        TARGET_OS_PACKAGES+=(ubuntu-desktop)
    else
        TARGET_OS_PACKAGES+=(ubuntu-standard)
    fi
}

validate_runtime_flags() {
    require_bool "$DRY_RUN" "dry-run"
    require_bool "$VERBOSE" "verbose"
    require_bool "$ENABLE_SSH" "enable-ssh"
    require_bool "$ENABLE_DESKTOP" "enable-desktop"
    require_bool "$ENABLE_TMPFS_TMP" "enable-tmpfs-tmp"
    require_bool "$FORCE" "force"
}

validate_environment() {
    if (( DRY_RUN )); then
        return
    fi

    require_root
    require_command apt
    require_command findmnt
    require_command lsblk
    require_uefi
    require_network
}

validate_inputs() {
    require_nonempty "$DISK" "disk"
    require_nonempty "$HOSTNAME_VALUE" "hostname"
    require_nonempty "$USERNAME_VALUE" "username"
    require_disk_by_id "$DISK"
    require_hostname "$HOSTNAME_VALUE"
    require_username "$USERNAME_VALUE"
    require_password_hash "$USER_PASSWORD_HASH"
    require_codename "$UBUNTU_CODENAME"
    require_zpool_name "$ROOT_POOL_NAME" "root-pool-name"
    require_zpool_name "$BOOT_POOL_NAME" "boot-pool-name"
    require_mapper_name "$LUKS_NAME" "luks-name"
    require_absolute_path "$TARGET_MNT" "target-mnt"
    require_absolute_path "$EFI_MOUNTPOINT" "efi-mountpoint"
    require_size_string "$SWAP_SIZE" "swap-size"
    require_size_string "$BOOT_POOL_SIZE" "boot-pool-size"
    require_size_string "$ESP_SIZE" "esp-size"
    validate_runtime_flags
    require_phase "$START_PHASE" \
        prepare-live-environment \
        partition-disk \
        create-pools \
        create-datasets \
        bootstrap-system \
        configure-target-system \
        finalize-install

    case "$ENCRYPTION_MODE" in
        none|luks)
            ;;
        *)
            die "Unsupported encryption mode: $ENCRYPTION_MODE"
            ;;
    esac

    if [[ "$BOOT_POOL_NAME" != "bpool" ]]; then
        die "Boot pool name must remain bpool for GRUB compatibility in this installer"
    fi

    if (( ! DRY_RUN )); then
        ensure_disk_exists "$DISK"
        ensure_disk_not_mounted "$DISK"
        if [[ -z "$START_PHASE" ]]; then
            ensure_directory_empty_or_absent "$TARGET_MNT"
        else
            log_warn "Skipping empty mountpoint check because resume mode is enabled"
        fi
    fi
}

confirm_destructive_action() {
    local summary
    summary=$(
        cat <<EOF
This will irreversibly destroy data on:
  disk: $DISK
  encryption: $ENCRYPTION_MODE
  swap-size: $SWAP_SIZE
  boot-pool-size: $BOOT_POOL_SIZE
  hostname: $HOSTNAME_VALUE
  username: $USERNAME_VALUE
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

phase_prepare_live_environment() {
    log_info "Installing live environment dependencies"
    run_cmd apt update
    run_cmd apt install --yes "${LIVE_PACKAGES[@]}"
    run_cmd systemctl stop zed || true
    run_cmd mkdir -p "$TARGET_MNT"
}

phase_partition_disk() {
    wipe_existing_storage "$DISK"
    create_gpt_layout "$DISK" "$ESP_SIZE" "$SWAP_SIZE" "$BOOT_POOL_SIZE"
    refresh_partition_table "$DISK"
}

phase_create_pools() {
    create_boot_pool
    create_root_pool
}

phase_create_datasets() {
    create_dataset_layout
}

phase_bootstrap_system() {
    bootstrap_target_system
}

phase_configure_target_system() {
    configure_target_system
}

phase_finalize_install() {
    finalize_target_system
}

print_completion_summary() {
    cat <<EOF

Install staging complete.

Target mountpoint: $TARGET_MNT
Disk: $DISK
Root pool: $ROOT_POOL_NAME
Boot pool: $BOOT_POOL_NAME
Encryption: $ENCRYPTION_MODE

If all commands succeeded, review $LOG_FILE before rebooting.
EOF
}

main "$@"
