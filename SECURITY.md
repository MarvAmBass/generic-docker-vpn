# Security

## Threat model

This project has one job: **traffic from jailed containers leaves through
the VPN tunnel or not at all.** Everything below follows from taking that
single sentence seriously.

### What it defends against

- **Traffic leaks around the tunnel.** All three filter chains default to
  drop. The only permitted WAN egress is encrypted WireGuard UDP to your
  configured endpoint, and only from the tunnel daemon's uid — no other
  process in the namespace can emit a packet toward the Internet except into
  the tunnel. The ruleset is installed atomically before any tunnel process
  exists, so there is no startup window.
- **DNS leaks — including the non-obvious one.** Docker's embedded resolver
  lives inside the namespace, but its upstream forwarding egresses from the
  *host*, outside the tunnel. Queries to it are dropped in a raw-priority
  chain, ahead of Docker's DNAT port rewrite (the address is discovered at
  runtime, never hardcoded). Namespace DNS goes to `VPN_DNS` through the
  tunnel and dies with it.
- **Tunnel failure, in every order.** Provider stops handshaking: packets
  die inside the tunnel. Daemon crashes: the TUN interface vanishes with its
  file descriptor and the gateway respawns the daemon in place — the
  namespace stays sealed throughout, and joined services never lose it.
  Gateway container killed outright: the namespace loses every interface;
  joined services can reach neither the Internet nor the LAN until
  explicitly recovered. The ruleset is deliberately never flushed on
  shutdown.
- **Compromise of the packet parser.** The process handling hostile bytes
  from the Internet — `wireguard-go` — runs as an unprivileged dedicated
  user holding nothing but an inherited TUN file descriptor. It cannot
  modify the firewall it lives behind; the only WAN destination its uid may
  reach is the endpoint it already talks to. Root is used for seconds of
  setup, then dropped.

Each of these is exercised by the leak suite in `tests/killswitch/`, with
positive controls proving the blocks are enforced by the firewall rather
than by routing or topology accidents. The suite runs in CI.

### What it does **not** defend against

- **Your VPN provider.** They see your traffic's far side, your real IP,
  and your payment trail. Choosing and trusting a provider is out of scope.
- **Host compromise.** Root on the Docker host owns every namespace,
  including this one. Container hardening here limits blast radius; it is
  not a host security boundary.
- **Deliberately enabled IPv6.** The namespace disables IPv6 via sysctls
  and drops it in the firewall. If you re-enable IPv6 on the networks or
  strip those settings, you are outside the tested configuration.
- **Traffic analysis and correlation.** Timing, volume and endpoint
  correlation by a capable observer are not addressed by any kill switch.
- **What jailed applications do over the tunnel.** The jail constrains
  *where* traffic goes, not what an application says. Logins, cookies and
  telemetry identify you regardless of exit IP.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(Security → Report a vulnerability) rather than a public issue, especially
for anything that could constitute a leak path. Include the output of the
kill-switch suite if it is relevant — a reproducing test case is the ideal
report. You can expect an acknowledgement within a few days.

Leak-class reports (any way a jailed container's traffic can reach the
network outside the tunnel while `KILLSWITCH=on`) are treated as the highest
severity this project has.
