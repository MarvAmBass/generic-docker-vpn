#!/usr/bin/env sh
# Isolated kill-switch test harness. Design rule: every "blocked" assertion
# is backed by a positive control — after removing the firewall table (and
# again with KILLSWITCH=off) the same paths must SUCCEED, proving the blocks
# were enforced by the firewall and not by routing or topology accidents.
set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$TEST_DIR"

COMPOSE="${COMPOSE:-docker compose -f "$TEST_DIR/compose.yaml"}"
VPN_INTERFACE="${VPN_INTERFACE:-wg0}"
FAKE_URL="http://10.77.20.80/"
LAN_URL="http://10.77.10.200/"
TUN_DNS="10.66.0.1"
FWD_PORT=51413
HOT_PORT=51500
KEEP_TEST_STACK="${KEEP_TEST_STACK:-0}"

pass_count=0
fail_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS %s\n' "$*"
}

fail() {
  fail_count=$((fail_count + 1))
  printf 'FAIL %s\n' "$*"
}

summary() {
  printf '\nSummary: %s passed, %s failed\n' "$pass_count" "$fail_count"
}

teardown() {
  code=$?
  trap - EXIT
  if [ "$KEEP_TEST_STACK" != "1" ]; then
    printf '\nTearing down test stack...\n'
    # shellcheck disable=SC2086
    TEST_KILLSWITCH=on $COMPOSE down --remove-orphans --rmi all >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR/runtime"
  else
    printf '\nKEEP_TEST_STACK=1, leaving stack running (NOTE: the kill switch was removed/disabled by the final phases).\n'
  fi
  summary
  exit "$code"
}

# An interrupt must never exit 0: convert INT/TERM into a definite exit code
# so the EXIT trap reports honestly.
trap 'exit 130' INT TERM
trap teardown EXIT

run_vpn() {
  # shellcheck disable=SC2086
  $COMPOSE exec -T vpn "$@"
}

run_gw() {
  # shellcheck disable=SC2086
  $COMPOSE exec -T wg-test-server "$@"
}

run_app() {
  # shellcheck disable=SC2086
  $COMPOSE exec -T app "$@"
}

wait_healthy() {
  i=0
  while [ "$i" -lt "$2" ]; do
    if [ "$(docker inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

mkdir -p "$TEST_DIR/runtime/wireguard"
cp "$TEST_DIR/fixtures/vpn-client/wg0.conf" "$TEST_DIR/runtime/wireguard/wg0.conf"

printf 'Building test images...\n'
# shellcheck disable=SC2086
if $COMPOSE build vpn app wg-test-server fake-internet >/dev/null; then
  pass "test images build"
else
  fail "test images failed to build"
  exit 1
fi

printf 'Starting gateway, fake internet, and VPN...\n'
# shellcheck disable=SC2086
if $COMPOSE up -d --force-recreate wg-test-server fake-internet vpn >/dev/null; then
  pass "gateway, fake internet, and vpn started"
else
  fail "services failed to start"
  exit 1
fi

ready=0
i=0
while [ "$i" -lt 30 ]; do
  if run_vpn curl --interface "$VPN_INTERFACE" -fsS4 --max-time 5 "$FAKE_URL" >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 2
done

if [ "$ready" -eq 1 ]; then
  pass "fake internet reachable through $VPN_INTERFACE (userspace WireGuard)"
else
  fail "tunnel never came up; aborting (dependent checks would pass vacuously)"
  # shellcheck disable=SC2086
  $COMPOSE logs vpn 2>/dev/null | tail -n 40
  exit 1
fi

wg_user="$(run_vpn ps -o user,comm 2>/dev/null | awk '$2 == "wireguard-go" { print $1; exit }')"
if [ -n "$wg_user" ] && [ "$wg_user" != "root" ]; then
  pass "wireguard-go runs unprivileged (user: $wg_user)"
else
  fail "wireguard-go is not running unprivileged (user: ${wg_user:-not found})"
fi

# curl-by-hostname exercises the container's resolv.conf ($TUN_DNS through
# the tunnel); busybox nslookup is unsuitable here (its AAAA probe gets
# REFUSED by the test dnsmasq and flips the exit code).
if run_vpn curl -fsS4 --max-time 5 http://fake.test/ 2>/dev/null | grep -q fake-internet-ok; then
  pass "DNS through the tunnel works (resolved fake.test via $TUN_DNS)"
else
  fail "DNS through the tunnel failed"
fi

# --- Block assertions (positive controls run at the end of the suite) ---

if run_vpn curl --interface eth0 -fsS4 --max-time 5 "$FAKE_URL" >/dev/null 2>&1; then
  fail "fake internet reachable via eth0 bypass"
else
  pass "eth0 bypass is blocked"
fi

# On-link target: the connected route exists, so ONLY the firewall can block.
derived_ep="$(run_vpn cat /run/vpn/endpoint_ip 2>/dev/null | tr -d '\r\n')"
if [ "$derived_ep" = "10.77.10.200" ]; then
  pass "endpoint derived from wg0.conf Endpoint= (no env vars required)"
else
  fail "endpoint not derived from wg0.conf (got: '$derived_ep')"
fi

if run_vpn curl -fsS4 --max-time 5 "$LAN_URL" >/dev/null 2>&1; then
  fail "LAN on-link target reachable (firewall not enforcing egress)"
else
  pass "LAN on-link egress is blocked by the firewall"
fi

EMBEDDED_DNS="$(run_vpn cat /run/vpn/embedded_dns 2>/dev/null | tr -d '\r\n')"
if [ -n "$EMBEDDED_DNS" ]; then
  if run_vpn nslookup wg-test-server "$EMBEDDED_DNS" >/dev/null 2>&1; then
    fail "embedded DNS resolver ($EMBEDDED_DNS) reachable (host-side DNS leak)"
  else
    pass "embedded DNS resolver ($EMBEDDED_DNS) is blocked"
  fi
else
  fail "could not read embedded DNS address from /run/vpn/embedded_dns"
fi

# --- Tunnel-down window: the ruleset must survive link-down ---

printf 'Lowering %s...\n' "$VPN_INTERFACE"
if run_vpn ip link set "$VPN_INTERFACE" down; then
  sleep 2

  if run_vpn curl -fsS4 --max-time 5 "$FAKE_URL" >/dev/null 2>&1; then
    fail "fake internet still reachable with $VPN_INTERFACE down"
  else
    pass "fake internet unreachable with $VPN_INTERFACE down"
  fi

  # Route-independent: connected route to the LAN target still exists while
  # wg0 is down, so this proves the RULESET survives link-down (not routing).
  if run_vpn curl -fsS4 --max-time 5 "$LAN_URL" >/dev/null 2>&1; then
    fail "LAN on-link target reachable during tunnel-down (ruleset gone?)"
  else
    pass "kill switch still enforced during tunnel-down (on-link check)"
  fi

  if run_vpn curl --interface eth0 -fsS4 --max-time 5 "$FAKE_URL" >/dev/null 2>&1; then
    fail "eth0 bypass works with $VPN_INTERFACE down"
  else
    pass "eth0 bypass remains blocked with $VPN_INTERFACE down"
  fi

  if run_vpn ip link set "$VPN_INTERFACE" up >/dev/null 2>&1 &&
     run_vpn ip route replace default dev "$VPN_INTERFACE" >/dev/null 2>&1; then
    pass "restored $VPN_INTERFACE and default route"
  else
    fail "could not restore $VPN_INTERFACE and default route"
  fi
else
  fail "could not bring $VPN_INTERFACE down"
fi

# --- Jailed service + inbound accept (VPN_ACCEPT_TCP) ---

# The link-down window accrues healthcheck failures; wait for the vpn to be
# healthy again before starting the health-gated app.
if wait_healthy vpnks-vpn 45; then
  pass "vpn returns to healthy after the link-down window"
else
  fail "vpn did not return to healthy after the link-down window"
fi

# shellcheck disable=SC2086
if $COMPOSE up -d app >/dev/null; then
  pass "jailed app started in the VPN namespace"
else
  fail "jailed app failed to start"
fi

mode="$(docker inspect vpnks-app --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)"
case "$mode" in
  service:vpn|container:*) pass "app shares the VPN network namespace: $mode" ;;
  *) fail "app does not share the VPN namespace: $mode" ;;
esac

VPN_IP="$(docker inspect vpnks-vpn --format '{{(index .NetworkSettings.Networks "vpnks-lan").IPAddress}}' 2>/dev/null)"
reach=0
i=0
while [ "$i" -lt 15 ]; do
  if run_gw curl -fsS --max-time 5 "http://$VPN_IP:8080/" 2>/dev/null | grep -q jailed-app-ok; then
    reach=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ "$reach" -eq 1 ]; then
  pass "VPN_ACCEPT_TCP admits the app port from the bridge subnet"
else
  fail "app port not reachable from the bridge (VPN_ACCEPT_TCP broken?)"
fi

# --- Port forwarding: static apply, hook contract, file hot-reload ---

synced=0
i=0
while [ "$i" -lt 30 ]; do
  if [ "$(run_vpn cat /run/vpn/forwarded_port 2>/dev/null | tr -d '\r\n')" = "$FWD_PORT" ] &&
     run_vpn nft list table inet vpn_killswitch 2>/dev/null | grep -q "$FWD_PORT" &&
     [ "$(run_vpn cat /tmp/hook-port 2>/dev/null | tr -d '\r\n')" = "$FWD_PORT" ]; then
    synced=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ "$synced" -eq 1 ]; then
  pass "static forwarded port $FWD_PORT applied (facts + firewall + hook)"
else
  fail "static forwarded port $FWD_PORT not applied everywhere"
fi

printf '%s\n' "$HOT_PORT" >"$TEST_DIR/runtime/wireguard/forwarded_port"
hot=0
i=0
while [ "$i" -lt 30 ]; do
  if [ "$(run_vpn cat /run/vpn/forwarded_port 2>/dev/null | tr -d '\r\n')" = "$HOT_PORT" ] &&
     run_vpn nft list table inet vpn_killswitch 2>/dev/null | grep -q "$HOT_PORT" &&
     [ "$(run_vpn cat /tmp/hook-port 2>/dev/null | tr -d '\r\n')" = "$HOT_PORT" ]; then
    hot=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ "$hot" -eq 1 ]; then
  pass "forwarded port hot-reloaded from config file ($FWD_PORT -> $HOT_PORT, no restart)"
else
  fail "forwarded port did not hot-reload from config file"
fi

# --- Daemon death: must self-heal in place (namespace stays stable) ---

started_before="$(docker inspect vpnks-vpn --format '{{.State.StartedAt}}' 2>/dev/null)"
if run_vpn pkill -x wireguard-go >/dev/null 2>&1; then
  healed=0
  i=0
  while [ "$i" -lt 30 ]; do
    if run_vpn curl --interface "$VPN_INTERFACE" -fsS4 --max-time 3 "$FAKE_URL" >/dev/null 2>&1; then
      healed=1
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  started_after="$(docker inspect vpnks-vpn --format '{{.State.StartedAt}}' 2>/dev/null)"
  if [ "$healed" -eq 1 ] && [ "$started_before" = "$started_after" ]; then
    pass "tunnel self-healed in place after daemon kill (container did not restart)"
  elif [ "$healed" -eq 1 ]; then
    fail "tunnel recovered but the container restarted (dependents would be orphaned)"
  else
    fail "tunnel did not recover after daemon kill"
  fi
else
  fail "could not kill wireguard-go"
fi

# --- Container death: namespace must go fully dark, then recover ---

if docker kill vpnks-vpn >/dev/null 2>&1; then
  sleep 2
  if run_app wget -T 4 -qO- "$FAKE_URL" >/dev/null 2>&1; then
    fail "app reached the fake internet while the vpn container is dead"
  else
    pass "app egress is dead while the vpn container is killed"
  fi
  if run_app wget -T 4 -qO- "$LAN_URL" >/dev/null 2>&1; then
    fail "app reached the LAN while the vpn container is dead"
  else
    pass "app cannot even reach the LAN while the vpn container is killed"
  fi

  # Documented recovery: restart the gateway container, recreate the joiner
  # once the gateway is healthy again.
  # shellcheck disable=SC2086
  if $COMPOSE stop app >/dev/null 2>&1 &&
     $COMPOSE up -d vpn >/dev/null 2>&1 &&
     wait_healthy vpnks-vpn 45 &&
     $COMPOSE up -d --force-recreate app >/dev/null 2>&1; then
    recovered=0
    i=0
    while [ "$i" -lt 45 ]; do
      if run_app wget -T 3 -qO- "$FAKE_URL" >/dev/null 2>&1; then
        recovered=1
        break
      fi
      i=$((i + 1))
      sleep 2
    done
    if [ "$recovered" -eq 1 ]; then
      pass "stack recovered after vpn restart + app recreate (egress via tunnel again)"
    else
      fail "app egress did not recover after vpn restart + recreate"
    fi
  else
    fail "could not restart vpn / recreate app after container kill"
  fi
else
  fail "could not kill the vpn container"
fi

# --- Positive controls: remove the firewall, blocked paths must now succeed ---

if run_vpn nft delete table inet vpn_killswitch >/dev/null 2>&1; then
  if run_vpn curl -fsS4 --max-time 5 "$LAN_URL" >/dev/null 2>&1; then
    pass "positive control: LAN on-link target reachable once firewall removed"
  else
    fail "positive control failed: LAN target unreachable even without firewall (block was vacuous)"
  fi
  if [ -n "$EMBEDDED_DNS" ]; then
    if run_vpn nslookup wg-test-server "$EMBEDDED_DNS" >/dev/null 2>&1; then
      pass "positive control: embedded DNS answers once firewall removed"
    else
      fail "positive control failed: embedded DNS dead even without firewall (block was vacuous)"
    fi
  fi
else
  fail "could not remove vpn_killswitch table for positive controls"
fi

# --- KILLSWITCH=off: the living positive control / leak demo ---

# shellcheck disable=SC2086
if TEST_KILLSWITCH=off $COMPOSE stop app >/dev/null 2>&1 &&
   TEST_KILLSWITCH=off $COMPOSE up -d --force-recreate vpn >/dev/null 2>&1; then
  offready=0
  i=0
  while [ "$i" -lt 30 ]; do
    if run_vpn curl --interface "$VPN_INTERFACE" -fsS4 --max-time 5 "$FAKE_URL" >/dev/null 2>&1; then
      offready=1
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  if [ "$offready" -eq 1 ]; then
    pass "KILLSWITCH=off: tunnel still comes up"
  else
    fail "KILLSWITCH=off: tunnel did not come up"
  fi

  if [ "$(run_vpn cat /run/vpn/killswitch 2>/dev/null | tr -d '\r\n')" = "off" ]; then
    pass "KILLSWITCH=off: mode fact recorded in /run/vpn/killswitch"
  else
    fail "KILLSWITCH=off: mode fact missing/incorrect"
  fi

  if run_vpn curl -fsS4 --max-time 5 "$LAN_URL" >/dev/null 2>&1; then
    pass "KILLSWITCH=off: LAN on-link target reachable (the leak the switch prevents)"
  else
    fail "KILLSWITCH=off: LAN target unreachable — earlier blocks may have been vacuous"
  fi

  if run_vpn ip route 2>/dev/null | grep -q "^default dev $VPN_INTERFACE"; then
    pass "KILLSWITCH=off: routing still tunnel-only (no WAN default-route fallback)"
  else
    fail "KILLSWITCH=off: default route is not via $VPN_INTERFACE"
  fi
else
  fail "could not recreate vpn with KILLSWITCH=off"
fi


# --- Hostname endpoint: resolved once and pinned into a writable config ---

sed 's|^Endpoint.*|Endpoint = wg-test-server:51820|' \
  "$TEST_DIR/fixtures/vpn-client/wg0.conf" >"$TEST_DIR/runtime/wireguard/wg0.conf"

# shellcheck disable=SC2086
if TEST_WG_MODE=rw $COMPOSE up -d --force-recreate vpn >/dev/null 2>&1; then
  hostready=0
  i=0
  while [ "$i" -lt 30 ]; do
    if run_vpn curl --interface "$VPN_INTERFACE" -fsS4 --max-time 5 "$FAKE_URL" >/dev/null 2>&1; then
      hostready=1
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  if [ "$hostready" -eq 1 ]; then
    pass "hostname endpoint: tunnel up after one-time resolution"
  else
    fail "hostname endpoint: tunnel did not come up"
    # shellcheck disable=SC2086
    $COMPOSE logs vpn 2>/dev/null | tail -n 15
    ls -l "$TEST_DIR/runtime/wireguard/" || true
    sed -n '1,20p' "$TEST_DIR/runtime/wireguard/wg0.conf" || true
  fi

  if grep -q '^# Endpoint = wg-test-server:51820' "$TEST_DIR/runtime/wireguard/wg0.conf" &&
     grep -q '^Endpoint = 10.77.10.200:51820' "$TEST_DIR/runtime/wireguard/wg0.conf"; then
    pass "hostname endpoint: config rewritten (hostname commented, literal IP pinned)"
  else
    fail "hostname endpoint: config was not rewritten as expected"
  fi

  if [ "$(run_vpn cat /run/vpn/endpoint_ip 2>/dev/null | tr -d '\r\n')" = "10.77.10.200" ]; then
    pass "hostname endpoint: firewall pinned to the resolved IP"
  else
    fail "hostname endpoint: endpoint fact does not match the resolved IP"
  fi
else
  fail "could not recreate vpn with a writable hostname config"
fi

# --- Hostname endpoint on a READ-ONLY config: must fail fast and loud ---

sed 's|^Endpoint.*|Endpoint = wg-test-server:51820|' \
  "$TEST_DIR/fixtures/vpn-client/wg0.conf" >"$TEST_DIR/runtime/wireguard/wg0.conf"

# shellcheck disable=SC2086
$COMPOSE up -d --force-recreate vpn >/dev/null 2>&1
sleep 4
# shellcheck disable=SC2086
if $COMPOSE logs vpn 2>/dev/null | grep -q "read-only, so the resolved endpoint cannot be pinned" &&
   $COMPOSE logs vpn 2>/dev/null | grep -q "Endpoint = 10.77.10.200:51820"; then
  pass "read-only hostname config fails fast, with the resolved IP ready to paste"
else
  fail "read-only hostname config did not fail with the expected guidance"
  # shellcheck disable=SC2086
  $COMPOSE logs vpn 2>/dev/null | tail -n 8
fi
# shellcheck disable=SC2086
$COMPOSE stop vpn >/dev/null 2>&1 || true

[ "$fail_count" -eq 0 ] || exit 1
