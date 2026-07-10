#!/bin/sh
# sbc-ap-nat.sh — set up NAT + FORWARD so AP clients (on wlan0) reach the internet
# via the box's WAN interface (ethernet, detected dynamically).
#
# Called from hostapd.service.d/retry-ap.conf ExecStartPost (after the AP is up).
# Idempotent: every rule uses `-C ... || -A ...` so re-runs are a no-op.
# Tolerant: no `set -e`; a missing WAN or iptables just logs and exits 0.
#
# AP subnet is derived from wlan0's own address (set by the prior ExecStartPost),
# so no hardcoding — if you changed AP_IP in INSTALL.sh, this just works.

AP_IF=wlan0
# Detect the WAN interface from the default route. Fall back to eth0 if detection fails.
WAN="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')" || true
[ -n "$WAN" ] || WAN=eth0

# Nothing to do if the WAN interface doesn't exist (e.g. ethernet not up yet).
if ! ip link show "$WAN" >/dev/null 2>&1; then
  echo "sbc-ap-nat: WAN interface '$WAN' not present yet — skipping NAT rules." >&2
  exit 0
fi

# AP subnet = the /24 configured on wlan0 (e.g. 192.168.43.0/24).
AP_NET="$(ip -4 -o addr show dev "$AP_IF" 2>/dev/null | awk '{print $4}')" || true
if [ -z "$AP_NET" ]; then
  echo "sbc-ap-nat: no IPv4 address on $AP_IF yet — cannot derive AP subnet. Run after the IP is set." >&2
  exit 0
fi

# Enable routing (persist via INSTALL.sh's sysctl; this is the live knob).
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# --- NAT: masquerade traffic from the AP subnet out to the WAN -----------------
iptables -t nat -C POSTROUTING -s "$AP_NET" -o "$WAN" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$AP_NET" -o "$WAN" -j MASQUERADE 2>/dev/null \
  || true

# --- FORWARD: allow established/related back in, allow AP→WAN, drop the rest ---
iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || true

iptables -C FORWARD -i "$AP_IF" -o "$WAN" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$AP_IF" -o "$WAN" -j ACCEPT 2>/dev/null \
  || true

echo "sbc-ap-nat: NAT on $AP_NET → $WAN, FORWARD $AP_IF↔$WAN (idempotent)."
exit 0
