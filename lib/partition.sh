#!/usr/bin/env bash

wipe_existing_storage() {
    local disk=$1

    log_info "Wiping existing partitioning and signatures on $disk"
    run_cmd swapoff --all || true
    run_cmd wipefs -a "$disk"
    run_cmd sgdisk --zap-all "$disk"
}

create_gpt_layout() {
    local disk=$1
    local esp_size=$2
    local swap_size=$3
    local boot_pool_size=$4
    local swap_enabled=$5
    local boot_part root_part

    if [[ "$swap_enabled" == "1" ]]; then
        boot_part=3
        root_part=4
    else
        boot_part=2
        root_part=3
    fi

    log_info "Creating GPT partition layout"
    run_cmd sgdisk -n1:1M:+"$esp_size" -t1:EF00 "$disk"
    if [[ "$swap_enabled" == "1" ]]; then
        run_cmd sgdisk -n2:0:+"$swap_size" -t2:8200 "$disk"
    else
        log_info "Skipping swap partition because --swap-size=0"
    fi
    run_cmd sgdisk -n"$boot_part":0:+"$boot_pool_size" -t"$boot_part":BE00 "$disk"

    if [[ "$ENCRYPTION_MODE" == "luks" ]]; then
        run_cmd sgdisk -n"$root_part":0:0 -t"$root_part":8309 "$disk"
    else
        run_cmd sgdisk -n"$root_part":0:0 -t"$root_part":BF00 "$disk"
    fi
}

refresh_partition_table() {
    local disk=$1
    run_cmd partprobe "$disk"
    if (( DRY_RUN )); then
        return
    fi
    run_cmd udevadm settle
}
