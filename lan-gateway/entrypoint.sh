#!/bin/sh
# Exposes a service running inside the VPN network namespace to the LAN.
# The jailed service has no network identity of its own, so this sidecar
# listens on the normal bridge and relays to the gateway's namespace.
set -eu

LISTEN_PORT="${LISTEN_PORT:?LISTEN_PORT is required}"
TARGET_HOST="${TARGET_HOST:-vpn}"
TARGET_PORT="${TARGET_PORT:?TARGET_PORT is required}"

echo "lan-gateway: :${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT}"
exec socat "TCP-LISTEN:${LISTEN_PORT},fork,reuseaddr" "TCP:${TARGET_HOST}:${TARGET_PORT}"
