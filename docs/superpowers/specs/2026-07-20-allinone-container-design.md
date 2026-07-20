# All-in-One Container (Standalone Bundle Unification) — Design

**Date:** 2026-07-20
**Status:** Approved, ready for planning

## Goal

Give the `stealthwg` all-in-one binary a **container mode** and rebuild the standalone
Docker bundle around it: one container running userspace WireGuard + masking, instead
of today's two containers (a kernel-WireGuard `wg` + the `gateway` relay). Result: one
engine, one container, **no host kernel-WireGuard dependency**, and QUIC on 443 for
free.

## From → to

```
NOW:  [ wg: wireguard-tools + host kernel WG ] + [ gateway: relay ]   (2 containers, kernel WG)
NEW:  [ stealthwg: wireguard-go + mask + NAT ]                         (1 container, userspace)
```

The kernel-WG two-container path is **kept** as an opt-in "high-performance" variant
(userspace wireguard-go is simpler/portable but slower than kernel WG).

## The blocker & fix

The all-in-one CLI (`gateway/cmd/stealthwg`) assumes systemd:
`init` → `systemctl enable --now`, `add-client` → `systemctl reload`. Containers have
no systemd. Fix: an env-gated **no-systemd mode** (`STEALTHWG_NO_SYSTEMD=1`):
- `init` skips `systemctl enable --now` (just provisions + prints the client profile).
- `add-client` reloads the running daemon by **signalling PID 1 with SIGHUP** — but
  only when PID 1 is actually the `stealthwg` daemon (checked via `/proc/1/comm`), so
  it is a no-op during entrypoint provisioning (when PID 1 is the shell).
- The container entrypoint provisions on first boot, then `exec stealthwg up` (PID 1,
  foreground). `stealthwg up` already reloads peers on SIGHUP.

## Components

### `gateway/cmd/stealthwg/main.go` (modify)
```go
func noSystemd() bool { return os.Getenv("STEALTHWG_NO_SYSTEMD") != "" }

// in cmdInit, replace the unconditional systemctl call:
if !noSystemd() {
    _ = exec.Command("systemctl", "enable", "--now", "stealthwg").Run()
}

// replace `systemctl reload stealthwg` in cmdAddClient with:
reloadDaemon()

func reloadDaemon() {
    if noSystemd() {
        if c, err := os.ReadFile("/proc/1/comm"); err == nil &&
            strings.TrimSpace(string(c)) == "stealthwg" {
            _ = syscall.Kill(1, syscall.SIGHUP)   // signal the running daemon
        }
        return
    }
    _ = exec.Command("systemctl", "reload", "stealthwg").Run()
}
```
`requireRoot()` stays (the container runs as root). `init` receives `--public-host`
(and optional `--transport`/`--sni`/`--listen`) from the entrypoint, so no curl-based
host detection is needed. Config path is `STEALTHWG_CONFIG` (already supported) → a
mounted volume for persistence.

### `deploy/standalone/allinone/Dockerfile` (new)
Multi-stage: build `stealthwg` (CGO-free, pinned wireguard-go) → runtime on Alpine with
`iproute2` + `iptables` (the engine shells out to `ip`/`sysctl`/`iptables`) + optional
`libqrencode-tools` (QR in logs). `ENTRYPOINT ["/entrypoint.sh"]`.

### `deploy/standalone/allinone/entrypoint.sh` (new, POSIX sh)
```sh
#!/bin/sh
set -eu
export STEALTHWG_NO_SYSTEMD=1
export STEALTHWG_CONFIG="${STEALTHWG_CONFIG:-/data/server.conf}"
: "${PUBLIC_HOST:?set PUBLIC_HOST in .env}"
PEERS="${PEERS:-1}"
if [ ! -f "$STEALTHWG_CONFIG" ]; then
    stealthwg init --public-host "$PUBLIC_HOST" \
        ${SUBNET:+--subnet "$SUBNET"} ${DNS:+--dns "$DNS"} \
        ${LISTEN:+--listen "$LISTEN"} ${TRANSPORT:+--transport "$TRANSPORT"} ${SNI:+--sni "$SNI"}
    i=2; while [ "$i" -le "$PEERS" ]; do stealthwg add-client "client$i"; i=$((i+1)); done
fi
exec stealthwg up
```
(`init`/`add-client` print each client profile + QR to the log on first boot.)

### `deploy/standalone/docker-compose.yml` (rewrite → single service)
```yaml
services:
  stealthwg:
    image: ghcr.io/kurtserdar/stealthwg-allinone:latest
    build: ./allinone
    restart: unless-stopped
    cap_add: ["NET_ADMIN"]
    devices: ["/dev/net/tun:/dev/net/tun"]
    sysctls: { net.ipv4.ip_forward: "1" }
    ports:
      - "${LISTEN:-51820}:${LISTEN:-51820}/udp"
    environment:
      PUBLIC_HOST: "${PUBLIC_HOST:?set PUBLIC_HOST in .env}"
      PEERS: "${PEERS:-1}"
      SUBNET: "${SUBNET:-10.8.0.0/24}"
      DNS: "${DNS:-1.1.1.1}"
      LISTEN: "${LISTEN:-51820}"
      TRANSPORT: "${TRANSPORT:-mask}"
      SNI: "${SNI:-}"
    volumes:
      - ./data:/data
```
For QUIC: set `TRANSPORT=quic`, `LISTEN=443` in `.env`.

### Kept: kernel-WG variant
Rename the current two-container file to
`deploy/standalone/docker-compose.kernel-wg.yml` (unchanged content) and keep the
`wg/` image dir. Docs point to it for kernel-WG performance.

### `.env.example` + docs
Update `deploy/standalone/.env.example` (PUBLIC_HOST, PEERS, SUBNET, DNS, LISTEN,
TRANSPORT, SNI) and `docs/deploy-gateway.md` (all-in-one is the default; kernel-WG is
the performance opt-in). README's install guide already lists the standalone bundle.

## Data flow

1. `docker compose up -d` → first boot: entrypoint provisions config+keys+PSK+PEERS
   clients (no systemd), prints profiles/QR, then `exec stealthwg up` (PID 1).
2. `up` brings up the TUN, the masked (or QUIC) WireGuard, and NAT.
3. `docker exec stealthwg stealthwg add-client laptop` → writes config, SIGHUPs PID 1
   → daemon reloads peers live.
4. Restart → config exists → skip provisioning → `up`.

## Error handling

- `PUBLIC_HOST` missing → entrypoint exits with a clear message (compose `:?`).
- No `/dev/net/tun` or `NET_ADMIN` → `stealthwg up` fails loudly (TUN create error);
  docs list the required `cap_add`/`devices`.
- add-client during provisioning (PID 1 = shell) → SIGHUP suppressed (comm check).

## Testing

- **Go:** `gateway` unit tests stay green; `reloadDaemon`/`noSystemd` are small and
  covered by a build + a focused test that `noSystemd()` reads the env.
- **Docker:** the all-in-one image **builds**; a smoke test runs `stealthwg init`
  inside the container (no TUN needed) and asserts it provisions + prints a profile
  without calling systemctl.
- **Device (user):** full `docker compose up` on a real Linux host + a phone
  connecting through the container is end-to-end verification (deferred to router
  access), like the QUIC end-to-end test.

## Out of scope (YAGNI)

- Writing profile files to a `/profiles` volume (they print to the log; a
  `print-client` command can come later).
- wg-easy-style web UI / multi-device management.
- Retiring the kernel-WG image (kept as the performance variant).
