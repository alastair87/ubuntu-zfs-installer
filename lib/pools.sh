#!/usr/bin/env bash

create_boot_pool() {
    log_info "Creating boot pool $BOOT_POOL_NAME"
    run_cmd zpool create \
        -f \
        -o ashift=12 \
        -o autotrim=on \
        -o cachefile=/etc/zfs/zpool.cache \
        -o compatibility=grub2 \
        -o feature@livelist=enabled \
        -o feature@zpool_checkpoint=enabled \
        -O devices=off \
        -O acltype=posixacl \
        -O xattr=sa \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off \
        -O mountpoint=/boot \
        -R "$TARGET_MNT" \
        "$BOOT_POOL_NAME" "$PART_BPOOL"
}

create_root_pool() {
    local root_device
    root_device=$PART_RPOOL

    if [[ "$ENCRYPTION_MODE" == "luks" ]]; then
        log_info "Creating LUKS container on $PART_RPOOL"
        run_cmd cryptsetup luksFormat \
            --batch-mode \
            --verify-passphrase \
            --type "$LUKS_TYPE" \
            --cipher "$LUKS_CIPHER" \
            --key-size "$LUKS_KEY_SIZE" \
            --hash "$LUKS_HASH" \
            "$PART_RPOOL"
        run_cmd cryptsetup luksOpen "$PART_RPOOL" "$LUKS_NAME"
        root_device="/dev/mapper/$LUKS_NAME"
    fi

    log_info "Creating root pool $ROOT_POOL_NAME"
    run_cmd zpool create \
        -f \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl \
        -O xattr=sa \
        -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off \
        -O mountpoint=/ \
        -R "$TARGET_MNT" \
        "$ROOT_POOL_NAME" "$root_device"
}

create_dataset_layout() {
    log_info "Creating ZFS dataset layout"

    run_cmd zfs create -o canmount=off -o mountpoint=none "$ROOT_POOL_NAME/ROOT"
    run_cmd zfs create -o mountpoint=/ "$ROOT_POOL_NAME/ROOT/ubuntu"

    run_cmd zfs create -o canmount=off -o mountpoint=none "$BOOT_POOL_NAME/BOOT"
    run_cmd zfs create -o mountpoint=/boot "$BOOT_POOL_NAME/BOOT/ubuntu"

    run_cmd zfs create -o mountpoint=/root "$ROOT_POOL_NAME/root"
    run_cmd zfs create -o canmount=off -o mountpoint=/home "$ROOT_POOL_NAME/home"
    run_cmd zfs create -o mountpoint=/home/"$USERNAME_VALUE" "$ROOT_POOL_NAME/home/$USERNAME_VALUE"

    run_cmd zfs create -o canmount=off -o mountpoint=/var "$ROOT_POOL_NAME/var"
    run_cmd zfs create -o mountpoint=/var/lib "$ROOT_POOL_NAME/var/lib"
    run_cmd zfs create -o mountpoint=/var/log "$ROOT_POOL_NAME/var/log"
    run_cmd zfs create -o mountpoint=/var/spool "$ROOT_POOL_NAME/var/spool"
    run_cmd zfs create -o mountpoint=/var/cache "$ROOT_POOL_NAME/var/cache"
    run_cmd zfs create -o mountpoint=/var/tmp "$ROOT_POOL_NAME/var/tmp"
    run_cmd chmod 1777 "$TARGET_MNT/var/tmp"

    run_cmd zfs create -o mountpoint=/srv "$ROOT_POOL_NAME/srv"
    run_cmd zfs create -o mountpoint=/usr/local "$ROOT_POOL_NAME/usr-local"

    if (( ENABLE_DESKTOP )); then
        run_cmd zfs create -o mountpoint=/var/lib/AccountsService "$ROOT_POOL_NAME/var/lib-accountsservice"
        run_cmd zfs create -o mountpoint=/var/lib/NetworkManager "$ROOT_POOL_NAME/var/lib-networkmanager"
        run_cmd zfs create -o mountpoint=/var/snap "$ROOT_POOL_NAME/var/snap"
    fi

    run_cmd mkdir -p "$TARGET_MNT/run"
    run_cmd mount -t tmpfs tmpfs "$TARGET_MNT/run"
    run_cmd mkdir -p "$TARGET_MNT/run/lock"
}

bootstrap_target_system() {
    log_info "Bootstrapping Ubuntu $UBUNTU_CODENAME into $TARGET_MNT"
    run_cmd debootstrap "$UBUNTU_CODENAME" "$TARGET_MNT"
    run_cmd mkdir -p "$TARGET_MNT/etc/zfs"
    run_cmd cp /etc/zfs/zpool.cache "$TARGET_MNT/etc/zfs/zpool.cache"
}