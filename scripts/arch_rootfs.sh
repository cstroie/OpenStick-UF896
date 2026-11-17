#!/bin/sh -e
#
# Build Arch Linux ARM boot and rootfs images for an MSM8916 stick
# (default: UZ801 v3).
#
# Userland:  Arch Linux ARM aarch64 (generic tarball, kernel removed)
# Kernel:    postmarketOS linux-postmarketos-qcom-msm8916 (has the board DTBs
#            and the MSM8916 modem/WCNSS drivers); no initramfs
# Firmware:  loaded at runtime from the stick's own modem/persist partitions
#            (pmOS msm-firmware-loader scripts, systemd units from here)
# Modem:     rmtfs + libqrtr built from source (not packaged by Arch ARM)
#
# Output: files/$BOARD/boot.img (ext2) and files/$BOARD/rootfs.img (ext4),
# raw images for `edl w`. The rootfs grows to fill its partition on first
# boot (x-systemd.growfs).
#
# Run as root, or as a normal user with uidmap installed: the script then
# re-runs itself in a user namespace (no real root, nothing mounted on the
# host).

if [ "$(id -u)" != 0 ]; then
    exec unshare --map-root-user --map-auto --mount --pid --fork \
        --kill-child "$0" "$@"
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BOARD=${BOARD:-uz801}
case "$BOARD" in
uz801) DTB=${DTB:-msm8916-yiming-uz801v3} ;;
uf896) DTB=${DTB:-msm8916-thwc-uf896} ;;
*) echo "ERROR: unknown BOARD=$BOARD" >&2; exit 1 ;;
esac

TOP=$(pwd)
CHROOT=${CHROOT:-$TOP/rootfs-arch}
DL=${DL:-$TOP/dl}
OUT=${OUT:-$TOP/files/$BOARD}
HOST_NAME=${HOST_NAME:-openstick}
USER_NAME=${USER_NAME:-user}
USER_PASS=${USER_PASS:-1}
ALARM_URL=${ALARM_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}
PMOS_MIRROR=${PMOS_MIRROR:-http://mirror.postmarketos.org/postmarketos}
PMOS_RELEASE=${PMOS_RELEASE:-v25.12}
QRTR_REPO=${QRTR_REPO:-https://github.com/linux-msm/qrtr}
RMTFS_REPO=${RMTFS_REPO:-https://github.com/linux-msm/rmtfs}
# fixed PARTUUIDs written by scripts/uf896_gpt.py
BOOT_PARTUUID=8e1d98a7-e738-4ff8-8052-f41c21c84f00
ROOT_PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e

PACKAGES="
    dnsmasq
    iw
    libqmi
    modemmanager
    networkmanager
    nftables
    openssh
    sudo
    usbutils
    wireguard-tools
    wireless-regdb
    wpa_supplicant
    zram-generator
"
BUILD_DEPS="gcc git make meson ninja pkgconf"
PACKAGES=$(echo $PACKAGES)  # one line, for the bash -c scripts below

in_chroot() {
    chroot "$CHROOT" /usr/bin/env -i \
        HOME=/root TERM=dumb LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
        /bin/bash -e -c "$1"
}

# --- downloads ---------------------------------------------------------------
mkdir -p "$DL" "$OUT"
TARBALL="$DL/$(basename "$ALARM_URL")"
if [ ! -s "$TARBALL" ]; then
    curl -fL -o "$TARBALL" "$ALARM_URL"
    curl -fL -o "$TARBALL.md5" "$ALARM_URL.md5"
fi
(cd "$DL" && md5sum -c "$(basename "$TARBALL").md5")

PMOS_REPO="$PMOS_MIRROR/$PMOS_RELEASE/aarch64"
curl -fsSL "$PMOS_REPO/APKINDEX.tar.gz" | tar xzO APKINDEX > "$DL/APKINDEX"
apk_version() {
    awk -v p="$1" 'BEGIN { RS = "" } $0 ~ "\nP:" p "\n" {
        for (i = 1; i <= NF; i++) if ($i ~ /^V:/) print substr($i, 3) }' \
        "$DL/APKINDEX"
}
fetch_apk() {
    v=$(apk_version "$1")
    [ -n "$v" ] || { echo "ERROR: $1 not in $PMOS_REPO" >&2; exit 1; }
    f="$DL/$1-$v.apk"
    [ -s "$f" ] || curl -fL -o "$f" "$PMOS_REPO/$1-$v.apk"
    echo "$f"
}
KERNEL_APK=$(fetch_apk linux-postmarketos-qcom-msm8916)
FWLOADER_APK=$(fetch_apk msm-firmware-loader)

# --- base system -------------------------------------------------------------
# RESUME=1 reuses an existing $CHROOT that already has the packages
# installed (skips extracting and the slow pacman step under qemu)
if [ "${RESUME:-0}" != 1 ]; then
    rm -rf "$CHROOT"
    mkdir -p "$CHROOT"
    bsdtar -xpf "$TARBALL" -C "$CHROOT"
fi

# private /dev with only the basic nodes: hooks in the chroot must not see
# (or try to chown) the host's devices
mount -t tmpfs -o mode=0755,nosuid dev "$CHROOT/dev"
for n in null zero full random urandom tty; do
    touch "$CHROOT/dev/$n"
    mount --bind "/dev/$n" "$CHROOT/dev/$n"
done
ln -s /proc/self/fd "$CHROOT/dev/fd"
ln -s /proc/self/fd/0 "$CHROOT/dev/stdin"
ln -s /proc/self/fd/1 "$CHROOT/dev/stdout"
ln -s /proc/self/fd/2 "$CHROOT/dev/stderr"
mkdir "$CHROOT/dev/shm" "$CHROOT/dev/pts"
mount -t proc proc "$CHROOT/proc"
mount -t tmpfs tmpfs "$CHROOT/tmp"
rm -f "$CHROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# pacman under qemu-user in a namespace: no Landlock sandbox, no separate
# download user, and no free-space check (it cannot read the mount table)
sed -i -e 's/^#\?DisableSandbox.*/DisableSandbox/' \
       -e 's/^DownloadUser/#DownloadUser/' \
       -e 's/^CheckSpace/#CheckSpace/' "$CHROOT/etc/pacman.conf"
grep -q '^DisableSandbox' "$CHROOT/etc/pacman.conf" ||
    sed -i '/^\[options\]/a DisableSandbox' "$CHROOT/etc/pacman.conf"

[ "${RESUME:-0}" = 1 ] || in_chroot "
pacman-key --init
pacman-key --populate archlinuxarm
# the generic kernel and the 1 GB linux-firmware are not used
pacman -Rns --noconfirm linux-aarch64 linux-firmware mkinitcpio || true
pacman -Syu --noconfirm --needed $PACKAGES $BUILD_DEPS
"

# --- qrtr + rmtfs ------------------------------------------------------------
[ -x "$CHROOT/usr/bin/rmtfs" ] || in_chroot "
pacman -S --noconfirm --needed $BUILD_DEPS
cd /tmp
git clone --depth 1 $QRTR_REPO qrtr
git clone --depth 1 $RMTFS_REPO rmtfs
cd /tmp/qrtr
meson setup build --prefix=/usr
ninja -C build install
cd /tmp/rmtfs
make
make prefix=/usr install
rm -rf /tmp/qrtr /tmp/rmtfs
pacman -Rns --noconfirm $BUILD_DEPS
pacman -Scc --noconfirm
"
# units from here instead (no EFS write-back, firmware-loader ordering)
rm -f "$CHROOT"/usr/lib/systemd/system/rmtfs.service \
      "$CHROOT"/usr/lib/systemd/system/rmtfs-dir.service

# --- kernel, DTBs, modules ---------------------------------------------------
KTMP=$(mktemp -d)
bsdtar -xf "$KERNEL_APK" -C "$KTMP" 2>/dev/null || true
KVER=$(ls "$KTMP/lib/modules")
[ -n "$KVER" ] && [ -f "$KTMP/boot/vmlinuz" ] && \
    [ -f "$KTMP/boot/dtbs/qcom/$DTB.dtb" ] || {
    echo "ERROR: kernel package lacks vmlinuz, modules or $DTB.dtb" >&2
    exit 1
}
mkdir -p "$CHROOT/boot/dtbs" "$CHROOT/usr/lib/modules"
cp "$KTMP/boot/vmlinuz" "$CHROOT/boot/vmlinuz"
cp -a "$KTMP/boot/dtbs/qcom" "$CHROOT/boot/dtbs/"
cp -a "$KTMP/lib/modules/$KVER" "$CHROOT/usr/lib/modules/"
rm -rf "$KTMP"
in_chroot "depmod -a $KVER"

mkdir -p "$CHROOT/boot/extlinux"
cat > "$CHROOT/boot/extlinux/extlinux.conf" << EOF
linux /vmlinuz
fdt /dtbs/qcom/$DTB.dtb
append earlycon root=PARTUUID=$ROOT_PARTUUID console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EOF

# --- firmware loader (scripts from pmOS, units from here) --------------------
FTMP=$(mktemp -d)
bsdtar -xf "$FWLOADER_APK" -C "$FTMP" 2>/dev/null || true
install -m 0755 "$FTMP/usr/sbin/msm-firmware-loader.sh" \
    "$FTMP/usr/sbin/msm-firmware-loader-unpack.sh" "$CHROOT/usr/bin/"
rm -rf "$FTMP"

U="$CHROOT/etc/systemd/system"
cat > "$U/msm-firmware-loader.service" << 'EOF'
[Unit]
Description=Load firmware from the stick's own modem/persist partitions
DefaultDependencies=no
Before=systemd-udev-trigger.service systemd-modules-load.service sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/mkdir -p /run/msm-firmware-loader
ExecStart=/usr/bin/msm-firmware-loader.sh

[Install]
WantedBy=sysinit.target
EOF

cat > "$U/msm-firmware-loader-unpack.service" << 'EOF'
[Unit]
Description=Unpack compressed modem firmware
After=msm-firmware-loader.service
Before=rmtfs.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/msm-firmware-loader-unpack.sh

[Install]
WantedBy=multi-user.target
EOF

# -r: never write EFS back to the modemst partitions (as on the Alpine image)
cat > "$U/rmtfs.service" << 'EOF'
[Unit]
Description=Qualcomm remote filesystem service
After=msm-firmware-loader-unpack.service systemd-udev-settle.service
Before=ModemManager.service NetworkManager.service

[Service]
ExecStart=/usr/bin/rmtfs -r -P -s
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# --- USB gadget (NCM, 192.168.5.1) -------------------------------------------
install -m 0755 scripts/setup_ncm_gadget.sh "$CHROOT/usr/local/bin/"
cat > "$CHROOT/etc/udev/rules.d/10-udc.rules" << 'EOF'
ACTION=="add", SUBSYSTEM=="udc", RUN+="/usr/bin/modprobe libcomposite", RUN+="/usr/local/bin/setup_ncm_gadget.sh"
EOF
cat > "$CHROOT/etc/udev/rules.d/99-nm-usb0.rules" << 'EOF'
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# --- NetworkManager ----------------------------------------------------------
mkdir -p "$CHROOT/etc/NetworkManager/system-connections"
cp configs/*.nmconnection "$CHROOT/etc/NetworkManager/system-connections/"
chmod 0600 "$CHROOT"/etc/NetworkManager/system-connections/*
# NM writes /etc/resolv.conf itself. It must be a regular file: a missing one
# makes NM's dnsmasq (DHCP for the USB network) refuse to start, and without
# it systemd-tmpfiles recreates the link to the (disabled) resolved stub.
rm -f "$CHROOT/etc/resolv.conf"
: > "$CHROOT/etc/resolv.conf"

# --- system configuration ----------------------------------------------------
echo "$HOST_NAME" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" << EOF
127.0.0.1	localhost $HOST_NAME
::1		localhost $HOST_NAME
EOF
echo 'LANG=C.UTF-8' > "$CHROOT/etc/locale.conf"
ln -sf /usr/share/zoneinfo/UTC "$CHROOT/etc/localtime"

cat > "$CHROOT/etc/fstab" << EOF
PARTUUID=$ROOT_PARTUUID	/	ext4	defaults,noatime,x-systemd.growfs	0 1
PARTUUID=$BOOT_PARTUUID	/boot	ext2	defaults,noatime	0 2
EOF

mkdir -p "$CHROOT/etc/systemd/journald.conf.d"
cat > "$CHROOT/etc/systemd/journald.conf.d/volatile.conf" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF

cat > "$CHROOT/etc/systemd/zram-generator.conf" << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$CHROOT/etc/sudoers.d/$USER_NAME"
chmod 0440 "$CHROOT/etc/sudoers.d/$USER_NAME"

in_chroot "
userdel -r alarm 2>/dev/null || true
id $USER_NAME >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash $USER_NAME
echo '$USER_NAME:$USER_PASS' | chpasswd
passwd -l root

systemctl disable systemd-networkd.service systemd-networkd.socket \
    systemd-resolved.service 2>/dev/null || true
systemctl enable NetworkManager.service ModemManager.service sshd.service \
    systemd-timesyncd.service msm-firmware-loader.service \
    msm-firmware-loader-unpack.service rmtfs.service
"

# --- images ------------------------------------------------------------------
# lazy: host submounts under /sys are locked inside a user namespace
for m in dev proc tmp; do umount -lR "$CHROOT/$m"; done
for m in dev proc tmp; do
    [ -z "$(ls -A "$CHROOT/$m")" ] || { echo "ERROR: $CHROOT/$m not empty" >&2; exit 1; }
done
rm -rf "$CHROOT"/var/cache/pacman/pkg/* "$CHROOT"/root/.cache

rm -f "$OUT/boot.img" "$OUT/rootfs.img"
/sbin/mke2fs -q -t ext2 -L boot -d "$CHROOT/boot" "$OUT/boot.img" 64M

# rootfs without /boot contents; sized to the data plus 25% headroom, it
# grows to the whole partition on first boot
BOOT_STAGE="$CHROOT.boot"
rm -rf "$BOOT_STAGE"
mv "$CHROOT/boot" "$BOOT_STAGE"
mkdir "$CHROOT/boot"
SIZE=$(du -sm "$CHROOT" | cut -f1)
SIZE=$((SIZE * 5 / 4 + 128))
RC=0
/sbin/mke2fs -q -t ext4 -L rootfs -d "$CHROOT" "$OUT/rootfs.img" "${SIZE}M" ||
    RC=$?
rmdir "$CHROOT/boot"
mv "$BOOT_STAGE" "$CHROOT/boot"
[ $RC = 0 ] || exit $RC

ls -l "$OUT/boot.img" "$OUT/rootfs.img"
echo "kernel $KVER, DTB $DTB"
