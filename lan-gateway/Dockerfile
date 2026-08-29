FROM alpine:latest

RUN apk add --no-cache socat

COPY entrypoint.sh /usr/local/bin/lan-gateway
RUN chmod +x /usr/local/bin/lan-gateway

# Unprivileged; use LISTEN_PORT > 1024.
USER nobody

ENTRYPOINT ["/usr/local/bin/lan-gateway"]
