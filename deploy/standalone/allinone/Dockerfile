# syntax=docker/dockerfile:1

# Build stage — the all-in-one stealthwg binary (userspace WireGuard + masking).
# The gateway module uses `replace ../mask` and `replace ../quictransport`, so those
# modules are copied in alongside gateway.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY mask/ ./mask/
COPY quictransport/ ./quictransport/
COPY wgbind/ ./wgbind/
COPY gateway/ ./gateway/
WORKDIR /src/gateway
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -ldflags='-s -w' -trimpath -o /out/stealthwg ./cmd/stealthwg

# Runtime — the engine shells out to ip / sysctl / iptables, so include those. QR
# rendering (qrencode) is optional but handy for the printed client profiles.
FROM alpine:3.20
RUN apk add --no-cache iproute2 iptables libqrencode-tools
COPY --from=build /out/stealthwg /usr/bin/stealthwg
COPY deploy/standalone/allinone/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
# The masked/QUIC WireGuard port (set LISTEN to change; 443 for QUIC).
EXPOSE 51820/udp
EXPOSE 443/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
