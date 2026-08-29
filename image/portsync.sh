#!/bin/sh
# Keeps the provider-forwarded port in sync with the firewall, the
# /run/vpn/forwarded_port fact, and an optional user hook.
#
# static: applies FORWARDED_PORT; the port can be changed at RUNTIME by
#         writing it to FORWARDED_PORT_FILE (re-read continuously, wins
#         over the env var) — no restart needed.
# natpmp: negotiates the port via NAT-PMP (e.g. against a provider gateway),
#         renews the lease, and follows port changes at runtime.
#
# On every applied change the optional PORT_FORWARD_HOOK is executed with the
# port as $1 (it runs inside this container, which shares the network
# namespace with your services — localhost APIs of sibling containers are
# reachable). In static mode the hook is quietly re-asserted each cycle so a
# recreated sibling picks the port back up.
set -u

MODE="${PORT_FORWARD_MODE:-off}"
STATIC_PORT="${FORWARDED_PORT:-}"
PORT_FILE="${FORWARDED_PORT_FILE:-/etc/wireguard/forwarded_port}"
NATPMP_GATEWAY="${NATPMP_GATEWAY:-10.2.0.1}"
REQUEST_PORTS="${NATPMP_REQUEST_PORTS:-1 0}"
RENEW_SECONDS="${NATPMP_RENEW_SECONDS:-45}"
HOOK="${PORT_FORWARD_HOOK:-}"
KILLSWITCH_STATE="$(cat /run/vpn/killswitch 2>/dev/null || echo on)"

log() {
  echo "vpn-portsync: $*" >&2
}

[ "$MODE" = "off" ] && exit 0

run_hook() {
  hport="$1"
  [ -n "$HOOK" ] || return 0
  if [ -x "$HOOK" ]; then
    if "$HOOK" "$hport"; then
      return 0
    fi
    log "hook $HOOK failed for port $hport"
    return 1
  fi
  log "PORT_FORWARD_HOOK '$HOOK' is missing or not executable"
  return 1
}

# Returns 0 when firewall, fact file and hook all applied; 1 on firewall
# failure; 2 when only the hook failed (retried by the caller).
apply_port() {
  port="$1"
  if [ "$KILLSWITCH_STATE" = "on" ]; then
    nft flush set inet vpn_killswitch fwd_port 2>/dev/null || return 1
    nft add element inet vpn_killswitch fwd_port "{ $port }" 2>/dev/null || return 1
  fi
  printf '%s\n' "$port" >/run/vpn/forwarded_port
  if run_hook "$port"; then
    log "forwarded port $port applied"
    return 0
  fi
  return 2
}

case "$MODE" in
  static)
    current=""
    while :; do
      port="$STATIC_PORT"
      if [ -r "$PORT_FILE" ]; then
        file_port="$(tr -cd '0-9' <"$PORT_FILE")"
        [ -n "$file_port" ] && port="$file_port"
      fi
      if [ -z "$port" ]; then
        log "static mode: no port configured (set FORWARDED_PORT or write $PORT_FILE)"
        sleep 30
        continue
      fi
      if [ "$port" != "$current" ]; then
        apply_port "$port"
        [ "$?" -eq 0 ] && current="$port"
        sleep 5
      else
        # Re-assert quietly each cycle: a recreated sibling service would
        # otherwise keep a stale port until the next change.
        run_hook "$port" >/dev/null 2>&1 || true
        sleep 15
      fi
    done
    ;;
  natpmp)
    current=""
    while :; do
      # shellcheck disable=SC2086  # REQUEST_PORTS is two natpmpc arguments
      out="$(natpmpc -g "$NATPMP_GATEWAY" -a $REQUEST_PORTS udp 60 2>/dev/null)" || {
        log "NAT-PMP request via $NATPMP_GATEWAY failed; retrying"
        sleep 10
        continue
      }
      # shellcheck disable=SC2086
      natpmpc -g "$NATPMP_GATEWAY" -a $REQUEST_PORTS tcp 60 >/dev/null 2>&1 || true
      port="$(printf '%s\n' "$out" | sed -n 's/.*Mapped public port \([0-9][0-9]*\).*/\1/p' | head -n1)"
      if [ -z "$port" ]; then
        log "could not parse NAT-PMP response"
        sleep 10
        continue
      fi
      if [ "$port" != "$current" ]; then
        apply_port "$port"
        [ "$?" -eq 0 ] && current="$port"
      fi
      sleep "$RENEW_SECONDS"
    done
    ;;
  *)
    log "unknown PORT_FORWARD_MODE: $MODE"
    exit 1
    ;;
esac
