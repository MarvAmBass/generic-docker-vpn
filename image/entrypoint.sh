#!/bin/sh
# VPN gateway entrypoint.
#
# Order matters: the nftables kill switch is installed atomically before any
# tunnel process exists, so there is no pre-firewall window. WireGuard runs in
# userspace (wireguard-go) as an unprivileged user that inherits a pre-opened
# TUN fd; root is only used for setup. If the daemon dies it is respawned in
# place — the container never exits on daemon death, because a container
# restart would create a fresh network namespace and orphan every service
# joined to it. The drop-policy ruleset belongs to the namespace and keeps it
# sealed during any gap.
set -eu

KILLSWITCH="${KILLSWITCH:-on}"
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"
WG_CONFIG="/etc/wireguard/${VPN_INTERFACE}.conf"
VPN_ENDPOINT_IP="${VPN_ENDPOINT_IP:-}"
VPN_ENDPOINT_PORT="${VPN_ENDPOINT_PORT:-}"
VPN_DNS="${VPN_DNS:-1.1.1.1}"
VPN_ACCEPT_TCP="${VPN_ACCEPT_TCP:-}"
VPN_ACCEPT_UDP="${VPN_ACCEPT_UDP:-}"
VPN_HTTP_PROXY="${VPN_HTTP_PROXY:-off}"
VPN_HTTP_PROXY_PORT="${VPN_HTTP_PROXY_PORT:-8888}"
PORT_FORWARD_MODE="${PORT_FORWARD_MODE:-}"
FORWARDED_PORT="${FORWARDED_PORT:-}"
WG_USER="wireguard"

fail() {
  echo "vpn-entrypoint: $*" >&2
  exit 1
}

case "$KILLSWITCH" in
  on|off) ;;
  *) fail "KILLSWITCH must be exactly 'on' or 'off' (got: '$KILLSWITCH')" ;;
esac

case "$VPN_HTTP_PROXY" in
  on|off) ;;
  *) fail "VPN_HTTP_PROXY must be 'on' or 'off' (got: '$VPN_HTTP_PROXY')" ;;
esac

[ -r "$WG_CONFIG" ] || fail "missing readable $WG_CONFIG"

# Endpoint source of truth: env wins when set; otherwise it is derived from
# the config's own Endpoint= line, so dropping in a new provider config and
# restarting just works. Hostname endpoints are rejected either way — this
# gateway never performs DNS outside the tunnel, by design.
if [ -z "$VPN_ENDPOINT_IP" ] || [ -z "$VPN_ENDPOINT_PORT" ]; then
  conf_ep="$(awk -F= '/^Endpoint[ \t]*=/ { gsub(/[ \t]/, "", $2); print $2; exit }' "$WG_CONFIG")"
  [ -n "$conf_ep" ] || fail "no Endpoint in $WG_CONFIG and VPN_ENDPOINT_IP/VPN_ENDPOINT_PORT not set"
  conf_ip="${conf_ep%:*}"
  conf_port="${conf_ep##*:}"
  [ "$conf_ip" != "$conf_ep" ] || fail "Endpoint in $WG_CONFIG has no port (expected IP:PORT)"
  case "$conf_ip" in
    *[!0-9.]*) fail "Endpoint host in $WG_CONFIG is '$conf_ip', not a numeric IPv4 address. This gateway performs no DNS outside the tunnel by design — resolve the hostname yourself and either put the IP in the config or set VPN_ENDPOINT_IP/VPN_ENDPOINT_PORT." ;;
  esac
  VPN_ENDPOINT_IP="${VPN_ENDPOINT_IP:-$conf_ip}"
  VPN_ENDPOINT_PORT="${VPN_ENDPOINT_PORT:-$conf_port}"
fi

case "$VPN_ENDPOINT_IP" in
  *[!0-9.]*|"") fail "VPN_ENDPOINT_IP must be a numeric IPv4 address (set it or provide a numeric Endpoint in $WG_CONFIG)" ;;
esac

case "$VPN_ENDPOINT_PORT" in
  *[!0-9]*|"") fail "VPN_ENDPOINT_PORT must be numeric (set it or provide a numeric Endpoint in $WG_CONFIG)" ;;
esac

case "$FORWARDED_PORT" in
  ""|*[!0-9]*) [ -z "$FORWARDED_PORT" ] || fail "FORWARDED_PORT must be numeric" ;;
esac

if [ -z "$PORT_FORWARD_MODE" ]; then
  if [ -n "$FORWARDED_PORT" ]; then
    PORT_FORWARD_MODE=static
  else
    PORT_FORWARD_MODE=off
  fi
fi
case "$PORT_FORWARD_MODE" in
  off|static|natpmp) ;;
  *) fail "PORT_FORWARD_MODE must be 'off', 'static' or 'natpmp' (got: '$PORT_FORWARD_MODE')" ;;
esac

# Normalize a comma-separated port list into nft set syntax ("p1, p2").
# Empty input yields empty output (no rule is emitted for it).
normalize_ports() {
  _name="$1"
  _list="$2"
  _out=""
  _oldifs="$IFS"
  IFS=','
  for _p in $_list; do
    _p="$(printf '%s' "$_p" | tr -d ' \t')"
    [ -n "$_p" ] || continue
    case "$_p" in
      *[!0-9]*) fail "$_name contains a non-numeric port: '$_p'" ;;
    esac
    if [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ]; then
      fail "$_name contains an out-of-range port: '$_p'"
    fi
    if [ -n "$_out" ]; then
      _out="$_out, $_p"
    else
      _out="$_p"
    fi
  done
  IFS="$_oldifs"
  printf '%s' "$_out"
}

if [ "$VPN_HTTP_PROXY" = "on" ]; then
  if [ -n "$VPN_ACCEPT_TCP" ]; then
    VPN_ACCEPT_TCP="$VPN_ACCEPT_TCP,$VPN_HTTP_PROXY_PORT"
  else
    VPN_ACCEPT_TCP="$VPN_HTTP_PROXY_PORT"
  fi
fi

TCP_PORTS="$(normalize_ports VPN_ACCEPT_TCP "$VPN_ACCEPT_TCP")"
UDP_PORTS="$(normalize_ports VPN_ACCEPT_UDP "$VPN_ACCEPT_UDP")"

WG_UID="$(id -u "$WG_USER")"

# Network facts, discovered before anything is changed. The container may sit
# on several bridges; the WAN interface is the one carrying the default
# route. The embedded-DNS resolver address is engine-provided (Docker:
# 127.0.0.11) and must never be hardcoded; its upstream forwarding egresses
# via the HOST, outside the tunnel — which is why it gets dropped below.
WAN_IF="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
GATEWAY="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
BRIDGE_ROUTES="$(ip -4 route show scope link | awk -v wg="$VPN_INTERFACE" '
  $1 ~ /\// { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) != wg) print $(i + 1), $1 }')"
EMBEDDED_DNS="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf)"
[ -n "$WAN_IF" ] || fail "could not determine the WAN interface (no default route)"
[ -n "$GATEWAY" ] || fail "could not determine the default gateway"
[ -n "$BRIDGE_ROUTES" ] || fail "could not determine any connected bridge subnet"

mkdir -p /run/vpn
printf '%s\n' "$KILLSWITCH" >/run/vpn/killswitch
printf '%s\n' "$WAN_IF" >/run/vpn/wan_if
printf '%s\n' "$GATEWAY" >/run/vpn/gateway
printf '%s\n' "$BRIDGE_ROUTES" >/run/vpn/lan_subnets
printf '%s\n' "$EMBEDDED_DNS" >/run/vpn/embedded_dns
printf '%s\n' "$VPN_ENDPOINT_IP" >/run/vpn/endpoint_ip

if [ "$KILLSWITCH" = "on" ]; then
  # Kill switch. add+delete+create in one file is one atomic transaction and
  # is idempotent across restarts without touching other tables (the engine
  # installs its own DNAT rules for the embedded DNS resolver in this
  # namespace — never flush the whole ruleset). The embedded-DNS drop lives
  # at raw priority so it matches the original destination before that DNAT
  # rewrites the port.
  cat >/tmp/killswitch.nft <<EOF
add table inet vpn_killswitch
delete table inet vpn_killswitch
table inet vpn_killswitch {
  set fwd_port {
    type inet_service
  }

  chain raw_output {
    type filter hook output priority raw; policy accept;
EOF

  if [ -n "$EMBEDDED_DNS" ]; then
    cat >>/tmp/killswitch.nft <<EOF
    ip daddr $EMBEDDED_DNS udp dport 53 drop
    ip daddr $EMBEDDED_DNS tcp dport 53 drop
EOF
  fi

  cat >>/tmp/killswitch.nft <<EOF
  }

  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    meta nfproto ipv6 drop
    ct state established,related accept
EOF

  # Service ports reachable from each connected bridge subnet, on its own
  # interface only.
  printf '%s\n' "$BRIDGE_ROUTES" | while read -r br_if br_subnet; do
    [ -n "$br_if" ] || continue
    if [ -n "$TCP_PORTS" ]; then
      printf '    iifname "%s" ip saddr %s tcp dport { %s } accept\n' "$br_if" "$br_subnet" "$TCP_PORTS" >>/tmp/killswitch.nft
    fi
    if [ -n "$UDP_PORTS" ]; then
      printf '    iifname "%s" ip saddr %s udp dport { %s } accept\n' "$br_if" "$br_subnet" "$UDP_PORTS" >>/tmp/killswitch.nft
    fi
    printf '    iifname "%s" ip saddr %s ip protocol icmp accept\n' "$br_if" "$br_subnet" >>/tmp/killswitch.nft
  done

  cat >>/tmp/killswitch.nft <<EOF
    iifname "$VPN_INTERFACE" tcp dport @fwd_port accept
    iifname "$VPN_INTERFACE" udp dport @fwd_port accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
  }

  chain output {
    type filter hook output priority 0; policy drop;
    oif "lo" accept
    meta nfproto ipv6 drop
    ct state established,related accept
    oifname "$WAN_IF" meta skuid $WG_UID ip daddr $VPN_ENDPOINT_IP udp dport $VPN_ENDPOINT_PORT accept
    oifname "$VPN_INTERFACE" ip daddr != 127.0.0.0/8 accept
  }
}
EOF

  nft -f /tmp/killswitch.nft
else
  cat >&2 <<'EOF'
##############################################################################
#                                                                            #
#   WARNING: KILLSWITCH=off — THE FIREWALL KILL SWITCH IS NOT INSTALLED      #
#                                                                            #
#   Traffic is only tunnel-bound by ROUTING. If the tunnel interface or      #
#   its routes are altered, traffic CAN leak to the local networks or the    #
#   WAN. This mode exists for debugging and as the leak-test positive        #
#   control. Do not run real workloads with the kill switch off.            #
#                                                                            #
##############################################################################
EOF
fi

# Tunnel DNS for this container; services sharing the namespace should write
# their own copy (each container has its own /etc/resolv.conf mount).
printf 'nameserver %s\n' "$VPN_DNS" >/etc/resolv.conf

# Build the `wg setconf` config: keep key material, strip wg-quick-only keys
# (Address/DNS/MTU/Table/PostUp/PostDown), and pin the endpoint to the
# env-provided address so no DNS is needed during setup.
SETCONF="/tmp/wg-setconf.conf"
awk -v ep="${VPN_ENDPOINT_IP}:${VPN_ENDPOINT_PORT}" '
  /^\[/ { section = $0; print; next }
  section == "[Interface]" {
    if ($0 ~ /^(PrivateKey|ListenPort)[ \t]*=/) print
    next
  }
  /^Endpoint[ \t]*=/ { print "Endpoint = " ep; next }
  { print }
' "$WG_CONFIG" >"$SETCONF"
chmod 600 "$SETCONF"
grep -q '^Endpoint' "$SETCONF" || printf 'Endpoint = %s:%s\n' "$VPN_ENDPOINT_IP" "$VPN_ENDPOINT_PORT" >>"$SETCONF"

ADDRESSES="$(awk -F= '/^Address[ \t]*=/ { print $2 }' "$WG_CONFIG" | tr ',' '\n' | tr -d ' \t' | grep -v ':' || true)"
[ -n "$ADDRESSES" ] || fail "no IPv4 Address found in $WG_CONFIG"
MTU="$(awk -F= '/^MTU[ \t]*=/ { gsub(/[ \t]/, "", $2); print $2; exit }' "$WG_CONFIG")"
MTU="${MTU:-1420}"

# Start the unprivileged tunnel daemon: tun-helper opens /dev/net/tun,
# creates the interface, drops to $WG_USER, and execs wireguard-go with the
# inherited fd. The UAPI socket it creates is what `wg` talks to.
mkdir -p /var/run/wireguard
chown "$WG_USER:$WG_USER" /var/run/wireguard
chmod 700 /var/run/wireguard

start_tunnel() {
  rm -f "/var/run/wireguard/${VPN_INTERFACE}.sock"

  tun-helper "$VPN_INTERFACE" "$WG_USER" wireguard-go "$VPN_INTERFACE" &
  WG_PID=$!

  i=0
  while [ ! -S "/var/run/wireguard/${VPN_INTERFACE}.sock" ]; do
    kill -0 "$WG_PID" 2>/dev/null || return 1
    i=$((i + 1))
    [ "$i" -le 50 ] || return 1
    sleep 0.2
  done

  wg setconf "$VPN_INTERFACE" "$SETCONF" || return 1

  for addr in $ADDRESSES; do
    ip -4 addr replace "$addr" dev "$VPN_INTERFACE" || return 1
  done
  ip link set up dev "$VPN_INTERFACE" mtu "$MTU" || return 1

  # Host route for the daemon's encrypted UDP: once the default route points
  # into the tunnel, the endpoint must stay reachable via the WAN interface
  # or WireGuard would route its own packets into itself.
  if ip -4 route get "$VPN_ENDPOINT_IP" 2>/dev/null | grep -q ' via '; then
    ip route replace "$VPN_ENDPOINT_IP" via "$GATEWAY" dev "$WAN_IF" || return 1
  else
    ip route replace "$VPN_ENDPOINT_IP" dev "$WAN_IF" || return 1
  fi
  ip route replace default dev "$VPN_INTERFACE" || return 1
}

start_tunnel || fail "initial tunnel setup failed"

TP_PID=""
if [ "$VPN_HTTP_PROXY" = "on" ]; then
  cat >/tmp/tinyproxy.conf <<EOF
User tinyproxy
Group tinyproxy
Port $VPN_HTTP_PROXY_PORT
Listen 0.0.0.0
Timeout 600
MaxClients 32
Allow 0.0.0.0/0
LogLevel Warning
EOF
  tinyproxy -d -c /tmp/tinyproxy.conf &
  TP_PID=$!
fi

PS_PID=""
if [ "$PORT_FORWARD_MODE" != "off" ]; then
  export PORT_FORWARD_MODE FORWARDED_PORT
  export FORWARDED_PORT_FILE="${FORWARDED_PORT_FILE:-/etc/wireguard/forwarded_port}"
  export NATPMP_GATEWAY="${NATPMP_GATEWAY:-10.2.0.1}"
  export NATPMP_REQUEST_PORTS="${NATPMP_REQUEST_PORTS:-1 0}"
  export NATPMP_RENEW_SECONDS="${NATPMP_RENEW_SECONDS:-45}"
  export PORT_FORWARD_HOOK="${PORT_FORWARD_HOOK:-}"
  portsync &
  PS_PID=$!
fi

echo "vpn-entrypoint: tunnel up ($VPN_INTERFACE via ${VPN_ENDPOINT_IP}:${VPN_ENDPOINT_PORT}, wireguard-go uid $WG_UID, killswitch $KILLSWITCH, port-forward $PORT_FORWARD_MODE, http-proxy $VPN_HTTP_PROXY)"

# Never flush the ruleset on shutdown: services may still be running in this
# namespace and must stay sealed.
term() {
  kill $WG_PID $TP_PID $PS_PID 2>/dev/null || true
  exit 0
}
trap term INT TERM

# Supervise the daemon and respawn it in place. The container must not exit:
# a container restart would create a fresh network namespace and orphan the
# services joined to this one. While the tunnel is down the namespace stays
# sealed by the ruleset, and the healthcheck reports unhealthy.
while :; do
  wait "$WG_PID" || true
  echo "vpn-entrypoint: wireguard-go exited; respawning in place (namespace stays sealed)" >&2
  sleep 2
  while ! start_tunnel; do
    kill "$WG_PID" 2>/dev/null || true
    echo "vpn-entrypoint: tunnel respawn failed; retrying" >&2
    sleep 5
  done
  echo "vpn-entrypoint: tunnel restored" >&2
done
