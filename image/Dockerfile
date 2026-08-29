FROM golang:1-alpine AS build

ARG WIREGUARD_GO_VERSION=

RUN apk add --no-cache build-base curl linux-headers patch

COPY wireguard-go-mtu.patch /tmp/wireguard-go-mtu.patch
RUN WIREGUARD_GO_VERSION="${WIREGUARD_GO_VERSION:-0.0.20250522}" \
  && curl -fsSL "https://github.com/WireGuard/wireguard-go/archive/refs/tags/${WIREGUARD_GO_VERSION}.tar.gz" | tar -xz -C /tmp \
  && cd "/tmp/wireguard-go-${WIREGUARD_GO_VERSION}" \
  && patch -p1 -F0 </tmp/wireguard-go-mtu.patch \
  && mkdir -p /out \
  && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/wireguard-go . \
  && printf '%s\n' "$WIREGUARD_GO_VERSION" >/out/.wireguard-go-version

COPY tun-helper.c /tmp/tun-helper.c
RUN gcc -static -O2 -Wall -Werror -o /out/tun-helper /tmp/tun-helper.c

FROM alpine:latest

RUN apk add --no-cache \
      ca-certificates \
      curl \
      drill \
      iproute2 \
      libnatpmp \
      nftables \
      tinyproxy \
      wireguard-tools-wg \
  && adduser -D -H -s /sbin/nologin -u 833 wireguard

COPY --from=build /out/wireguard-go /out/tun-helper /usr/local/bin/
COPY --from=build /out/.wireguard-go-version /etc/wireguard-go-version

COPY entrypoint.sh /usr/local/bin/entrypoint
COPY portsync.sh /usr/local/bin/portsync
COPY healthcheck.sh /usr/local/bin/healthcheck

RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/portsync /usr/local/bin/healthcheck

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/healthcheck"]

ENTRYPOINT ["/usr/local/bin/entrypoint"]
