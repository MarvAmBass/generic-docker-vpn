# Why not gluetun?

Fair question — [gluetun](https://github.com/qdm12/gluetun) is the
established VPN gateway container, it is mature, actively maintained, and
genuinely good. If it fits you, use it; this page exists to make the choice
honest, not to win it.

## What gluetun gives you that this project never will

- **Provider integration.** Dozens of VPN providers built in — pick a name,
  supply credentials, servers are selected and rotated for you. This
  project's interface is a WireGuard config file you bring yourself, full
  stop.
- **Breadth of features.** OpenVPN as well as WireGuard, DNS-over-TLS with
  filtering, a Shadowsocks server, server-list updaters, public-IP echo, an
  HTTP control server — years of accumulated capability.
- **Maturity and community.** Enormous deployment base, fast issue
  turnaround, documentation for nearly every provider quirk.

## What this project trades all of that for

- **A surface you can actually audit.** One shell entrypoint, one ~90-line
  C helper, one small patch against the reference WireGuard implementation,
  one firewall ruleset, one sync script. Reading *everything* that stands
  between your traffic and a leak takes an afternoon. Feature breadth is the
  enemy of that property, so features lose.
- **Unprivileged packet parsing.** Here the WireGuard daemon — the process
  that spends years parsing bytes from the Internet — runs as a dedicated
  user with **no capabilities**, holding nothing but an inherited TUN file
  descriptor. It cannot modify the firewall it lives behind. Root exists for
  seconds of setup, then is gone. Gateway containers generally run their
  tunnel and control plane as root; that is a real difference in blast
  radius if the parser is ever wrong.
- **A falsifiable kill switch.** The strongest claim any gateway makes is
  "if the tunnel is down, nothing leaks" — and it is usually just that, a
  claim. This project ships an isolated leak-test suite with **positive
  controls**: after proving the blocked paths are blocked, it deletes the
  firewall and proves the same paths become reachable — so a block that only
  existed by routing or topology accident fails the suite. It also kills the
  daemon and the whole gateway container mid-run and verifies sealed
  behavior each time. This runs in CI on every commit. The kill switch is
  not asserted; it is continuously disproven-or-confirmed.
- **Bring-your-own config as a feature.** No provider abstraction means no
  provider API keys in environment variables, no server-list fetching at
  runtime, no trust in a third party's endpoint metadata — and no waiting on
  anyone when your provider changes something. Your `wg0.conf` is the whole
  contract.

## The honest decision table

| You want | Use |
|---|---|
| Pick a provider by name and go | gluetun |
| OpenVPN, DoT, Shadowsocks, server rotation | gluetun |
| The smallest reviewable thing that seals a namespace | this |
| The tunnel daemon itself running unprivileged | this |
| Leak protection you can watch being tested, not just read about | this |
| Both philosophies at once | they coexist fine — different stacks, different containers |

No benchmark charts, no scare quotes: gluetun's kill switch has served a
huge community well. The difference is philosophy — features versus
falsifiability — and you should pick the one whose failure modes you would
rather live with.
