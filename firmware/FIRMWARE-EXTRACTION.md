# Extracting the AIC8800D40 firmware from your own Android dump

The blob in the [Release asset](../README.md#firmware) works for the Vontar H618 / X98H. If you
have a different board, or you prefer not to use a vendor binary you didn't extract yourself, get
the firmware from **your device's own Android eMMC image** — it's the firmware the manufacturer
validated for exactly your silicon.

## 1. Get the Android eMMC dump
Dump the box's eMMC while it still runs Android (or from a backup). On the box:
```bash
# boot Android, then (root):
dd if=/dev/mmcblk0 of=/path/on/nfs/or/usb/mmcblk0.img bs=8M
# or the common tools: `armbian-config`, TWRP backup, USB-burning-tool "export"
```
You need the full eMMC image (`mmcblk0.img`).

## 2. Find the `super` partition
Android A/B stores system/vendor/etc. inside a `super` partition:
```bash
sgdisk -p mmcblk0.img | grep -i super
# note the Start sector (e.g. 599040)
```
Extract it:
```bash
SUPER_START=599040   # use your value
dd if=mmcblk0.img of=super.img bs=512 skip=$SUPER_START count=6291456   # size from sgdisk
```

## 3. Locate `vendor_a` inside `super`
`super` is an Android "logical partition" (LP) image. The simplest way:
```bash
pip install --user --break-system-packages liblp   # has the LP parser (note: the `lpunpack` CLI
                                                   #  isn't shipped; use the lib, or android-tools
                                                   #  `lpunpack` from your distro)
```
If you have distro `lpunpack`:
```bash
mkdir out && lpunpack super.img out/
# out/vendor_a.img   (ext4)
```
Manual fallback (what was used to build this package) — parse the LP metadata by hand:
- LP metadata header magic `0x414c5030` is at offset `4096*3` (`0x3000`) of `super.img`.
- The partition table follows the header (`header_size` after the header magic); entries are
  ~104 bytes, name at offset 0. `system_a` / `vendor_a` / `product_a` are listed there.
- Each partition entry's extents are in the extent table; the first extent of `vendor_a` gives
  its offset (in 512-byte sectors × 512) and size within `super`. For the Vontar X98H it lands at
  ~1.39 GiB into `super`, ext4 (superblock magic `0x53EF` at partition+0x438).
- `dd` that region out as `vendor_a.img`.

## 4. Pull the firmware out of `vendor_a` (ext4, no root needed)
`debugfs` reads ext4 images without mounting:
```bash
debugfs -R "ls /etc/firmware/aic8800d80" vendor_a.img
# dump the whole set:
for f in fmacfw_8800d80_u02.bin fw_adid_8800d80_u02.bin fw_patch_8800d80_u02.bin \
         fw_patch_table_8800d80_u02.bin lmacfw_rf_8800d80_u02.bin aic_userconfig_8800d80.txt; do
  debugfs -R "dump /etc/firmware/aic8800d80/$f ./$f" vendor_a.img
done
```
(Some builds keep them flat under `/etc/firmware/` — check both.)

## 5. Verify
```bash
sha256sum fmacfw_8800d80_u02.bin
# compare to firmware/SHA256SUMS — for the Vontar X98H it matches the Release asset.
# For a different board you'll get a different hash; that's fine — it's the firmware YOUR
# manufacturer shipped, matched to YOUR silicon.
```

## Which files matter
The loader needs the **whole set** from one vendor build (don't mix):
`fmacfw_8800d80_u02.bin` (the one that must boot), `fw_adid_8800d80_u02.bin`,
`fw_patch_8800d80_u02.bin`, `fw_patch_table_8800d80_u02.bin`, `lmacfw_rf_8800d80_u02.bin`,
`aic_userconfig_8800d80.txt`. (The `fmacfw.bin` base file is also present in the dump but is not
used by the D80 procedure on this chip.)
