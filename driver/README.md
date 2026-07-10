# Driver

- **prebuilt-6.18.37-ophub/** — ready `.ko` for the ophub 6.18.37 kernel, **included in the repo**:
  - `aic8800_bsp.ko` and `aic8800_fdrv.ko`
  - vermagic: `6.18.37-ophub SMP preempt mod_unload aarch64`

  If your `uname -r` matches `6.18.37-ophub`, `INSTALL.sh` copies these in directly — no build
  step needed.
- **patches/port-to-6.18.sh** — the port script. Applied by `build.sh` against the upstream
  **LYU4662/aic8800-sdio-linux-1.0** tree to produce the `.ko` above. It covers: the 6.12+
  cfg80211 `net_device → wireless_dev` op conversion, timer API renames
  (`del_timer_sync`→`timer_delete_sync` + `from_timer` shim), wakelock API renames, disabled
  ops removed in 6.18, the Rockchip-Android `VFS_internal_…` namespace import removed, and
  `FEATURE_SDIO_CLOCK_V3 = 150000000`.
- **build.sh** — rebuild for your kernel (upstream LYU4662 + the patches).

> The prebuilt modules **only** match `6.18.37-ophub` (vermagic check). For **any other kernel**
> (different ophub version, mainline, a different board family), rebuild from source with
> `./build.sh` — see [../docs/BUILD-DRIVER.md](../docs/BUILD-DRIVER.md). Do not expect these `.ko`
> to load on a kernel whose vermagic differs.
