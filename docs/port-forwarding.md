# Port forwarding

Anything that accepts connections from the Internet — peer-to-peer
software, self-hosted services reachable via the VPN — needs the provider
to forward an inbound port to your tunnel. The gateway keeps three things in
agreement about that port, continuously and without restarts:

1. the **firewall**: the tunnel-side input rules admit exactly the ports in
   a dynamic nftables set (`@fwd_port`) — nothing else from the VPN side;
2. the **published fact**: the current port is written to
   `/run/vpn/forwarded_port`;
3. your **hook**: an optional script you mount, invoked on every change.

Select the behavior with `PORT_FORWARD_MODE`:

## `off` (default)

No inbound port. The tunnel-side set stays empty; the jail is egress-only.

## `static`

Your provider assigned you a fixed port. Set it once:

```yaml
environment:
  PORT_FORWARD_MODE: static
  FORWARDED_PORT: "51423"
```

**Runtime changes without a restart:** the sync daemon continuously re-reads
`FORWARDED_PORT_FILE` (default `/etc/wireguard/forwarded_port`, i.e. a file
named `forwarded_port` next to your `wg0.conf` in the mounted config
directory). Write a new number there and the firewall set, the published
fact and your hook follow within seconds. The file, when present, wins over
the environment variable — the env var is the initial/fallback value.

```bash
echo 51999 > config/forwarded_port     # picked up live
```

## `natpmp`

For providers that assign forwarded ports dynamically over NAT-PMP. The
gateway negotiates the mapping **through the tunnel** with
`NATPMP_GATEWAY` (default `10.2.0.1`), maps both UDP and TCP, renews well
inside the lease lifetime, and follows provider-side port changes
automatically — the firewall and your hook track every change.

`NATPMP_REQUEST_PORTS` controls the request's public/private port pair as
passed to `natpmpc -a`:

- `"1 0"` (default) — the form widely used with providers whose gateway
  ignores the requested values and assigns both sides itself;
- `"0 <port>"` — for spec-strict NAT-PMP daemons (miniupnpd, for example)
  that reject a private port of 0: request "any public port" mapped to a
  real private port.

If the mapping ever lapses (provider outage, gateway restart), the sync
daemon keeps retrying; the firewall set simply reflects whatever is
currently granted.

## The hook contract

Most software that listens on a forwarded port needs to be *told* the port.
Mount a script and point `PORT_FORWARD_HOOK` at it:

```yaml
environment:
  PORT_FORWARD_MODE: natpmp
  PORT_FORWARD_HOOK: /hooks/apply-port.sh
volumes:
  - ./apply-port.sh:/hooks/apply-port.sh:ro
```

The contract, in full:

- called with the current port as **`$1`**, once at startup (as soon as a
  port is known) and again on every change;
- runs as root **inside the gateway container**, which shares its network
  namespace with your jailed services — so `127.0.0.1` reaches *their*
  localhost APIs directly;
- a non-zero exit is logged and retried on the next sync cycle; the
  firewall set is updated regardless (the firewall never waits on your
  application).

A typical hook updates a jailed service's listen port over its local API:

```sh
#!/bin/sh
# apply-port.sh — push the forwarded port into the jailed service
set -eu
curl -fsS --max-time 5 \
  --data "{\"listen_port\": $1}" \
  http://127.0.0.1:9000/api/settings
```

A template hook documenting the contract lives in `examples/hooks/`.

## Verifying

```bash
docker compose exec vpn cat /run/vpn/forwarded_port
docker compose exec vpn nft list set inet vpn_killswitch fwd_port
```

An isolated NAT-PMP integration harness (a real NAT-PMP daemon on a
containerized WireGuard gateway, with proof that the mapping survives a
full lease period only because renewal is happening) is planned; today,
verify with the commands above.
