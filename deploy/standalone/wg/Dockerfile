# Bundled WireGuard server for the StealthWG standalone compose bundle.
# Uses the host's kernel WireGuard via wg-quick. The host therefore needs
# WireGuard support (built into Linux 5.6+); a userspace fallback is not bundled
# yet (no wireguard-go package in the pinned Alpine repo).
FROM alpine:3.20

RUN apk add --no-cache \
        wireguard-tools \
        wireguard-tools-wg-quick \
        iptables \
        ip6tables \
        libqrencode-tools \
        iproute2

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
