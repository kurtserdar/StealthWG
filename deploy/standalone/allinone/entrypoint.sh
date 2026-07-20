#!/bin/sh
# All-in-one StealthWG container: provisions on first boot (no systemd), then runs
# the masked/QUIC WireGuard server in the foreground as PID 1. POSIX sh, idempotent.
set -eu

export STEALTHWG_NO_SYSTEMD=1
export STEALTHWG_CONFIG="${STEALTHWG_CONFIG:-/data/server.conf}"

: "${PUBLIC_HOST:?set PUBLIC_HOST in .env}"
PEERS="${PEERS:-1}"

if [ ! -f "$STEALTHWG_CONFIG" ]; then
    mkdir -p "$(dirname "$STEALTHWG_CONFIG")"
    stealthwg init --public-host "$PUBLIC_HOST" \
        ${SUBNET:+--subnet "$SUBNET"} \
        ${DNS:+--dns "$DNS"} \
        ${LISTEN:+--listen "$LISTEN"} \
        ${TRANSPORT:+--transport "$TRANSPORT"} \
        ${SNI:+--sni "$SNI"}
    i=2
    while [ "$i" -le "$PEERS" ]; do
        stealthwg add-client "client$i"
        i=$((i + 1))
    done
fi

# exec so stealthwg becomes PID 1 (SIGHUP reload from `add-client` targets PID 1).
exec stealthwg up
