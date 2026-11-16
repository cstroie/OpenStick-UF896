#!/usr/bin/env python3
"""Convert a stock UF896 (Android 4.4) GPT into the OpenStick UF896 layout.

Input : the stock GPT, i.e. at least the first 34 sectors of the eMMC
        (e.g. `edl rs 0 34 stock_gpt.bin`) or a full eMMC dump.
Output: a "gpt_both" image: 34 sectors (protective MBR, primary header,
        128 entries) followed by 33 sectors (128 entries, backup header).
        Write the first 34 sectors to LBA 0 and the last 33 to LBA
        <last_lba - 32> (both printed by this script), e.g. with edl ws.

Changes from stock (all other partitions keep their stock position):
  * tz grows from 512 KiB to 1 MiB (the 64-bit TZ.BF.3.0 tz.mbn is
    ~591 KiB); this absorbs the old tzbak area
  * tzbak moves into the unused gap after splash
  * boot grows from 16 MiB to 64 MiB and gets a fixed PARTUUID
  * boot and rootfs lose the stock read-only attribute
  * system (entry 23) becomes rootfs: 1536 MiB right after persist,
    Linux filesystem type and the fixed PARTUUID used by extlinux.conf
  * cache, recovery and userdata are dropped
  * the entry array is widened to 128 entries
"""
import argparse
import struct
import sys
import uuid
import zlib

SECTOR = 512
ENTRY_SIZE = 128
NUM_ENTRIES = 128
ENTRY_SECTORS = NUM_ENTRIES * ENTRY_SIZE // SECTOR  # 32

BOOT_PARTUUID = uuid.UUID('8e1d98a7-e738-4ff8-8052-f41c21c84f00')
ROOTFS_PARTUUID = uuid.UUID('a7ab80e8-e9d1-e8cd-f157-93f69b1d141e')
LINUX_FS_TYPE = uuid.UUID('0fc63daf-8483-4772-8e79-3d69d8477de4')

# name: (first_lba, last_lba) for the partitions that change
LAYOUT = {
    'tz':     (270336, 272383),    # 1 MiB
    'tzbak':  (306176, 307199),    # 512 KiB, in the gap after splash
    'boot':   (396384, 527455),    # 64 MiB
    'rootfs': (2133088, 5278815),  # 1536 MiB, after persist
}
DROP = {'cache', 'recovery', 'userdata'}
# stock entries expected at these 1-based indexes (sanity check)
EXPECT = {2: 'sbl1', 4: 'aboot', 8: 'tz', 9: 'tzbak', 13: 'modemst1',
          14: 'modemst2', 20: 'fsg', 22: 'boot', 23: 'system', 24: 'persist'}


def die(msg):
    sys.exit('error: ' + msg)


def entry_name(e):
    return e[56:128].decode('utf-16le').rstrip('\0')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('stock', help='stock GPT dump (>= 34 sectors) or full eMMC image')
    ap.add_argument('output', help='output gpt_both image (67 sectors)')
    args = ap.parse_args()

    with open(args.stock, 'rb') as f:
        data = f.read(34 * SECTOR)
    if len(data) < 34 * SECTOR:
        die('input is shorter than 34 sectors')
    mbr, hdr = data[:SECTOR], bytearray(data[SECTOR:2 * SECTOR])
    if hdr[:8] != b'EFI PART':
        die('no GPT header at LBA 1')

    hdr_size, = struct.unpack_from('<I', hdr, 12)
    my_lba, alt_lba, first_lba, last_lba = struct.unpack_from('<QQQQ', hdr, 24)
    pe_lba, n_ent, ent_size = struct.unpack_from('<QII', hdr, 72)
    if my_lba != 1 or pe_lba != 2 or ent_size != ENTRY_SIZE:
        die('unexpected GPT header (my_lba=%d pe_lba=%d entry_size=%d)'
            % (my_lba, pe_lba, ent_size))
    if first_lba < 2 + ENTRY_SECTORS:
        die('first usable LBA %d leaves no room for 128 entries' % first_lba)

    stock = data[pe_lba * SECTOR:pe_lba * SECTOR + n_ent * ENTRY_SIZE]
    stock = [stock[i * ENTRY_SIZE:(i + 1) * ENTRY_SIZE] for i in range(n_ent)]
    for idx, name in EXPECT.items():
        if idx > len(stock) or entry_name(stock[idx - 1]) != name:
            die('entry %d is not "%s" - this does not look like a stock UF896 GPT'
                % (idx, name))

    out = []
    for e in stock:
        if e[:16] == b'\0' * 16:
            continue
        name = entry_name(e)
        if name in DROP:
            continue
        e = bytearray(e)
        if name == 'system':
            e[0:16] = LINUX_FS_TYPE.bytes_le
            e[16:32] = ROOTFS_PARTUUID.bytes_le
            e[56:128] = 'rootfs'.encode('utf-16le').ljust(72, b'\0')
            name = 'rootfs'
        if name == 'boot':
            e[16:32] = BOOT_PARTUUID.bytes_le
        if name in ('boot', 'rootfs'):
            e[48:56] = bytes(8)  # clear stock attributes (bit 60: read-only)
        if name in LAYOUT:
            struct.pack_into('<QQ', e, 32, *LAYOUT[name])
        out.append(bytes(e))

    # overlap / bounds check
    ranges = sorted((struct.unpack_from('<QQ', e, 32), entry_name(e)) for e in out)
    for (a, an), (b, bn) in zip(ranges, ranges[1:]):
        if a[1] >= b[0]:
            die('%s overlaps %s' % (an, bn))
    if ranges[0][0][0] < first_lba or ranges[-1][0][1] > last_lba:
        die('partition outside the usable area')

    entries = b''.join(out).ljust(NUM_ENTRIES * ENTRY_SIZE, b'\0')
    ecrc = zlib.crc32(entries) & 0xffffffff

    def header(mine, alt, pe):
        h = bytearray(hdr[:hdr_size])
        struct.pack_into('<QQ', h, 24, mine, alt)
        struct.pack_into('<QII', h, 72, pe, NUM_ENTRIES, ENTRY_SIZE)
        struct.pack_into('<I', h, 88, ecrc)
        struct.pack_into('<I', h, 16, 0)
        struct.pack_into('<I', h, 16, zlib.crc32(h) & 0xffffffff)
        return bytes(h).ljust(SECTOR, b'\0')

    backup_pe = alt_lba - ENTRY_SECTORS
    image = (mbr + header(1, alt_lba, 2) + entries
             + entries + header(alt_lba, 1, backup_pe))
    with open(args.output, 'wb') as f:
        f.write(image)

    for (s, e), n in ranges:
        print('  %-9s %8d..%-8d %8d KiB' % (n, s, e, (e - s + 1) * SECTOR // 1024))
    print('wrote %s: write sectors 0-33 to LBA 0, sectors 34-66 to LBA %d'
          % (args.output, backup_pe))


if __name__ == '__main__':
    main()
