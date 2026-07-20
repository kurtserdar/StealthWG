# syntax=docker/dockerfile:1

# Build stage — cross-compiles the static gateway binary for the target arch.
# The gateway module uses `replace ../mask` and `replace ../quictransport` (the
# relay's QUIC mode imports quictransport), so those modules are copied in too.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY mask/ ./mask/
COPY quictransport/ ./quictransport/
COPY gateway/ ./gateway/
WORKDIR /src/gateway
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -ldflags='-s -w' -trimpath -o /out/stealthwg-gateway ./cmd/stealthwg-gateway

# Runtime stage — just the static binary on an empty base.
FROM scratch
COPY --from=build /out/stealthwg-gateway /stealthwg-gateway
# The mask-side listen port (51819) and, when STEALTHWG_QUIC is set, the QUIC
# port (443). Upstream and PSK are supplied via flags or the STEALTHWG_*
# environment variables (see the gateway's -h).
EXPOSE 51819/udp
EXPOSE 443/udp
ENTRYPOINT ["/stealthwg-gateway"]
