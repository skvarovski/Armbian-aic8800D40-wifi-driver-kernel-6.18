#!/bin/bash
# INSTALL.sh — turnkey installer for the AIC8800D40 WiFi (AC WPA2 AP) fix.
# Idempotent. Run as root on the box (ophub 6.18.37 Armbian).
#
# Env (all optional — defaults are EXAMPLE values):
#   SSID        (default AIC8800D40-AP)
#   PASS        (default ChangeMe12345)
#   CHANNEL     (default 36)
#   AP_IP       (default 192.168.43.1)   — the AP's wlan0 address; DHCP = .10-.50 of its /24
#
# This installer sets up:
#   firmware + driver + regdom → wlan0 up → hostapd AP (with auto-restart drop-in)
#   → wlan0 IP (in hostapd ExecStartPost, after the AP is up) → dnsmasq DHCP+DNS → NAT internet.
set -euo pipefail

SSID="${SSID:-AIC8800D40-AP}"
PASS="${PASS:-ChangeMe12345}"
CHANNEL="${CHANNEL:-36}"
AP_IP="${AP_IP:-192.168.43.1}"

# AP subnet base (first 3 octets) for DHCP range
AP_BASE="$(echo "$AP_IP" | awk -F. '{print $1"."$2"."$3}')"

HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (parent of ap-config/)
KVER="$(uname -r)"

say(){ printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }

say "AIC8800D40 WiFi installer  (SSID=$SSID  CH=$CHANNEL  AP_IP=$AP_IP  kernel=$KVER)"

# ─── firmware ────────────────────────────────────────────────────────────────
say "Firmware"
FW="$HERE/firmware"
if ! ls "$FW"/*.bin >/dev/null 2>&1; then
  echo "  No firmware blobs in $FW/."
  echo "  Download the Release asset (aic8800D40-firmware.tar.gz) and extract it into $FW/,"
  echo "  or extract your own (firmware/FIRMWARE-EXTRACTION.md). Aborting."
  exit 1
fi
for d in /lib/firmware/aic8800_fw/SDIO/aic8800D80 \
         /lib/firmware/aic8800/SDIO/aic8800D80 \
         /usr/lib/firmware/aic8800_fw/SDIO/aic8800D80 \
         /usr/lib/firmware/aic8800/SDIO/aic8800D80 \
         /usr/lib/firmware/aic8800_sdio/aic8800 \
         /usr/lib/firmware/aic8800_sdio; do
  mkdir -p "$d"; cp -f "$FW"/*.bin "$FW"/*.txt "$d/" 2>/dev/null || true
done
ok "firmware set copied to loader search paths"

# ─── driver (prebuilt for ophub 6.18.37) ─────────────────────────────────────
say "Driver"
MODDIR="/lib/modules/$KVER/kernel/drivers/net/wireless/aic8800"
mkdir -p "$MODDIR"
if [ -f "$HERE/driver/prebuilt-$KVER/aic8800_bsp.ko" ]; then
  cp -f "$HERE/driver/prebuilt-$KVER/aic8800_bsp.ko" \
        "$HERE/driver/prebuilt-$KVER/aic8800_fdrv.ko" "$MODDIR/"
  ok "prebuilt modules for $KVER installed"
else
  echo "  No prebuilt modules for kernel '$KVER' in driver/prebuilt-$KVER/."
  echo "  Rebuild from source: see docs/BUILD-DRIVER.md"
  echo "  (continuing — assuming you installed the .ko yourself)"
fi
depmod -a || true
printf 'aic8800_bsp\naic8800_fdrv\n' > /etc/modules-load.d/aic8800.conf
ok "driver autoload enabled"

# ─── regdom ──────────────────────────────────────────────────────────────────
say "Regulatory domain (5 GHz AP)"
cp -f "$HERE/ap-config/regdom-ru.conf" /etc/modprobe.d/regdom-ru.conf
iw reg set RU 2>/dev/null || true
ok "regdom RU"

# ─── packages ───────────────────────────────────────────────────────────────
say "hostapd + dnsmasq"
if ! command -v hostapd >/dev/null; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq hostapd dnsmasq
fi
command -v hostapd >/dev/null && ok "hostapd present"
command -v dnsmasq >/dev/null && ok "dnsmasq present"

# ─── mask wpa_supplicant (BEFORE hostapd) ────────────────────────────────────
# ROOT CAUSE of "AP starts then stops 1 ms later": the system D-Bus wpa_supplicant
# instance (-u -s) grabs wlan0 before hostapd can. hostapd then logs
# UNINITIALIZED->HT_SCAN then "Deactivated" without ever reaching AP-ENABLED.
# This box is AP-only (WAN = ethernet), so wpa_supplicant is not needed.
say "Disable wpa_supplicant (it fights hostapd for wlan0)"
systemctl stop wpa_supplicant.service 2>/dev/null || true
systemctl mask wpa_supplicant.service 2>/dev/null || true
# Also mask the socket/D-Bus activations if present.
systemctl mask wpa_supplicant.socket 2>/dev/null || true
ok "wpa_supplicant masked"

# ─── DNS: disable systemd-resolved (conflicts with dnsmasq on :53) ───────────
say "DNS: stop systemd-resolved so dnsmasq can bind :53 on wlan0"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  systemctl disable --now systemd-resolved || true
  ok "systemd-resolved disabled"
else
  systemctl disable --now systemd-resolved 2>/dev/null || true
  ok "systemd-resolved already off"
fi

# ─── static /etc/resolv.conf ─────────────────────────────────────────────────
# systemd-resolved symlinks /etc/resolv.conf → ../run/systemd/resolve/stub-resolv.conf.
# With resolved off, that target goes stale (127.0.0.53 that nothing answers).
# Break the symlink and write a real file (immutable so nothing re-symlinks it).
say "Static /etc/resolv.conf"
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
# Managed by armbian-aic8800d40-wifi INSTALL.sh — do not edit (chattr +i).
nameserver 1.1.1.1
nameserver 8.8.8.8
# If your LAN has a resolver, add it here for lower latency, e.g.:
# nameserver <your-LAN-gateway-DNS>
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true
ok "/etc/resolv.conf set to 1.1.1.1 / 8.8.8.8 (immutable)"

# ─── wlan0 boot (IP + regdom) ────────────────────────────────────────────────
say "wlan0 boot service"
cp -f "$HERE/ap-config/sbc-ap-wifi-up.sh" /usr/local/sbin/sbc-ap-wifi-up.sh
chmod +x /usr/local/sbin/sbc-ap-wifi-up.sh
sed "s|^Environment=AP_IP=.*|Environment=AP_IP=$AP_IP|" \
    "$HERE/ap-config/sbc-wlan0-up.service" > /etc/systemd/system/sbc-wlan0-up.service
systemctl daemon-reload
systemctl enable sbc-wlan0-up.service >/dev/null 2>&1 || true
ok "sbc-wlan0-up enabled (AP_IP=$AP_IP)"

# ─── hostapd AP config ───────────────────────────────────────────────────────
say "hostapd AP config (SSID=$SSID, CH=$CHANNEL, WPA2)"
mkdir -p /etc/hostapd
sed -e "s|^ssid=.*|ssid=$SSID|" \
    -e "s|^wpa_passphrase=.*|wpa_passphrase=$PASS|" \
    -e "s|^channel=.*|channel=$CHANNEL|" \
    "$HERE/ap-config/hostapd.conf" > /etc/hostapd/hostapd.conf
# DAEMON_CONF (deprecated but still honored by Debian's unit)
grep -q '^DAEMON_CONF=' /etc/default/hostapd 2>/dev/null \
  && sed -i "s|^DAEMON_CONF=.*|DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"|" /etc/default/hostapd \
  || echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
systemctl unmask hostapd.service >/dev/null 2>&1 || true
systemctl enable hostapd.service >/dev/null 2>&1 || true
ok "hostapd configured + enabled"

# ─── hostapd retry drop-in (Type=simple + auto-restart + wlan0 IP + NAT) ─────
say "hostapd retry drop-in (Type=simple, Restart=always, sets wlan0 IP + NAT after AP up)"
mkdir -p /etc/systemd/system/hostapd.service.d
# Substitute the AP IP placeholder; existing drop-in is overwritten (idempotent).
sed "s|__AP_IP__|$AP_IP|g" \
    "$HERE/ap-config/hostapd.service.d-retry-ap.conf" \
    > /etc/systemd/system/hostapd.service.d/retry-ap.conf
systemctl daemon-reload
ok "retry-ap.conf installed (AP_IP=$AP_IP)"

# ─── NAT script ──────────────────────────────────────────────────────────────
say "NAT script (dynamic WAN detection)"
cp -f "$HERE/ap-config/sbc-ap-nat.sh" /usr/local/sbin/sbc-ap-nat.sh
chmod +x /usr/local/sbin/sbc-ap-nat.sh
ok "sbc-ap-nat.sh installed"

# ─── dnsmasq (DHCP + DNS) ────────────────────────────────────────────────────
# GOTCHA: dnsmasq loads EVERY file in /etc/dnsmasq.d/ (via the default -7 invocation).
# A leftover backup file there (e.g. ap.conf.pre-dnsfix containing "port=0") silently
# re-disables DNS. Always move backups OUT of /etc/dnsmasq.d/. We hard-guard below.
say "dnsmasq DHCP+DNS (${AP_BASE}.10-${AP_BASE}.50, upstream 1.1.1.1/8.8.8.8)"
# Remove any old backup/second copies from /etc/dnsmasq.d/ that could re-introduce port=0.
for f in /etc/dnsmasq.d/*.bak /etc/dnsmasq.d/*.pre-* /etc/dnsmasq.d/*.orig /etc/dnsmasq.d/ap.conf.*; do
  [ -f "$f" ] && rm -f "$f" && echo "  removed stale dnsmasq.d file: $f"
done
sed -e "s|192\.168\.43\.|${AP_BASE}.|g" "$HERE/ap-config/dnsmasq-ap.conf" > /etc/dnsmasq.d/ap.conf
# Safety net: if anything in /etc/dnsmasq.d/ still says port=0, DNS is dead.
if grep -rqE '^\s*port\s*=\s*0' /etc/dnsmasq.d/ 2>/dev/null; then
  echo "  WARNING: a 'port=0' line exists somewhere in /etc/dnsmasq.d/ — DNS will be disabled."
  echo "  Offending file(s):"
  grep -rlE '^\s*port\s*=\s*0' /etc/dnsmasq.d/ 2>/dev/null | sed 's/^/    /'
  echo "  Move or fix them (see docs/TROUBLESHOOTING.md 'DNS disabled')."
fi
systemctl enable dnsmasq.service >/dev/null 2>&1 || true
ok "dnsmasq configured + enabled"

# ─── sysctl: enable IPv4 forwarding (persist) ────────────────────────────────
say "Enable IPv4 forwarding"
if ! grep -q '^net.ipv4.ip_forward' /etc/sysctl.d/99-aic-ap.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-aic-ap.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
ok "ip_forward=1"

# ─── bring it up now ─────────────────────────────────────────────────────────
say "Starting services"
# release NetworkManager's grip on wlan0 if present
nmcli dev set wlan0 managed no 2>/dev/null || true
systemctl restart sbc-wlan0-up 2>/dev/null || /usr/local/sbin/sbc-ap-wifi-up.sh || true
systemctl restart dnsmasq 2>/dev/null || true
systemctl restart hostapd 2>/dev/null || true
sleep 3

say "Done. Verify:"
echo "    iw dev wlan0 info            # expect: type AP, ssid $SSID, channel $CHANNEL (5 GHz)"
echo "    systemctl is-active hostapd dnsmasq"
echo "    ip addr show wlan0           # expect AP IP $AP_IP/24 (set by hostapd ExecStartPost)"
echo "    Connect a client to '$SSID' with password '$PASS' — should get DHCP + DNS + internet"
echo ""
echo "    Speed check: expect ~70-90 Mbps down (1T1R SDIO ceiling). Not a bug."
echo ""
echo "    GOTCHA: if DNS fails, check ALL files in /etc/dnsmasq.d/ for a 'port=0' line"
echo "    (incl. backups — dnsmasq loads every file there). See docs/TROUBLESHOOTING.md."
iw dev wlan0 info 2>/dev/null | grep -E 'type|ssid|channel' || echo "(wlan0 not yet up — check dmesg | grep -E 'aic|rd_version')"
