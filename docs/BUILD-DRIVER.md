# Rebuild the AIC8800D40 driver for your kernel

The prebuilt `.ko` files in `driver/prebuilt-6.18.37-ophub/` match **only** the ophub `6.18.37`
kernel (vermagic). For any other kernel, rebuild from source.

## Prerequisites (on the box)
```bash
sudo apt-get update
sudo apt-get install -y build-essential linux-headers-$(uname -r) git bc
ls -ld /lib/modules/$(uname -r)/build   # must exist
```

## Build
```bash
cd driver
./build.sh        # clones upstream LYU4662, applies driver/patches/*, builds
```
`build.sh` equivalent, manual:
```bash
git clone --depth 1 https://github.com/LYU4662/aic8800-sdio-linux-1.0
cd aic8800-sdio-linux-1.0
for p in ../patches/*.patch; do patch -p1 < "$p"; done
make KSRC=/lib/modules/$(uname -r)/build ARCH=$(uname -m) -j$(nproc)
# → aic8800_bsp/aic8800_bsp.ko  and  aic8800_fdrv/aic8800_fdrv.ko
```

## What the patches do (so you can adapt for other kernel versions)
The patches in `driver/patches/` are grouped:

1. **cfg80211 wdev conversion** — Linux 6.12+ changed many `cfg80211_ops` callbacks from
   `struct net_device *` to `struct wireless_dev *`. The patch changes the affected op functions
   (add_key/get_key/del_key/set_default_mgmt_key/add_station/del_station/change_station/get_station/
   dump_station) and the `cfg80211_new_sta`/`del_sta` call sites. (`set_default_key` stays
   `net_device` on 6.18.)
2. **timer API + from_timer** — `del_timer_sync`→`timer_delete_sync`, `del_timer`→`timer_delete`;
   adds a `from_timer` compat macro if the headers lack it.
3. **wakelock API** — `wakeup_source_create`+`add` → `wakeup_source_register(NULL, name)`;
   `remove`+`destroy` → `unregister`.
4. **disabled/guarded ops** — `channel_switch`, `start_radar_detection` commented out of the
   `cfg80211_ops` table (CSA/DFS not needed for a basic AP); TDLS `mgmt->u` block guarded under
   kernel `< 6.18`; the Rockchip-Android `VFS_internal_…` namespace import removed.
5. **SDIO clock** — `FEATURE_SDIO_CLOCK_V3` set to `150000000` (required for chip rev 7).

If your kernel is older than 6.12 you may not need patch #1; if older than 6.15, not #2; etc.
Apply selectively.

## Verify
```bash
modinfo aic8800_bsp/aic8800_bsp.ko | grep vermagic    # must match `uname -r`
sudo cp aic8800_bsp/aic8800_bsp.ko aic8800_fdrv/aic8800_fdrv.ko \
     /lib/modules/$(uname -r)/kernel/drivers/net/wireless/aic8800/
sudo depmod -a
sudo modprobe aic8800_bsp && sudo modprobe aic8800_fdrv
dmesg | grep -E 'aic|rd_version'      # expect rd_version != 00000000
```

If `modinfo` vermagic doesn't match `uname -r`, the build picked the wrong headers — double-check
`/lib/modules/$(uname -r)/build` and that `KSRC` points to it.

## Porting notes for other kernel series
- The cfg80211 wdev refactor landed in 6.12; for 5.15/6.1 LTS trees the stock LYU driver may build
  with fewer changes.
- `from_timer`, wakelock, and the `channel_switch`/`start_radar` op signatures also shifted across
  6.1x; check each error the compiler throws and apply the matching hunk.
- The 150 MHz clock requirement is silicon-rev-specific, not kernel-specific — keep it regardless.
