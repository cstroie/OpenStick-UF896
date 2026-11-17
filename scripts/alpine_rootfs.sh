#!/bin/sh -e

export CHROOT=${CHROOT=$(pwd)/rootfs}
export HOST_NAME=${HOST_NAME=openstick}
export RELEASE=${RELEASE=v3.24}
export PMOS_RELEASE=${PMOS_RELEASE=v25.12}
export MIRROR=${MIRROR=http://dl-cdn.alpinelinux.org/alpine}
export PMOS_MIRROR=${PMOS_MIRROR=http://mirror.postmarketos.org/postmarketos}
export APK_STATIC_URL=https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.6/x86_64/apk.static
# Filesystem UUIDs used in /etc/fstab. busybox mount cannot resolve
# PARTUUID=, so fstab uses UUID=; build_images.sh creates the filesystems
# with these UUIDs. OPT_FSUUID adds an /opt line (format the partition made
# by uf896_gpt.py --opt with: mkfs.ext4 -L opt -U $OPT_FSUUID ...).
export ROOT_FSUUID=${ROOT_FSUUID=fcb221c5-4c0c-437e-a5d2-e2cd756ee1fc}
export BOOT_FSUUID=${BOOT_FSUUID=782dc120-6ede-4dd7-b538-a8cdd98ae480}
export OPT_FSUUID=${OPT_FSUUID=}
# BOARD selects the kernel DTB: uf896 (default) or uz801 (UZ801 v3)
export BOARD=${BOARD=uf896}
export USER_NAME=${USER_NAME=user}
case "${BOARD}" in
uf896) DTB=msm8916-thwc-uf896 ;;
uz801) DTB=msm8916-yiming-uz801v3 ;;
*) echo "ERROR: unknown BOARD=${BOARD}" >&2; exit 1 ;;
esac

rm -rf ${CHROOT}

mkdir -p ${CHROOT}/etc/apk
cat << EOF >  ${CHROOT}/etc/apk/repositories
${MIRROR}/${RELEASE}/main
${MIRROR}/${RELEASE}/community
@pmos ${PMOS_MIRROR}/${PMOS_RELEASE}
EOF

cp /etc/resolv.conf ${CHROOT}/etc/

mkdir -p ${CHROOT}/usr/bin
cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

[ -e apk.static ] || wget ${APK_STATIC_URL}; chmod a+x apk.static

./apk.static add -p ${CHROOT} --initdb -U --arch aarch64 --allow-untrusted alpine-base

# install apps
chroot ${CHROOT} ash -l -c "
apk add --allow-untrusted postmarketos-keys@pmos
apk add \
    bridge-utils \
    dropbear \
    dbus \
    eudev \
    gadget-tool \
    iptables \
    linux-postmarketos-qcom-msm8916@pmos \
    modemmanager \
    msm-firmware-loader@pmos \
    openrc \
    rmtfs \
    shadow \
    sudo \
    udev-init-scripts \
    udev-init-scripts-openrc \
    wireguard-tools \
    wireguard-tools-wg-quick \
    wireless-regdb \
    iw

# clear
rm /etc/fstab
"

# extract NetworkManager from previous alpine version (v3.20)
scripts/extract_networkmanager.sh

# setup alpine
chroot ${CHROOT} ash -l -c "
echo ${USER_NAME}:1::::/home/${USER_NAME}:/bin/ash | newusers

# update users used by chrooted apps
addgroup -S dnsmasq
adduser -S -D -H -h /dev/null -s /sbin/nologin -G dnsmasq -g dnsmasq dnsmasq

# sync
ln /etc/group    /usr/local/etc
ln /etc/passwd   /usr/local/etc
ln /etc/hostname /usr/local/etc

ln -sf /usr/local/etc/resolv.conf /etc

# add symlinks
for a in nm-online nmcli nmtui nmtui-connect nmtui-edit nmtui-hostname; do
    ln -s /usr/local/bin/chroot.sh /usr/bin/\${a};
done

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add udev-postmount default
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown
rc-update add dropbear default
rc-update add rmtfs default
rc-update add modemmanager default
rc-update add networkmanager default
rc-update add networkmanager-dispatcher default
rc-update add wpa_supplicant default
rc-update add syslog boot
rc-update add klogd boot
rc-update add ntpd default
rc-update add local default
"
echo "${USER_NAME} ALL=(ALL:ALL) NOPASSWD: ALL" > ${CHROOT}/etc/sudoers.d/${USER_NAME}

# add udev rules
cat << EOF > ${CHROOT}/etc/udev/rules.d/10-udc.rules
ACTION=="add", SUBSYSTEM=="udc", RUN+="/sbin/modprobe libcomposite", RUN+="/usr/local/bin/setup_ncm_gadget.sh"
EOF

cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# enable autologin on console
sed -i '/^tty/ s/^/#/' ${CHROOT}/etc/inittab
echo 'ttyMSM0::respawn:/bin/sh' >> ${CHROOT}/etc/inittab
# login on the USB serial gadget; ttyGS0 only exists once the gadget is up,
# so wait between attempts instead of respawning in a tight loop
echo 'ttyGS0::respawn:/bin/sh -c "sleep 2; exec /sbin/getty -L 115200 ttyGS0 vt100"' >> ${CHROOT}/etc/inittab

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/usr/local/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/usr/local/etc/NetworkManager/system-connections/*
ln -s ../usr/local/etc/NetworkManager ${CHROOT}/etc/NetworkManager

mkdir -p ${CHROOT}/boot/extlinux
sed "s|msm8916-thwc-uf896|${DTB}|" configs/extlinux.conf > ${CHROOT}/boot/extlinux/extlinux.conf

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# restore ownership/modes recorded in the apk database: apk running under
# qemu inside the chroot drops setuid/setgid bits (sudo, passwd, unix_chkpwd...)
awk '
/^F:/ { dir = substr($0, 3); file = ""; next }
/^M:/ { split(substr($0, 3), a, ":"); print a[1], a[2], a[3], "/" dir; next }
/^R:/ { file = (dir == "" ? "" : dir "/") substr($0, 3); next }
/^a:/ { if (file != "") { split(substr($0, 3), a, ":"); print a[1], a[2], a[3], "/" file }; next }
/^$/  { dir = ""; file = "" }
' ${CHROOT}/lib/apk/db/installed | while read -r uid gid mode path; do
    p="${CHROOT}${path}"
    [ -e "$p" ] && [ ! -L "$p" ] || continue
    chown "$uid:$gid" "$p"
    chmod "$mode" "$p"
done

# update fstab (the NetworkManager chroot binds are already in it)
{
    printf 'UUID=%s\t/\text4\tdefaults,noatime\t0 1\n' "${ROOT_FSUUID}"
    printf 'UUID=%s\t/boot\text2\tdefaults,noatime\t0 2\n' "${BOOT_FSUUID}"
    [ -z "${OPT_FSUUID}" ] ||
        printf 'UUID=%s\t/opt\text4\tdefaults,noatime\t0 2\n' "${OPT_FSUUID}"
    echo
    echo '# frequently written directories in RAM'
    echo 'tmpfs\t/tmp\ttmpfs\tnosuid,nodev,mode=1777,size=64M\t0 0'
    echo 'tmpfs\t/var/tmp\ttmpfs\tnosuid,nodev,mode=1777,size=16M\t0 0'
    echo 'tmpfs\t/var/log\ttmpfs\tnosuid,nodev,noexec,mode=0755,size=16M\t0 0'
} >> ${CHROOT}/etc/fstab

# syslog to a 256 KiB RAM ring buffer only (read with logread)
sed -i 's/^SYSLOGD_OPTS=.*/SYSLOGD_OPTS="-t -C256"/' ${CHROOT}/etc/conf.d/syslog

# LEDs: heartbeat on red, USB/Wi-Fi traffic on green/blue (run by 'local')
install -m 0755 configs/leds.start ${CHROOT}/etc/local.d/leds.start
echo ledtrig-netdev >> ${CHROOT}/etc/modules

# copy gadget-tool templates and script
cp -a configs/templates ${CHROOT}/etc/gt
cp scripts/setup_ncm_gadget.sh ${CHROOT}/usr/local/bin

# backup rootfs
rm -f alpine_rootfs.tgz
tar cpzf alpine_rootfs.tgz \
    --exclude="root/*" \
    --exclude="newroot" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -C rootfs .
