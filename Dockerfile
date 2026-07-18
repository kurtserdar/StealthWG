# syntax=docker/dockerfile:1

# Build stage — cross-compiles the static gateway binary for the target arch.
# The gateway module uses `replace ../mask`, so both modules are copied in.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY mask/ ./mask/
COPY gateway/ ./gateway/
WORKDIR /src/gateway
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -ldflags='-s -w' -trimpath -o /out/stealthwg-gateway ./cmd/stealthwg-gateway

# Runtime stage — just the static binary on an empty base.
FROM scratch
COPY --from=build /out/stealthwg-gateway /stealthwg-gateway
# The mask-side listen port. Upstream and PSK are supplied via flags or the
# STEALTHWG_* environment variables (see the gateway's -h).
EXPOSE 51819/udp
ENTRYPOINT ["/stealthwg-gateway"]
