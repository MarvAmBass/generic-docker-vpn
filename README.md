# generic-docker-vpn

[![CI](https://github.com/MarvAmBass/generic-docker-vpn/actions/workflows/ci.yml/badge.svg)](https://github.com/MarvAmBass/generic-docker-vpn/actions/workflows/ci.yml)

A kill-switched WireGuard gateway container for Docker. Put any container —
unmodified, straight from its upstream registry — inside a network namespace
whose only way to the Internet is your VPN tunnel. If the tunnel is down,
traffic stops. It never falls back to your WAN.

Three things set this project apart:

- **The kill switch is falsifiable, not claimed.** The test suite includes
  positive controls: at the end of a run it deletes the firewall and proves
  the previously blocked paths become reachable. A block that only existed by
  topology accident fails the suite. The suite runs in CI on every commit.
- **The process that parses packets from the Internet holds no privileges.**
  WireGuard runs in userspace (a pinned build of the reference
  implementation, `wireguard-go`) as a dedicated unprivileged user. Root is
  used for a few seconds of setup, then dropped. No host kernel module is
  required — this runs on any Docker host, including locked-down NAS and VPS
  kernels.
- **Small enough to actually audit.** One shell entrypoint, one ~90-line C
  helper, one small patch, one firewall ruleset. You can read all of it in an
  afternoon, and you are encouraged to.

## How it works

The gateway container installs a fail-closed nftables ruleset
(`vpn_killswitch`, default-drop on input/forward/output) **atomically, before
any tunnel process exists** — there is no pre-firewall window. It then starts
`wireguard-go` through a tiny helper that opens the TUN device as root, drops
to an unprivileged user, and hands over nothing but the file descriptor. The
only WAN egress the firewall permits is encrypted WireGuard UDP, from that
user's uid, to your provider's endpoint — nothing else in the namespace can
emit a packet toward the Internet except through the tunnel.

Other containers join the namespace with one line:

```yaml
network_mode: "service:vpn"
```

They need no changes, no special images, no cooperation. The jail is the
namespace, not the application.

## Quickstart

The flagship example jails the official [SearXNG](https://docs.searxng.org/)
metasearch image (plus its Valkey companion) and publishes it to
`127.0.0.1:8080` through a small LAN gateway that lives *outside* the jail:

```bash
git clone https://github.com/MarvAmBass/generic-docker-vpn.git
cd generic-docker-vpn
cp config/wg0.conf.example config/wg0.conf
# paste the WireGuard config from your VPN provider into config/wg0.conf,
# the endpoint is read from the config's Endpoint line automatically
# (numeric IP:PORT; set VPN_ENDPOINT_IP/PORT only to override)
docker compose up -d --build
open http://127.0.0.1:8080
```

Every search now leaves through your VPN. Kill the tunnel, the daemon, or
the whole gateway container — searches stop; they never leak.

`config/wg0.conf` is a standard WireGuard configuration, exactly as VPN
providers hand them out. There is no provider abstraction and no credentials
in environment variables: bring your own file, keep your private key in it.

## Guarantees — and the test that proves each one

| Guarantee | Proven by |
|---|---|
| No packet leaves except through the tunnel | On-link LAN target blocked while the kill switch is up — then the **positive control** deletes the firewall table and the same request must succeed |
| DNS cannot leak via Docker's embedded resolver (which forwards from the *host*, outside the tunnel) | Embedded-resolver queries blocked at raw priority — with its own positive control |
| Tunnel down means sealed, never a WAN fallback | Link-down phase: Internet, DNS and bypass attempts must all fail |
| Daemon death self-heals without breaking the namespace | The suite kills `wireguard-go` mid-run and asserts recovery **without** a container restart (a restart would orphan joined services) |
| Gateway container death leaves joined services fully dark | `docker kill` on the gateway: joined services must reach neither Internet nor LAN; recovery procedure verified end-to-end |
| The kill switch — not routing luck — is what blocks | Run the suite with `KILLSWITCH=off` and watch the leak checks fail |
| Forwarded port stays in sync everywhere | Firewall set, published fact and hook all verified, including runtime hot-reload without a restart |

Run it yourself: `tests/killswitch/run-test.sh`. It is fully isolated —
a containerized WireGuard server and a fake Internet on their own bridges;
no VPN account, no real network access needed.

## Environment reference

| Variable | Default | Meaning |
|---|---|---|
| `KILLSWITCH` | `on` | `on` or `off` (exact match). See below. |
| `VPN_ENDPOINT_IP` | *derived* | Numeric IPv4 of your provider endpoint. Optional: derived from the `Endpoint` line in `wg0.conf`; set to override. Hostname endpoints are rejected either way (no DNS outside the tunnel) |
| `VPN_ENDPOINT_PORT` | *derived* | Endpoint UDP port (same derivation/override rules) |
| `VPN_INTERFACE` | `wg0` | Tunnel interface / config file name (`/etc/wireguard/<name>.conf`) |
| `VPN_DNS` | `1.1.1.1` | Resolver used inside the namespace, reached through the tunnel |
| `VPN_ACCEPT_TCP` | empty | Comma-separated TCP ports accepted inbound on each bridge, from that bridge's own subnet only |
| `VPN_ACCEPT_UDP` | empty | Same, for UDP |
| `VPN_HTTP_PROXY` | `off` | `on` starts a small HTTP proxy inside the namespace — tunnel-only egress for services *outside* the jail |
| `VPN_HTTP_PROXY_PORT` | `8888` | Proxy port (included in the inbound accept list automatically) |
| `PORT_FORWARD_MODE` | `off` | `off`, `static` or `natpmp` |
| `FORWARDED_PORT` | empty | The provider-forwarded port (static mode) |
| `FORWARDED_PORT_FILE` | `/etc/wireguard/forwarded_port` | Write a new port number here at runtime — picked up within seconds, no restart; wins over the env var |
| `NATPMP_GATEWAY` | `10.2.0.1` | NAT-PMP gateway inside the tunnel |
| `NATPMP_REQUEST_PORTS` | `"1 0"` | `natpmpc` public/private request form; spec-strict gateways want `"0 <port>"` |
| `PORT_FORWARD_HOOK` | empty | Path to a mounted script, invoked with the current port as `$1` on every change |
| `HEALTHCHECK_URL` | `https://1.1.1.1` | Fetched through the tunnel (must succeed) and around it (must fail) |

Runtime facts are exposed under `/run/vpn/` inside the gateway (WAN
interface, gateway, bridge subnets, embedded-DNS address, endpoint,
forwarded port, kill-switch state) — useful for scripts, tests and debugging.

## The kill switch

`KILLSWITCH=on` (the default) is the entire point of this project: a
default-drop ruleset installed before the tunnel exists, owned by the
namespace, surviving daemon crashes and deliberately **not** flushed on
shutdown — a dying gateway leaves joined services sealed, not exposed.
Rule-by-rule walkthrough: [docs/killswitch.md](docs/killswitch.md).

`KILLSWITCH=off` exists for two honest reasons: debugging provider
connectivity, and demonstrating that the firewall is load-bearing — it is
the documented way to watch the leak tests fail. Even `off` keeps routing
tunnel-only (there is never a WAN default route); it removes the rule
enforcement, not the design. The container prints a loud warning on every
start in this mode.

## Port forwarding

For providers that forward an inbound port to you (needed by anything that
accepts connections from the Internet):

- **`static`** — set `FORWARDED_PORT`. To change it at runtime, write the
  new number to `config/forwarded_port` (mounted as
  `FORWARDED_PORT_FILE`) — firewall and hook follow within seconds, no
  restart.
- **`natpmp`** — for providers that assign ports dynamically over NAT-PMP:
  the mapping is negotiated through the tunnel, renewed continuously, and
  port changes are followed automatically.

In both modes the firewall opens the port on the tunnel side only, and your
optional `PORT_FORWARD_HOOK` script is called with the port as `$1` — it
runs inside the shared namespace, so it can reconfigure a jailed service
over `localhost`. Details: [docs/port-forwarding.md](docs/port-forwarding.md).

## Exposing a jailed service to your LAN

The jail seals the service off from everything — including you. The pattern
for access is a deliberately tiny sidecar *outside* the namespace that
forwards a published port to the gateway's service port:

```
LAN ──▶ lan-gateway (publishes 127.0.0.1:8080) ──▶ vpn:8080 ──▶ jailed service
```

`lan-gateway/` is a self-built alpine+socat image of a few lines. It is the
only published entry point; the jailed service itself publishes nothing.
Remember to allow the service port via `VPN_ACCEPT_TCP` so the gateway's
input chain admits the sidecar's connections. For anything beyond localhost
use, put authentication in front (a reverse proxy with basic auth slots into
the same position).

## Jailing your own service

```yaml
services:
  vpn:
    build: ./image        # or: image: ghcr.io/marvambass/generic-docker-vpn
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    sysctls:
      net.ipv6.conf.all.disable_ipv6: "1"
      net.ipv6.conf.default.disable_ipv6: "1"
    volumes:
      - ./config:/etc/wireguard:ro
    environment:
      # endpoint derived from wg0.conf; set VPN_ENDPOINT_IP/PORT to override
      VPN_ACCEPT_TCP: "8080"
    healthcheck:
      test: ["CMD", "/usr/local/bin/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    restart: unless-stopped

  your-service:
    image: any/stock-image
    network_mode: "service:vpn"
    depends_on:
      vpn:
        condition: service_healthy
```

`NET_ADMIN` and the TUN device are required for setup; the WireGuard daemon
itself runs with neither. Note the healthcheck: joined services gate on it,
so they only start once the tunnel is verified up **and** the bypass
verified down.

**Recovery note:** if the gateway *container* is recreated (image update,
compose change), Docker gives it a fresh namespace and joined services must
be recreated too:

```bash
docker compose up -d --force-recreate vpn your-service
```

Daemon crashes don't need this — the gateway respawns `wireguard-go` in
place precisely so the namespace, and everything joined to it, survives.

## Honest caveats

- **Docker only.** Podman's embedded DNS, compose interop and rootless
  network stack differ in ways this project does not test for.
- **IPv6 is disabled by design** inside the namespace (sysctls + firewall).
  If you need IPv6 through your VPN, this project is not for you today.
- **VPN exit IPs are shared and well-known.** Some sites and search engines
  throttle or captcha them. That is your provider's reputation at work, not
  a malfunction — the SearXNG example documents which knobs help.
- **Bring your own `wg0.conf`.** There is no provider API integration and
  none is planned; a standard WireGuard config is the interface.

## Tests

`tests/killswitch/` — the isolated leak suite described above (also the CI
gate). It tears itself down and needs nothing but Docker. An isolated
NAT-PMP integration harness (real NAT-PMP daemon on a containerized
gateway, with lease-renewal proof) is planned.

## License

[MIT](LICENSE) © 2026 MarvAmBass
