# Driver

- **prebuilt-6.18.37-ophub/** — ready `.ko` for the ophub 6.18.37 kernel. _(Populated from a
  built box; see the repo Releases if absent here.)_
- **patches/** — the 6.18 port (cfg80211 wdev, timer, wakelock, disabled ops, 150 MHz clock).
  Applied by `build.sh` against upstream LYU4662.
- **build.sh** — rebuild for your kernel.

For any kernel ≠ 6.18.37-ophub, use `./build.sh` (see ../docs/BUILD-DRIVER.md).
