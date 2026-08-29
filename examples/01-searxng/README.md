# Example 01 — SearXNG, jailed

This example **is** the repo's root [`compose.yml`](../../compose.yml) — it is
kept there as the quickstart so there is exactly one copy to maintain.

Why SearXNG is the flagship example: it's a service you *want* jailed away
from your own network — a privacy metasearch engine whose outbound queries
should leave only through the VPN, and whose UI should be reachable only from
your LAN. And it demonstrates the core claim of this repo: the jailed
containers (`searxng/searxng`, `valkey/valkey`) are **unmodified official
upstream images**. The jail is purely the gateway's network namespace and its
fail-closed firewall.

```text
LAN ── lan-gateway ──> [ vpn namespace: searxng + valkey + wireguard-go ] ──> tunnel ──> Internet
                        no other path in, no other path out
```

## Run it

```bash
cp config/wg0.conf.example config/wg0.conf   # replace with your provider's config
cp .env.example .env                         # set endpoint + secret
docker compose up -d
open http://127.0.0.1:8080
```

Expected: search works, and the results come from the VPN exit IP. Some
engines throttle or captcha VPN addresses — that's the Internet being the
Internet, not a stack bug.

Kill-switch check in one line: `docker compose stop vpn` — the UI dies and
nothing inside can reach anywhere, LAN included.
