#!/bin/sh -e

make -C src/qhypstub CROSS_COMPILE=aarch64-linux-gnu-

# Reduce MMC speed for boards with unreliable flash initialization.
if ! grep -qxF 'DEFINES += USE_TARGET_HS200_CAPS=1' \
    src/lk2nd/project/lk1st-msm8916.mk; then
    echo 'DEFINES += USE_TARGET_HS200_CAPS=1' \
        >> src/lk2nd/project/lk1st-msm8916.mk
fi

# Build lk2nd for UF896.
make -C src/lk2nd \
    LK2ND_BUNDLE_DTB="msm8916-512mb-qrd-skuh.dtb" \
    LK2ND_COMPATIBLE="thwc,uf896" \
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

