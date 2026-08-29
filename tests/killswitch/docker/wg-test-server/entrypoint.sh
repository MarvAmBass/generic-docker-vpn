#!/bin/sh
# WireGuard test gateway: terminates the tunnel (kernel WireGuard), forwards
# tunnel traffic to the fake-internet bridge, answers DNS on the tunnel, and
# serves an on-link HTTP target on its LAN address for the suite's
# route-independent firewall checks.
set -eu

SERVER_PRIVATE_KEY="${SERVER_PRIVATE_KEY:?SERVER_PRIVATE_KEY is required}"
CLIENT_PUBLIC_KEY="${CLIENT_PUBLIC_KEY:?CLIENT_PUBLIC_KEY is required}"
WG_PORT="${WG_PORT:-51820}"
WG_ADDR="${WG_ADDR:-10.66.0.1/24}"
CLIENT_ADDR="${CLIENT_ADDR:-10.66.0.2/32}"
FAKE_WAN_CIDR="${FAKE_WAN_CIDR:-10.77.20.0/24}"
FAKE_WAN_TARGET="${FAKE_WAN_TARGET:-10.77.20.80}"

cat >/tmp/wg-server.conf <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_ADDR}
EOF

ip link add wg0 type wireguard
wg setconf wg0 /tmp/wg-server.conf
ip addr add "$WG_ADDR" dev wg0
ip link set wg0 up

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

cat >/tmp/gateway.nft <<EOF
table inet wg_gateway {
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "wg0" ip daddr ${FAKE_WAN_CIDR} accept
    oifname "wg0" ct state established,related accept
  }
}

table ip wg_gateway_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${WG_ADDR%/*}/24 ip daddr ${FAKE_WAN_CIDR} masquerade
  }
}
EOF
nft -f /tmp/gateway.nft

cat >/tmp/dnsmasq.conf <<EOF
interface=wg0
bind-interfaces
no-resolv
address=/fake.test/${FAKE_WAN_TARGET}
EOF
dnsmasq --no-daemon --conf-file=/tmp/dnsmasq.conf &

# On-link HTTP target: reachable from the VPN client's LAN interface with a
# connected route, so only the kill switch can block it.
mkdir -p /www
printf 'lan-ok\n' >/www/index.html
httpd -f -p 80 -h /www &

trap 'ip link delete wg0 >/dev/null 2>&1 || true' INT TERM

while :; do
  sleep 3600 &
  wait $!
done
