#!/bin/bash
# Rebuild the AIC8800D40 SDIO driver for your kernel.
# Applies driver/patches/*.patch against upstream LYU4662/aic8800-sdio-linux-1.0, then makes.
set -euo pipefail
KSRC="${KSRC:-/lib/modules/$(uname -r)/build}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="aic8800-sdio-linux-1.0"

[ -d "$SRC" ] || git clone --depth 1 "https://github.com/LYU4662/$SRC"
cd "$SRC"

echo "Applying 6.18 port patches..."
for p in "$HERE/patches/"*.patch; do
  [ -e "$p" ] || { echo "  (no patches yet — see docs/BUILD-DRIVER.md)"; break; }
  patch -p1 --forward < "$p" || { echo "patch $p failed"; exit 1; }
done

echo "Building (KSRC=$KSRC)..."
make KSRC="$KSRC" ARCH="$(uname -m)" -j"$(nproc)"
echo
echo "Built: $SRC/aic8800_bsp/aic8800_bsp.ko  and  $SRC/aic8800_fdrv/aic8800_fdrv.ko"
echo "modinfo check (must match $(uname -r)):"
modinfo aic8800_bsp/aic8800_bsp.ko | grep vermagic
