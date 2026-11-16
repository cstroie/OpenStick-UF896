Prebuilt Alpine Linux for the **UF896** MSM8916 4G USB stick (`UF896_V1.1`),
built by GitHub Actions from this tag.

> [!WARNING]
> Read the [README](https://github.com/cstroie/OpenStick-UF896#readme) first.
> Back up the **whole eMMC** before writing anything. The modem calibration
> partitions (`modemst1`, `modemst2`, `fsg`, `persist`) are unique to each
> stick and cannot be replaced.

## Files

| File | Partition | Notes |
| --- | --- | --- |
| `aboot.mbn` | `aboot` | lk2nd with the UF896 DTB: boots Alpine; hold the button while plugging in for fastboot |
| `aboot-fastboot.mbn` | `aboot` | same, but always stops in fastboot (`fastboot continue` boots); handy for a first install |
| `hyp.mbn` | `hyp` | qhypstub, test-signed |
| `sbl1.mbn`, `rpm.mbn`, `tz.mbn` | `sbl1`, `rpm`, `tz` | 64-bit Qualcomm firmware from the DragonBoard 410c release (see `LICENSE.qcom.txt`) |
| `boot.img.xz`, `rootfs.img.xz` | `boot`, `rootfs` | raw images for `edl`; decompress with `unxz` first |
| `boot-sparse.img`, `rootfs-sparse.img` | `boot`, `rootfs` | Android sparse images for `fastboot flash` |
| `uf896_gpt.py` | GPT | builds the partition table from **your own** stock GPT |
| `SHA256SUMS` | | `sha256sum -c SHA256SUMS` |

There is no prebuilt partition table: the stock layout grows `tz` to 1 MiB
and adds `rootfs`, and the table has to be derived from your stick's own GPT.

## Install via EDL

`L` stands for `--loader=prog_emmc_firehose_8916.mbn --memory=emmc`.

```shell
sha256sum -c SHA256SUMS
edl rf full_emmc.bin $L                       # full backup, keep it safe

edl rs 0 34 stock_gpt.bin $L
python3 uf896_gpt.py stock_gpt.bin gpt.bin    # prints the backup GPT LBA
dd if=gpt.bin of=gpt-primary.bin bs=512 count=34
dd if=gpt.bin of=gpt-backup.bin  bs=512 skip=34 count=33
edl ws 0       gpt-primary.bin $L
edl ws 7569375 gpt-backup.bin  $L             # LBA printed above

for p in sbl1 rpm tz hyp aboot; do edl w $p $p.mbn $L; done
unxz -k boot.img.xz rootfs.img.xz
edl w boot   boot.img   $L
edl w rootfs rootfs.img $L
edl reset $L
```

Write all four firmware files (`sbl1`, `rpm`, `tz`, `hyp`) together: the
stock 32-bit TrustZone cannot start the 64-bit kernel. If the stick does not
come back, see the [recovery guide](https://github.com/cstroie/OpenStick-UF896/blob/main/docs/RECOVERY.md).

## After the first boot

- USB network: stick at `192.168.5.1`, SSH as `user`, password `1`. Change it
  and set a root password right away.
- Wi-Fi hotspot `Openstick` / `openstick` until you add a client network.
