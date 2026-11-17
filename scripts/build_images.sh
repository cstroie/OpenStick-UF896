#!/bin/sh -e
#
# Package alpine_rootfs.tgz into a boot (ext2) and a rootfs (ext4) image.
#
# Uses mke2fs -d, so nothing is mounted. Run as root, or rootless inside a
# user namespace (as scripts/alpine_rootfs.sh does) so file owners are kept.
#
#   OUT          output directory (default: files)
#   ROOTFS_SIZE  rootfs image size (default: 1536M; 2686M fills the UZ801
#                partition made with uf896_gpt.py --rootfs-size max)
#   OVERLAY      optional directory copied over the rootfs, for files that
#                do not belong in the repo (SSH keys, Wi-Fi profiles)

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

OUT=${OUT:-files}
ROOTFS_SIZE=${ROOTFS_SIZE:-1536M}
TGZ=${TGZ:-alpine_rootfs.tgz}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT" "$STAGE/boot" "$STAGE/root"

tar xf "$TGZ" -C "$STAGE/boot" ./boot --exclude='./boot/linux.efi' \
    --strip-components=2
tar xpf "$TGZ" -C "$STAGE/root" \
    --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

if [ -n "$OVERLAY" ]; then
    cp -a "$OVERLAY"/. "$STAGE/root/"
fi

rm -f boot.raw rootfs.raw
mke2fs -q -t ext2 -L boot -d "$STAGE/boot" boot.raw 64M
mke2fs -q -t ext4 -L rootfs -d "$STAGE/root" rootfs.raw "$ROOTFS_SIZE"

# sparse images for fastboot
img2simg rootfs.raw "$OUT/alpine_rootfs.bin"
img2simg boot.raw "$OUT/boot.bin"
ls -l boot.raw rootfs.raw "$OUT/alpine_rootfs.bin" "$OUT/boot.bin"
