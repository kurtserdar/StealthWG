#!/bin/sh
# StealthWG standalone bundle — provisions keys/PSK, runs the WireGuard server,
# and emits StealthWG client profiles. POSIX sh (BusyBox ash), idempotent.
set -eu

DATA_DIR="${DATA_DIR:-/data}"
PROFILES_DIR="${PROFILES_DIR:-/profiles}"
WG_CONF_DIR="${WG_CONF_DIR:-/etc/wireguard}"
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.0.0.0/24}"
WG_DNS="${WG_DNS:-1.1.1.1}"
PEERS="${PEERS:-1}"
RELAY_PORT="${RELAY_PORT:-51819}"
SUPERVISE="${SUPERVISE:-1}"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

subnet_base()      { printf '%s' "$WG_SUBNET" | sed 's#\.[0-9]*/[0-9]*$##'; }
subnet_prefixlen() { printf '%s' "$WG_SUBNET" | sed 's#.*/##'; }

# resolve_psk sets $PSK and writes $DATA_DIR/psk (base64). The PSK file is the
# single source of truth shared with the relay via STEALTHWG_PSK_FILE. Written
# first, before anything else, so the relay can start as soon as it appears.
resolve_psk() {
    psk_file="$DATA_DIR/psk"
    if [ -n "${STEALTHWG_PSK:-}" ]; then
        printf '%s' "$STEALTHWG_PSK" > "$psk_file"
    elif [ ! -f "$psk_file" ]; then
        wg genpsk | tr -d '\n' > "$psk_file"
    fi
    chmod 600 "$psk_file"
    PSK="$(cat "$psk_file")"
}

ensure_server_keys() {
    if [ ! -f "$DATA_DIR/server.key" ]; then
        ( umask 077; wg genkey > "$DATA_DIR/server.key" )
        wg pubkey < "$DATA_DIR/server.key" > "$DATA_DIR/server.pub"
    fi
    SERVER_KEY="$(cat "$DATA_DIR/server.key")"
    SERVER_PUB="$(cat "$DATA_DIR/server.pub")"
}

ensure_peer_keys() {
    i=1
    while [ "$i" -le "$PEERS" ]; do
        if [ ! -f "$DATA_DIR/peer$i.key" ]; then
            ( umask 077; wg genkey > "$DATA_DIR/peer$i.key" )
            wg pubkey < "$DATA_DIR/peer$i.key" > "$DATA_DIR/peer$i.pub"
        fi
        i=$((i+1))
    done
}

render_server_conf() {
    base="$(subnet_base)"; plen="$(subnet_prefixlen)"
    conf="$WG_CONF_DIR/$WG_IF.conf"
    {
        printf '[Interface]\n'
        printf 'Address = %s.1/%s\n' "$base" "$plen"
        printf 'ListenPort = %s\n' "$WG_PORT"
        printf 'PrivateKey = %s\n' "$SERVER_KEY"
        i=1
        while [ "$i" -le "$PEERS" ]; do
            printf '\n[Peer]\n'
            printf 'PublicKey = %s\n' "$(cat "$DATA_DIR/peer$i.pub")"
            printf 'AllowedIPs = %s.%s/32\n' "$base" "$((i+1))"
            i=$((i+1))
        done
    } > "$conf"
    chmod 600 "$conf"
}

write_profiles() {
    base="$(subnet_base)"
    i=1
    while [ "$i" -le "$PEERS" ]; do
        out="$PROFILES_DIR/client$i.conf"
        ( umask 077
          {
            printf '[Interface]\n'
            printf 'PrivateKey = %s\n' "$(cat "$DATA_DIR/peer$i.key")"
            printf 'Address = %s.%s/32\n' "$base" "$((i+1))"
            printf 'DNS = %s\n' "$WG_DNS"
            printf '\n[Peer]\n'
            printf 'PublicKey = %s\n' "$SERVER_PUB"
            printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
            printf 'Endpoint = %s:%s\n' "$PUBLIC_HOST" "$RELAY_PORT"
            printf '\n[Stealth]\n'
            printf 'MaskKey = %s\n' "$PSK"
          } > "$out" )
        log "===== StealthWG profile: client$i ($out) ====="
        cat "$out"
        log "----- scan this QR to import on a phone -----"
        qrencode -t ANSIUTF8 < "$out" || true
        i=$((i+1))
    done
}

start_tunnel() {
    sysctl net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    wg-quick up "$WG_IF"
    out_if="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [ -n "$out_if" ]; then
        iptables -t nat -C POSTROUTING -s "$WG_SUBNET" -o "$out_if" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -o "$out_if" -j MASQUERADE
    else
        iptables -t nat -C POSTROUTING -s "$WG_SUBNET" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -j MASQUERADE
    fi
}

supervise() {
    trap 'wg-quick down "$WG_IF" 2>/dev/null || true; exit 0' TERM INT
    log "StealthWG standalone up: relay :$RELAY_PORT -> wg :$WG_PORT. Ctrl-C to stop."
    while :; do sleep 3600 & wait $!; done
}

main() {
    [ -n "${PUBLIC_HOST:-}" ] || die "PUBLIC_HOST is required"
    mkdir -p "$DATA_DIR" "$PROFILES_DIR" "$WG_CONF_DIR"
    resolve_psk
    ensure_server_keys
    ensure_peer_keys
    render_server_conf
    write_profiles
    start_tunnel
    [ "$SUPERVISE" = "1" ] && supervise
    return 0
}

main "$@"
