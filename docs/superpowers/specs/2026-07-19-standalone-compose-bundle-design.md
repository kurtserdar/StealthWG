# StealthWG standalone compose bundle — design

**Date:** 2026-07-19
**Status:** Approved, ready for implementation planning

## Goal

Let someone with **no existing WireGuard server** stand up a complete StealthWG
endpoint on a generic Linux box (or VPS) with a single `docker compose up -d`.
The bundle runs the masking relay **and** a WireGuard server side by side, and
emits a ready-to-paste StealthWG client profile (correct relay endpoint + mask
key) so the user can connect their phone immediately.

This is the "WG-not-yet-installed" tier. Users who **already** run WireGuard do
not use this bundle — they run the relay container alone and point its upstream
at their existing WG (already covered by the "Generic Linux / VPS" section of
`docs/deploy-gateway.md`). The relay is transparent to an existing WG server:
the only client-side change is `[Peer] Endpoint` → relay `:51819` and adding
`[Stealth] MaskKey`.

## Non-goals (YAGNI)

- No web UI, no admin panel.
- No multi-user / dynamic peer add-remove at runtime. Peers are provisioned once
  at first boot from `PEERS`. Managing many devices via a UI is a **later phase**
  (the "wg-easy / native provisioner" option we explicitly deferred).
- No change to the existing gateway image — it is reused as-is.

## Architecture

Two services in one `docker compose` project, each with one clear job:

1. **`gateway`** — the existing multi-arch relay image
   (`ghcr.io/kurtserdar/stealthwg-gateway`). Unchanged. Publishes `51819/udp`
   to the host. Its upstream is the `wg` service on the compose network
   (`wg:51820`). It unmasks incoming StealthWG traffic and forwards plain
   WireGuard to `wg`.

2. **`wg`** — a new small image (Alpine + `wireguard-tools` + `iptables` +
   `qrencode`, with a userspace `wireguard-go`/BoringTun fallback binary). A thin,
   auditable `entrypoint.sh` owns provisioning and the WG server lifecycle.

Only `gateway` exposes a host port. `wg` has **no** published port — it is
reachable only by the relay over the internal compose network, keeping the WG
listener off the public internet (minimal attack surface). The design principle:
the relay is the small, exposed, auditable front door; the WG server is an
internal, mature engine.

```
phone ──masked UDP──▶ host:51819/udp ──▶ [gateway] ──plain WG──▶ [wg]:51820 ──▶ internet (NAT)
                                          unmask                 terminate + masquerade
```

## `wg` entrypoint behavior

**First boot (no persisted state):**
1. Generate the server keypair and `PEERS` client keypairs; write all keys and
   the resolved PSK to the persistent data volume.
2. If `STEALTHWG_PSK` is unset, generate a 32-byte base64 PSK and persist it.
3. Write `/etc/wireguard/wg0.conf` (server + peers) and `wg-quick up wg0`.
   Prefer the kernel WireGuard module; if unavailable, fall back to userspace
   (`wireguard-go`). Enable `net.ipv4.ip_forward` and an `iptables` MASQUERADE
   rule so client traffic reaches the internet.
4. For each client, write a **StealthWG** profile with:
   - `[Interface]` Address in `WG_SUBNET`, `DNS = ${WG_DNS}`, PrivateKey
   - `[Peer]` server PublicKey, `AllowedIPs = 0.0.0.0/0, ::/0`,
     `Endpoint = ${PUBLIC_HOST}:51819`  ← the **relay**, not the WG port
   - `[Stealth] MaskKey = ${PSK}`
   Deliver each profile three ways: write to the mounted `./profiles/clientN.conf`,
   print it to the container log, and render a QR code (`qrencode`) to the log for
   direct phone import.

**Subsequent boots (state exists):**
- Reuse the persisted keys and PSK verbatim (idempotent). Re-render `wg0.conf`,
  bring the tunnel up, re-apply forwarding/NAT. Do **not** regenerate keys or
  profiles. This makes `docker compose down && up -d` and host reboots safe.

## Configuration (`.env`)

| Variable        | Required | Default                | Purpose                                   |
|-----------------|----------|------------------------|-------------------------------------------|
| `PUBLIC_HOST`   | yes      | —                      | Public IP/DNS written as the profile Endpoint |
| `STEALTHWG_PSK` | no       | generated + persisted  | Mask PSK; shared by relay and profiles    |
| `PEERS`         | no       | `1`                    | Number of client profiles to provision    |
| `WG_SUBNET`     | no       | `10.0.0.0/24`          | Tunnel subnet                             |
| `WG_DNS`        | no       | `1.1.1.1`              | DNS pushed to clients                     |

**Shared PSK, no race.** To guarantee relay and profiles agree even when the PSK
is auto-generated, `wg` is the single owner of the PSK: it writes the resolved
value to `./data/psk` (base64, `0600`) as the **first** step of its entrypoint,
before anything else. The `gateway` service does not take `STEALTHWG_PSK` from
`.env`; instead it mounts `./data` read-only and is configured with
`STEALTHWG_PSK_FILE=/data/psk`, plus `depends_on: wg`. With `restart:
unless-stopped`, if `gateway` starts before the file exists it exits and retries
until `wg` has written it, then stays up. If the user *does* set
`STEALTHWG_PSK` in `.env`, `wg` uses that value verbatim (still writing it to
`./data/psk` for the relay), so an explicit PSK and an auto-generated one flow
through the exact same single path.

## Persistence

Bind mounts in the compose project directory:
- `./data` — server/client keys and the resolved PSK. Survives restarts and
  `down/up`.
- `./profiles` — generated `clientN.conf` files for the user to copy out.

## Networking / requirements

- Compose bridge network; `gateway` publishes `51819/udp`; `wg` publishes nothing.
- `wg` requires `NET_ADMIN` and `/dev/net/tun`.
- Restart policy `unless-stopped` on both services.
- Host needs WireGuard support (kernel 5.6+ has it built in); userspace fallback
  covers hosts without the module, at lower throughput (acceptable for the
  few-device tier).
- Upgrade path: `docker compose pull && docker compose up -d`.

## Repository layout

```
deploy/standalone/
  docker-compose.yml
  .env.example
  wg/
    Dockerfile
    entrypoint.sh
```

- Add a "Standalone (WireGuard included)" section to `docs/deploy-gateway.md`
  pointing at `deploy/standalone/`.
- The new `wg` image can be built locally by the bundle; publishing it to GHCR
  alongside the gateway image is optional and can follow later.

## Testing

- `entrypoint.sh` logic (key generation, idempotent second boot, profile
  contents) is unit-testable with a shell test harness that stubs `wg`/`wg-quick`
  and asserts on generated files (mirrors the existing `scripts/*.sh` test style,
  e.g. `scripts/test-parser.sh`).
- Manual end-to-end: `docker compose up -d` on a Linux host, import the emitted
  profile on a phone, confirm handshake and internet egress. (macOS Docker cannot
  exercise kernel WG / NAT the same way; end-to-end is validated on Linux.)

## Security notes

- WG listener never exposed to the host/public — internal compose network only.
- PSK never published as a port or printed outside first-boot provisioning
  output; persisted with restrictive permissions on the `./data` volume.
- Keys are generated inside the container and never leave the volume.
