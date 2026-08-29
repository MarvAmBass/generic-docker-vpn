# Kill-Switch Test Harness

Fully isolated: a containerized WireGuard gateway and a fake-internet target
on dedicated bridges. No VPN credentials, no real network access, no kernel
module needed on the client side (userspace WireGuard).

```bash
tests/killswitch/run-test.sh
```

Design rule: **every "blocked" assertion has a positive control.** At the end
of the run the firewall table is deleted — and the vpn is then recreated with
`KILLSWITCH=off` — and the previously blocked paths must **succeed**. If a
block was ever caused by routing or topology accidents rather than the
firewall, the suite fails.

What it proves:

```text
tunnel comes up end-to-end (userspace wireguard-go, unprivileged)
DNS through the tunnel works
eth0 bypass, LAN on-link egress, and the embedded-DNS resolver are blocked
the ruleset survives tunnel-down (route-independent on-link check inside
  the down window)
a stock, unmodified container is jailed via network_mode: service:vpn and
  reachable from the bridge only through VPN_ACCEPT_TCP
static port forwarding: firewall fact + nft rule + PORT_FORWARD_HOOK all
  agree; runtime hot-reload via the forwarded_port file (no restart)
daemon kill: tunnel self-heals in place, the container does not restart
container kill: the namespace goes fully dark (no internet, no LAN) and
  recovers via the documented restart + recreate procedure
positive controls: with the table removed, LAN target and embedded DNS
  must become reachable
KILLSWITCH=off: the leak demo — LAN target reachable, mode fact recorded,
  routing still tunnel-only
```

The committed WireGuard keys under `fixtures/` are throwaway pairs generated
for this harness only. Teardown is automatic; `KEEP_TEST_STACK=1` keeps the
stack for inspection (note: the final phases leave the kill switch removed).
