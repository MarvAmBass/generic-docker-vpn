# The kill switch, rule by rule

This document walks through the `vpn_killswitch` nftables table the gateway
installs, why each rule exists, and what happens in every failure mode. The
ruleset lives in the network namespace, which means two load-bearing facts:

1. It applies to **every** container that joins via
   `network_mode: "service:vpn"` — the jail is the namespace, not any
   process.
2. It **outlives the process that installed it.** Firewall state belongs to
   the namespace; a crashed entrypoint, a killed daemon, even a dying
   gateway container leaves the rules standing.

## Ordering is the guarantee

The entrypoint's sequence is deliberate:

```
1. discover network facts   (WAN interface, bridge subnets, embedded DNS)
2. install the ruleset      (one atomic nft transaction, policy drop)
3. write namespace DNS      (VPN_DNS, reached only through the tunnel)
4. create the TUN device    (as root), pre-set MTU
5. drop privileges          (dedicated user, uid 833, no capabilities)
6. exec wireguard-go        (inherits the TUN fd — nothing else)
7. configure tunnel + routes, then supervise
```

The firewall exists **before any tunnel process does** — there is no
pre-firewall window. And the process parsing hostile bytes from the
Internet spends its life without a single capability: it cannot alter the
firewall it lives behind, and the only WAN destination its uid may reach is
the endpoint it already talks to.

The ruleset is applied with an `add table` / `delete table` / redefine
pattern in a single transaction — atomic and idempotent, and it never
touches other tables. In particular it must **not** flush the ruleset
wholesale: Docker installs DNAT rules for its embedded DNS in this
namespace, and destroying them breaks name resolution in surprising ways.

## The four chains

### `raw_output` — the DNS leak nobody expects

```
chain raw_output {
  type filter hook output priority raw; policy accept;
  ip daddr <embedded-dns> udp dport 53 drop
  ip daddr <embedded-dns> tcp dport 53 drop
}
```

Docker's embedded resolver answers *inside* the namespace, but forwards
external queries from the **host's** network stack — outside your tunnel.
Every hostname a jailed app resolves through it would leak to your ISP-side
resolver. So it is blocked — and the block sits at **raw priority (-300)**
for a subtle reason: Docker rewrites the resolver's port 53 with a DNAT rule
at dstnat priority (-100). A drop in the normal filter chain (priority 0)
runs *after* that rewrite and never matches `dport 53`. Raw runs first and
sees the original destination.

The resolver's address is discovered from `/etc/resolv.conf` at runtime,
never hardcoded — it is an engine-provided detail, not a constant.

### `input` — who may talk *to* the namespace

```
chain input {
  type filter hook input priority 0; policy drop;
  iif "lo" accept
  meta nfproto ipv6 drop
  ct state established,related accept
  iifname <bridge> ip saddr <that bridge's subnet> tcp dport { VPN_ACCEPT_TCP } accept   # per bridge
  iifname <bridge> ip saddr <that bridge's subnet> udp dport { VPN_ACCEPT_UDP } accept   # per bridge
  iifname <bridge> ip protocol icmp accept                                               # per bridge
  iifname "wg0" tcp dport @fwd_port accept
  iifname "wg0" udp dport @fwd_port accept
}
```

The per-bridge rules are **generated at runtime**, one pair per connected
Docker network, each scoped to that bridge's own subnet — attach the gateway
to one network or five, the rules follow. From the tunnel side, only the
provider-forwarded port (a dynamic set, kept current by the port-forward
sync) is admitted; there is no blanket accept from the VPN — your jailed
service's ports are not exposed to the provider's network or its other
customers.

### `forward` — nothing

```
chain forward { type filter hook forward priority 0; policy drop; }
```

The namespace routes for itself, never for others.

### `output` — the heart of it

```
chain output {
  type filter hook output priority 0; policy drop;
  oif "lo" accept
  meta nfproto ipv6 drop
  ct state established,related accept
  oifname <wan-if> meta skuid <tunnel-uid> ip daddr <endpoint> udp dport <port> accept
  oifname "wg0" ip daddr != 127.0.0.0/8 accept
}
```

Two accepts carry all traffic. The first is the tunnel's ciphertext: only
the WireGuard daemon's uid, only UDP, only to your configured endpoint, only
via the WAN interface. Userspace WireGuard makes this rule *possible* — with
an in-kernel tunnel, the encrypted packets have no owning uid to match. The
second is everything else: into the tunnel. That's the entire policy — a
packet is either the tunnel itself or inside it.

There is intentionally **no** general LAN egress rule. Replies to inbound
connections (your LAN sidecar, health probes) ride `established,related`;
jailed services cannot *initiate* toward your LAN.

One supporting route matters: the endpoint gets a host route via the WAN
gateway before the default route moves into the tunnel — otherwise the
daemon's own ciphertext would route into the tunnel that carries it, a
self-swallowing loop that looks like a silent hang.

## Failure modes

| Event | Result | Recovery |
|---|---|---|
| Provider stops handshaking | Sealed — packets die inside the tunnel; healthcheck goes unhealthy | Automatic on handshake resume |
| `wireguard-go` crashes | Sealed — the TUN vanishes with its fd, the ruleset stands; the gateway **respawns the daemon in place** so the namespace (and everything joined to it) survives | Automatic, seconds |
| Gateway container killed | Sealed and dark — the namespace loses every interface; joined services reach nothing, LAN included | `docker compose up -d --force-recreate vpn <service>` |
| Tunnel link downed by hand | Sealed — no default route, and the drop policy behind it | Bring the link up or restart the gateway |
| Gateway shuts down cleanly | Rules are **left in place** on purpose — joined services may still be running and must stay sealed | — |

The healthcheck ties this together: healthy means interface up, default
route through the tunnel, ruleset present, recent handshake,
`HEALTHCHECK_URL` reachable *through* the tunnel and — the inversion that
matters — **not** reachable around it. Gate joined services on it with
`depends_on: condition: service_healthy`.

## `KILLSWITCH=off`

`off` (exact match; anything else is a fatal configuration error) skips the
nftables installation and prints a loud banner on every start. Routing is
unchanged: the default route still points into the tunnel and there is never
a WAN fallback route, so even `off` fails closed against casual leaks — it
removes the *enforcement*, not the design. Its legitimate uses are debugging
provider connectivity and honesty: run the leak suite in this mode and watch
the blocked-path checks fail. That failure is the proof that the firewall,
not routing luck, is what protects you the rest of the time.

The current mode is written to `/run/vpn/` alongside the other runtime facts
(WAN interface, gateway, bridge subnets, embedded-DNS address, endpoint,
forwarded port), so tooling and tests can always tell which regime they are
observing.
