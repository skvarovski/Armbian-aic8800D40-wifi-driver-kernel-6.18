#!/bin/bash
# port-to-6.18.sh — port LYU4662/aic8800-sdio-linux-1.0 to Linux 6.18 (ophub 6.18.37).
# Reconstructs ALL patches applied during the 2026-07-10 session that got the driver building
# and the AIC8800D40 (rev 7) chip booting (150 MHz).
#
# Usage:  cd <upstream LYU4662 source> && bash /path/to/port-to-6.18.sh
# Then:   make KSRC=/lib/modules/$(uname -r)/build ARCH=arm64 -j4
#
# Run on the box (native arm64) or cross-compile. Patches are idempotent-ish but best on a fresh clone.
set -uo pipefail
ROOT="$(pwd)"
[ -f aic8800_bsp/aicsdio.c ] || { echo "Run from the LYU4662 source root (needs aic8800_bsp/aicsdio.c)"; exit 1; }
echo "Porting LYU4662 aic8800-sdio to 6.18 in $ROOT ..."

# ── 1. timer API renames (6.15+) ─────────────────────────────────────────────
for f in aic8800_bsp/*.c aic8800_fdrv/*.c; do
  sed -i 's/del_timer_sync/timer_delete_sync/g; s/del_timer(/timer_delete(/g' "$f"
done

# ── 2. remove Rockchip-Android MODULE_IMPORT_NS(VFS_internal...) + add linux/timer.h ──
for f in aic8800_bsp/*.c aic8800_fdrv/*.c; do
  grep -q "MODULE_IMPORT_NS(VFS_internal" "$f" && sed -i '/MODULE_IMPORT_NS(VFS_internal/d' "$f"
  if grep -q "from_timer" "$f" && ! grep -q "linux/timer.h" "$f"; then
    sed -i '/#include <linux\/module.h>/a #include <linux/timer.h>' "$f"
  fi
done

# ── 3. from_timer compat macro (6.18 lacks it in timer.h on ophub headers) ────
for hf in aic8800_fdrv/rwnx_compat.h aic8800_bsp/aicsdio.h; do
  grep -q "FROM_TIMER_COMPAT" "$hf" || sed -i '1i #ifndef FROM_TIMER_COMPAT\n#define FROM_TIMER_COMPAT\n#define from_timer(var, t, f) container_of(t, typeof(*var), f)\n#endif' "$hf"
done

# ── 4. cfg80211 wdev conversion (6.12+): ~10 ops net_device → wireless_dev ────
python3 << 'PYWDEV'
import re
f="aic8800_fdrv/rwnx_main.c"
lines=open(f).read().splitlines(True)
for fn in ["add_key","get_key","del_key","set_default_key","set_default_mgmt_key",
           "add_station","del_station_compat","change_station","get_station","dump_station"]:
    di=-1
    for i,l in enumerate(lines):
        if re.search(r"\brwnx_cfg80211_"+fn+r"\s*\(", l) and "struct wiphy" in l: di=i; break
    if di<0: continue
    var=None; nline=None; bi=None
    for j in range(di, min(di+16,len(lines))):
        m=re.search(r"struct net_device \*(\w+)", lines[j])
        if m and var is None: var=m.group(1); nline=j
        if "{" in lines[j]: bi=j; break
    if not var or bi is None: continue
    lines[nline]=lines[nline].replace("struct net_device *"+var,"struct wireless_dev *wdev",1)
    idx=lines[bi].find("{")
    lines[bi]=lines[bi][:idx+1]+"\n\tstruct net_device *"+var+" = wdev->netdev;"+lines[bi][idx+1:]
open(f,"w").write("".join(lines))
print("wdev conversion done")
PYWDEV

# ── 5. set_default_key: revert to net_device (6.18 keeps it net_device) ──────
python3 - << 'PYREVERT'
f="aic8800_fdrv/rwnx_main.c"; s=open(f).read()
di=s.find("rwnx_cfg80211_set_default_key(struct wiphy")
if di>0:
    chunk=s[di:di+600]
    chunk=chunk.replace("struct wireless_dev *wdev","struct net_device *netdev",1)
    chunk=chunk.replace("\n\tstruct net_device *netdev = wdev->netdev;","",1)
    s=s[:di]+chunk+s[di+600:]
    open(f,"w").write(s); print("set_default_key reverted")
PYREVERT

# ── 6. cfg80211 call-site fixes: new_sta/del_sta → wdev (ieee80211_ptr) ──────
f="aic8800_fdrv/rwnx_main.c"
sed -i 's/cfg80211_new_sta(rwnx_vif->ndev,/cfg80211_new_sta(rwnx_vif->ndev->ieee80211_ptr,/g' "$f"
sed -i 's/cfg80211_del_sta(rwnx_vif->ndev,/cfg80211_del_sta(rwnx_vif->ndev->ieee80211_ptr,/g' "$f"
sed -i 's/rwnx_cfg80211_add_key(wiphy, dev,/rwnx_cfg80211_add_key(wiphy, dev->ieee80211_ptr,/g' "$f"
sed -i 's/rwnx_cfg80211_del_station_compat(wiphy, dev, NULL)/rwnx_cfg80211_del_station_compat(wiphy, dev->ieee80211_ptr, NULL)/g' "$f"

# ── 7. ch_switch_notify 3-arg + ch_switch_started_notify 5-arg ───────────────
sed -i 's/cfg80211_ch_switch_notify(vif->ndev, &csa->chandef, 0, 0)/cfg80211_ch_switch_notify(vif->ndev, \&csa->chandef, 0)/g; s/cfg80211_ch_switch_notify(vif->ndev, &csa->chandef);/cfg80211_ch_switch_notify(vif->ndev, \&csa->chandef, 0)/g' "$f"
sed -i 's/cfg80211_ch_switch_started_notify(dev, &csa->chandef, 0, params->count, false, 0)/cfg80211_ch_switch_started_notify(dev, \&csa->chandef, 0, params->count, params->block_tx)/g; s/cfg80211_ch_switch_started_notify(dev, &csa->chandef, 0, params->count, false)/cfg80211_ch_switch_started_notify(dev, \&csa->chandef, 0, params->count, params->block_tx)/g; s/cfg80211_ch_switch_started_notify(dev, &csa->chandef, params->count, params->block_tx)/cfg80211_ch_switch_started_notify(dev, \&csa->chandef, 0, params->count, params->block_tx)/g; s/cfg80211_ch_switch_started_notify(dev, &csa->chandef, params->count)/cfg80211_ch_switch_started_notify(dev, \&csa->chandef, 0, params->count, params->block_tx)/g' "$f"

# ── 8. rx_spurious/4addr + link_id (rwnx_rx.c) ───────────────────────────────
g="aic8800_fdrv/rwnx_rx.c"
sed -i 's/rwnx_cfg80211_rx_spurious_frame(rwnx_vif->ndev, hdr->addr2, GFP_ATOMIC)/rwnx_cfg80211_rx_spurious_frame(rwnx_vif->ndev, hdr->addr2, 0, GFP_ATOMIC)/g; s/cfg80211_rx_spurious_frame(rwnx_vif->ndev, hdr->addr2, GFP_ATOMIC)/cfg80211_rx_spurious_frame(rwnx_vif->ndev, hdr->addr2, 0, GFP_ATOMIC)/g' "$g"
sed -i 's/cfg80211_rx_unexpected_4addr_frame(rwnx_vif->ndev,\n/sta->mac_addr, 0, GFP_ATOMIC)/cfg80211_rx_unexpected_4addr_frame(rwnx_vif->ndev,\n/sta->mac_addr, 0, GFP_ATOMIC)/g' "$g"  # NB: see note

# ── 9. set_tx_power +link_id ─────────────────────────────────────────────────
sed -i 's|static int rwnx_cfg80211_set_tx_power(struct wiphy \*wiphy, struct wireless_dev \*wdev,|static int rwnx_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, int link_id,|' "$f"

# ── 10. disable non-essential ops (sig mismatch on 6.18; not needed for AP) ──
for op in channel_switch set_monitor_channel set_wiphy_params start_radar_detection; do
  sed -i "s|^\(\s*\)\.${op} = rwnx_cfg80211_${op},|\1//.${op} = rwnx_cfg80211_${op},  // disabled: 6.18 sig change, not needed for basic AP|" "$f"
done

# ── 11. TDLS mgmt->u guard (< 6.18) ──────────────────────────────────────────
python3 - << 'PYTDLS'
g="aic8800_fdrv/rwnx_tdls.c"; lines=open(g).read().splitlines(True)
out=[]; i=0
while i < len(lines):
    if "case WLAN_PUB_ACTION_TDLS_DISCOVER_RES:" in lines[i]:
        out.append(lines[i]); i+=1
        out.append("#if LINUX_VERSION_CODE < KERNEL_VERSION(6,18,0)\n")
        while i < len(lines) and "break;" not in lines[i]: out.append(lines[i]); i+=1
        out.append("#else\n\tbreak;\n#endif\n")
        if i < len(lines): out.append(lines[i]); i+=1
    else: out.append(lines[i]); i+=1
open(g,"w").write("".join(out)); print("TDLS guarded")
PYTDLS

# ── 12. wakelock API (6.18: register/unregister) ─────────────────────────────
w="aic8800_fdrv/rwnx_wakelock.c"
python3 - << 'PYWK'
f="aic8800_fdrv/rwnx_wakelock.c"; s=open(f).read()
s=s.replace("\tws = wakeup_source_create(name);\n\twakeup_source_add(ws);\n\treturn ws;","\treturn wakeup_source_register(NULL, name);")
s=s.replace("\twakeup_source_remove(ws);\n\twakeup_source_destroy(ws);","\twakeup_source_unregister(ws);")
open(f,"w").write(s); print("wakelock fixed")
PYWK

# ── 13. FEATURE_SDIO_CLOCK_V3 = 150 MHz (REQUIRED for AIC8800D40 rev 7) ──────
sed -i 's|^#define FEATURE_SDIO_CLOCK          25000000.*|#define FEATURE_SDIO_CLOCK          150000000  // AIC8800D40 rev7 needs 150MHz|; s|^#define FEATURE_SDIO_CLOCK_V3       25000000.*|#define FEATURE_SDIO_CLOCK_V3       150000000|' aic8800_bsp/aic_bsp_driver.h

echo "Port applied. Build with:"
echo "  make KSRC=/lib/modules/\$(uname -r)/build ARCH=arm64 -j4"
echo "Expected: 0 errors → aic8800_bsp/aic8800_bsp.ko + aic8800_fdrv/aic8800_fdrv.ko"
echo "NOTE: if a stray 6.18 API error remains (kernel minor-version drift), it'll be a single"
echo "      cfg80211/timer signature fix — see docs/TROUBLESHOOTING.md in the community package."
