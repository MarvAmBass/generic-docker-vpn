FROM alpine:latest

# busybox-extras provides httpd (the on-link HTTP target used by the suite's
# positive controls).
RUN apk add --no-cache busybox-extras curl dnsmasq iproute2 nftables wireguard-tools

COPY entrypoint.sh /usr/local/bin/wg-test-server
RUN chmod +x /usr/local/bin/wg-test-server

ENTRYPOINT ["/usr/local/bin/wg-test-server"]
