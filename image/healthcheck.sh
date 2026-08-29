#!/bin/sh
# Healthy means: interface up, default route through the tunnel, recent
# WireGuard handshake, the Internet reachable through the tunnel — and, with
# the kill switch on, the ruleset present and the Internet NOT reachable
# around the tunnel.
set -u

VPN_INTERFACE="${VPN_INTERFACE:-wg0}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://1.1.1.1}"
WAN_IF="$(cat /run/vpn/wan_if 2>/dev/null)"
WAN_IF="${WAN_IF:-eth0}"
KILLSWITCH_STATE="$(cat /run/vpn/killswitch 2>/dev/null || echo on)"

ip link show "$VPN_INTERFACE" >/dev/null 2>&1 || exit 1
ip -4 route get 1.1.1.1 2>/dev/null | grep -q "dev $VPN_INTERFACE" || exit 1

if [ "$KILLSWITCH_STATE" = "on" ]; then
  nft list table inet vpn_killswitch >/dev/null 2>&1 || exit 1
fi

latest="$(wg show "$VPN_INTERFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -n1)"
now="$(date +%s)"
[ -n "$latest" ] && [ "$latest" -gt 0 ] && [ $((now - latest)) -lt 180 ] || exit 1

curl --interface "$VPN_INTERFACE" -fsS4 --max-time 8 "$HEALTHCHECK_URL" >/dev/null || exit 1

if [ "$KILLSWITCH_STATE" = "on" ]; then
  if curl --interface "$WAN_IF" -fsS4 --max-time 5 "$HEALTHCHECK_URL" >/dev/null 2>&1; then
    exit 1
  fi
fi

exit 0
