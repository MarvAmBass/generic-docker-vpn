#!/bin/sh
# Test fixture for the PORT_FORWARD_HOOK contract: receives the forwarded
# port as $1; records it so the suite can assert the hook fired.
printf '%s\n' "$1" >/tmp/hook-port
