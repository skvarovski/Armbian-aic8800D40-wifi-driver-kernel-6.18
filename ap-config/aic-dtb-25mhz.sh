#!/bin/bash
# aic-dtb-25mhz.sh — patch the device tree: mmc WiFi node max-frequency 150 MHz → 25 MHz.
#
# ROOT CAUSE of `sunxi-mmc ... data error, sending stop command` on these boards
# (proven on a clean Armbian/ophub install, 2026-07):
#
#   The ophub Vontar-H618 device tree ships mmc1 (the WiFi SDIO slot) with
#   max-frequency = 150 MHz (0x8f0d180). The AIC8800 driver requests 150 MHz
#   (FEATURE_SDIO_CLOCK_V3), the controller accepts and raises the bus to
#   50 MHz (SD high-speed) — which this board's SDIO routing cannot hold.
#   Large firmware transfers corrupt → "data error" → the chip never finishes
#   booting → no wlan0.
#
#   Lowering the DTB max-frequency to 25 MHz caps the bus at 25 MHz (the value a
#   known-good image uses). 25 MHz is slow but rock-solid; the 1T1R SDIO PHY
#   ceiling (~70-90 Mbps) is unaffected. ONLY mmc1 (WiFi) is touched; mmc0 (SD
#   card) and mmc2 are left at 150 MHz.
#
#   Note: the driver's FEATURE_SDIO_CLOCK_V3=150000000 is a REQUEST — the actual
#   bus clock is min(DTB max-frequency, request). So "150 MHz in the driver" is
#   fine and harmless; the DTB is the real lever.
#
# Run ON THE BOX as root. Needs `dtc` (apt install device-tree-compiler).
# Reboot afterwards. Original DTB is kept as ${DTB}.orig.
set -eu

DTB="${DTB:-/boot/dtb/allwinner/sun50i-h618-vontar-h618.dtb}"
[ -f "$DTB" ] || { echo "DTB not found: $DTB (set DTB=/path/to/your.dtb if different)"; exit 1; }
command -v dtc >/dev/null || { echo "dtc required: apt-get install -y device-tree-compiler"; exit 1; }

echo "=== backup original ==="
if [ ! -f "${DTB}.orig" ]; then cp -a "$DTB" "${DTB}.orig"; echo "  saved ${DTB}.orig"; else echo "  ${DTB}.orig already exists"; fi

echo "=== current mmc max-frequency (before) ==="
dtc -I dtb -O dts "$DTB" 2>/dev/null | awk '/mmc@402[012]000/{name=$0}/max-frequency/{print name,$0}' | sed 's/[ \t]*{/ {/' | head

echo "=== decompile → change max-frequency ONLY in mmc@4021000 (WiFi) → recompile ==="
dtc -I dtb -O dts "$DTB" > /tmp/aic-dtb.dts 2>/dev/null
# 0x8f0d180 = 150000000 (150 MHz) → 0x17d7840 = 25000000 (25 MHz), only inside the mmc1 block
awk '
  /[ \t]*mmc@4021000[ \t]*\{/ { in_mmc1=1 }
  /^[ \t]*mmc@402[02]000[ \t]*\{/ { in_mmc1=0 }
  in_mmc1 && /max-frequency[ \t]*=/ { sub(/0x[0-9a-fA-F]+/, "0x17d7840") }
  { print }
' /tmp/aic-dtb.dts > /tmp/aic-dtb.new.dts
dtc -I dts -O dtb /tmp/aic-dtb.new.dts > /tmp/aic-dtb.new.dtb 2>/tmp/dtc.err || { echo "recompile failed:"; cat /tmp/dtc.err; exit 1; }

echo "=== validate new DTB ==="
mmc0=$(dtc -I dtb -O dts /tmp/aic-dtb.new.dtb 2>/dev/null | awk '/mmc@4020000/{f=1}/mmc@4021000/{f=0}f&&/max-frequency/')
mmc1=$(dtc -I dtb -O dts /tmp/aic-dtb.new.dtb 2>/dev/null | awk '/mmc@4021000/{f=1}/mmc@4022000/{f=0}f&&/max-frequency/')
mmc2=$(dtc -I dtb -O dts /tmp/aic-dtb.new.dtb 2>/dev/null | awk '/mmc@4022000/{f=1}f&&/max-frequency/' | head -1)
echo "  mmc0 (SD card): $mmc0   (must stay 0x8f0d180)"
echo "  mmc1 (WiFi):    $mmc1   (must be 0x17d7840 = 25 MHz)"
echo "  mmc2:           $mmc2   (must stay 0x8f0d180)"

echo "$mmc1" | grep -q 0x17d7840 || { echo "ABORT: mmc1 not 25 MHz, DTB NOT applied"; exit 1; }
echo "$mmc0" | grep -q 0x8f0d180 || { echo "ABORT: mmc0 was changed — refusing"; exit 1; }

echo "=== apply ==="
cp /tmp/aic-dtb.new.dtb "$DTB"
echo "✓ DTB patched: mmc1 WiFi → 25 MHz. Reboot to apply: systemctl reboot"
echo "  Rollback: cp ${DTB}.orig $DTB"
echo "  After reboot verify: cat /sys/kernel/debug/mmc1/ios | grep ^clock  → 25000000 Hz"
