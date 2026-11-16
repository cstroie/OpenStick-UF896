#!/bin/sh -e

make -C src/qhypstub CROSS_COMPILE=aarch64-linux-gnu-

# Reduce MMC speed for boards with unreliable flash initialization.
if ! grep -qxF 'DEFINES += USE_TARGET_HS200_CAPS=1' \
    src/lk2nd/project/lk1st-msm8916.mk; then
    echo 'DEFINES += USE_TARGET_HS200_CAPS=1' \
        >> src/lk2nd/project/lk1st-msm8916.mk
fi

# Apply UF896 patches to lk2nd (skipped when already applied).
for p in patches/lk2nd/*.patch; do
    if git -C src/lk2nd apply --reverse --check "../../$p" 2>/dev/null; then
        echo "already applied: $p"
    else
        git -C src/lk2nd apply "../../$p"
    fi
done

# Build lk2nd for UF896. Set LK2ND_FORCE_FASTBOOT=1 in the environment for
# a bootloader that always stops in fastboot (safe for first installs).
make -C src/lk2nd \
    LK2ND_BUNDLE_DTB="msm8916-512mb-qrd-skuh.dtb" \
    LK2ND_COMPATIBLE="thwc,uf896" \
    LK2ND_FORCE_FASTBOOT="${LK2ND_FORCE_FASTBOOT:-0}" \
    TOOLCHAIN_PREFIX=arm-none-eabi- \
    lk1st-msm8916

# Test sign.
mkdir -p files

src/qtestsign/qtestsign.py hyp \
    src/qhypstub/qhypstub.elf \
    -o files/hyp.mbn

src/qtestsign/qtestsign.py aboot \
    src/lk2nd/build-lk1st-msm8916/emmc_appsboot.mbn \
    -o files/aboot.mbn

# Never flash an aboot without the UF896 board definition: without it the
# reset key is not wired up and a failed boot leaves no way back to fastboot.
grep -q 'thwc,uf896' files/aboot.mbn || {
    echo "ERROR: files/aboot.mbn lacks the thwc,uf896 DTB - do not flash it" >&2
    exit 1
}

