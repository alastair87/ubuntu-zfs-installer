#!/usr/bin/env bash

configure_target_system() {
    log_info "Writing base target configuration"

    write_target_file "etc/hostname" "$HOSTNAME_VALUE\n"
    write_target_file "etc/hosts" "127.0.0.1 localhost\n127.0.1.1 $HOSTNAME_VALUE\n"
    write_target_file "etc/apt/sources.list" "deb http://archive.ubuntu.com/ubuntu $UBUNTU_CODENAME main restricted universe multiverse\ndeb http://archive.ubuntu.com/ubuntu $UBUNTU_CODENAME-updates main restricted universe multiverse\ndeb http://archive.ubuntu.com/ubuntu $UBUNTU_CODENAME-backports main restricted universe multiverse\ndeb http://security.ubuntu.com/ubuntu $UBUNTU_CODENAME-security main restricted universe multiverse\n"

    run_cmd mount --make-private --rbind /dev "$TARGET_MNT/dev"
    run_cmd mount --make-private --rbind /proc "$TARGET_MNT/proc"
    run_cmd mount --make-private --rbind /sys "$TARGET_MNT/sys"

    write_fstab
    maybe_write_crypttab

    run_in_chroot_cmd apt update
    run_in_chroot_cmd apt install --yes "${TARGET_OS_PACKAGES[@]}"
    run_in_chroot_cmd locale-gen en_US.UTF-8
    run_in_chroot_cmd update-locale LANG=en_US.UTF-8
    run_in_chroot_cmd ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
    run_in_chroot_cmd dpkg-reconfigure -f noninteractive tzdata
    run_in_chroot_cmd mkdosfs -F 32 -s 1 -n EFI "$PART_EFI"
    run_in_chroot_cmd mkdir -p "$EFI_MOUNTPOINT" /boot/grub
    run_in_chroot_cmd mount "$EFI_MOUNTPOINT"
    run_in_chroot_cmd mkdir -p "$EFI_MOUNTPOINT/grub"
    run_in_chroot_cmd mount --bind "$EFI_MOUNTPOINT/grub" /boot/grub
    run_in_chroot_cmd grub-probe /boot
    populate_zfs_list_cache
    run_in_chroot_cmd update-initramfs -c -k all
    configure_grub_defaults
    run_in_chroot_cmd update-grub
    run_in_chroot_cmd grub-install --target=x86_64-efi "--efi-directory=$EFI_MOUNTPOINT" --bootloader-id=ubuntu --recheck

    create_initial_user
    maybe_enable_tmpfs_tmp
}

configure_grub_defaults() {
    run_in_chroot "if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"init_on_alloc=0\"/' /etc/default/grub; else echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"init_on_alloc=0\"' >> /etc/default/grub; fi"
    run_in_chroot "if grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then sed -i 's/^GRUB_TIMEOUT_STYLE=.*/#GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub; fi"
    run_in_chroot "if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub; else echo 'GRUB_TIMEOUT=5' >> /etc/default/grub; fi"
    run_in_chroot "if grep -q '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub; then sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*/GRUB_RECORDFAIL_TIMEOUT=5/' /etc/default/grub; else echo 'GRUB_RECORDFAIL_TIMEOUT=5' >> /etc/default/grub; fi"
    run_in_chroot "if grep -q '^GRUB_TERMINAL=' /etc/default/grub; then sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL=console/' /etc/default/grub; else echo 'GRUB_TERMINAL=console' >> /etc/default/grub; fi"
}

write_fstab() {
    write_target_file "etc/fstab" \
        "$PART_EFI $EFI_MOUNTPOINT vfat defaults 0 0\n/boot/efi/grub /boot/grub none defaults,bind 0 0\n"

    if [[ "$SWAP_ENABLED" == "0" ]]; then
        return
    fi

    if [[ "$ENCRYPTION_MODE" == "none" ]]; then
        append_target_file "etc/fstab" "$PART_SWAP none swap discard 0 0\n"
    else
        append_target_file "etc/fstab" "/dev/mapper/swap none swap defaults 0 0\n"
    fi
}

maybe_write_crypttab() {
    if [[ "$ENCRYPTION_MODE" == "luks" && "$SWAP_ENABLED" == "1" ]]; then
        write_target_file "etc/crypttab" "${LUKS_NAME} ${PART_RPOOL} none luks,discard,initramfs\nswap ${PART_SWAP} /dev/urandom swap,cipher=aes-xts-plain64:sha256,size=512\n"
        return
    fi

    if [[ "$ENCRYPTION_MODE" == "luks" ]]; then
        write_target_file "etc/crypttab" "${LUKS_NAME} ${PART_RPOOL} none luks,discard,initramfs\n"
        return
    fi

    if [[ "$ENCRYPTION_MODE" == "none" ]]; then
        :
    fi
}

create_initial_user() {
    run_in_chroot "addgroup --system lpadmin || true"
    run_in_chroot "addgroup --system sambashare || true"

    if (( DRY_RUN )); then
        run_in_chroot_cmd id -u "$USERNAME_VALUE"
        run_in_chroot_cmd adduser --disabled-password --gecos "" "$USERNAME_VALUE"
    elif run_in_chroot_cmd id -u "$USERNAME_VALUE"; then
        log_info "User already exists in target: $USERNAME_VALUE"
    else
        run_in_chroot_cmd adduser --disabled-password --gecos "" "$USERNAME_VALUE"
    fi

    run_in_chroot_cmd usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo "$USERNAME_VALUE"
    run_in_chroot_cmd chown -R "$USERNAME_VALUE:$USERNAME_VALUE" "/home/$USERNAME_VALUE"
    set_initial_user_password
}

set_initial_user_password() {
    if [[ -n "$USER_PASSWORD_HASH" ]]; then
        run_in_chroot_cmd_redacted "usermod --password [REDACTED] $USERNAME_VALUE" \
            usermod --password "$USER_PASSWORD_HASH" "$USERNAME_VALUE"
        return
    fi

    if (( DRY_RUN )); then
        run_in_chroot_cmd passwd "$USERNAME_VALUE"
        return
    fi

    log_info "Set password for initial user: $USERNAME_VALUE"
    run_in_chroot_cmd passwd "$USERNAME_VALUE"
}

maybe_enable_tmpfs_tmp() {
    if (( ENABLE_TMPFS_TMP )); then
        run_in_chroot "if [[ -f /usr/lib/systemd/system/tmp.mount || -f /lib/systemd/system/tmp.mount ]]; then systemctl enable tmp.mount; elif [[ -f /usr/share/systemd/tmp.mount ]]; then cp /usr/share/systemd/tmp.mount /etc/systemd/system/ && systemctl enable tmp.mount; else echo 'tmp.mount unit not found; skipping /tmp tmpfs enable' >&2; fi"
    fi
}

populate_zfs_list_cache() {
    run_in_chroot_cmd mkdir -p /etc/zfs/zfs-list.cache
    run_in_chroot_cmd touch "/etc/zfs/zfs-list.cache/$BOOT_POOL_NAME" "/etc/zfs/zfs-list.cache/$ROOT_POOL_NAME"
    run_in_chroot "zed -F & sleep 2; pkill -INT zed || true"
    run_in_chroot "sed -Ei 's|$TARGET_MNT/?|/|g' /etc/zfs/zfs-list.cache/* || true"
}

finalize_target_system() {
    if [[ "$SWAP_ENABLED" == "0" ]]; then
        log_info "Skipping swap setup because --swap-size=0"
        cleanup_mounts
        return
    fi

    if [[ "$ENCRYPTION_MODE" == "none" ]]; then
        run_cmd mkswap -f "$PART_SWAP"
        run_cmd swapon "$PART_SWAP"
    else
        run_cmd cryptsetup open --type plain --key-file /dev/urandom --cipher aes-xts-plain64 --key-size 512 "$PART_SWAP" swap
        run_cmd mkswap -f /dev/mapper/swap
        run_cmd swapoff /dev/mapper/swap || true
        run_cmd cryptsetup close swap
    fi

    cleanup_mounts
}
