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

    log_info "Creating GPT partition layout"
    run_cmd sgdisk -n1:1M:+"$esp_size" -t1:EF00 "$disk"
    run_cmd sgdisk -n2:0:+"$swap_size" -t2:8200 "$disk"
    run_cmd sgdisk -n3:0:+"$boot_pool_size" -t3:BE00 "$disk"

    if [[ "$ENCRYPTION_MODE" == "luks" ]]; then
        run_cmd sgdisk -n4:0:0 -t4:8309 "$disk"
    else
        run_cmd sgdisk -n4:0:0 -t4:BF00 "$disk"
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