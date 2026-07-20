# Deploying the StealthWG gateway

StealthWG ships in two shapes:

- **All-in-one server** (`stealthwg`) — a single self-contained binary that **is**
  a masked WireGuard server (embedded wireguard-go + UdpMask). Best for a fresh
  Linux host: `apt install` then one `stealthwg init`. See "Native install" below.
- **Relay** (`stealthwg-gateway`) — unmasks and forwards to an **unmodified**
  upstream WireGuard (kernel WG, MikroTik, wg-easy…). Best when you already run
  WireGuard, or on container platforms (RouterOS/RB5009, k8s). See the rest of
  this doc.

## Native install (all-in-one masked WireGuard server)

Download the package for your distro from the releases (or build with
`scripts/build-packages.sh`), then:

```sh
# Debian / Ubuntu
sudo apt install ./stealthwg_0.1.0_amd64.deb
# Fedora / RHEL / Rocky / Alma
sudo dnf install ./stealthwg-0.1.0-1.x86_64.rpm
# Alpine
sudo apk add --allow-untrusted stealthwg_0.1.0_x86_64.apk

# Bring up a complete masked WireGuard server (generates keys + PSK, NAT, service):
sudo stealthwg init --public-host <your-public-ip-or-dns>

# It prints a client profile (with a QR) — paste it into the StealthWG app.
# Add more devices:
sudo stealthwg add-client laptop
```

WireGuard is embedded (no `wireguard-tools` needed); the package only recommends
`iproute2` / `iptables` for the interface + NAT, and `qrencode` for the QR. The
server runs as the `stealthwg` systemd service. Available as `.deb`, `.rpm`,
`.apk` for amd64 + arm64; raw binaries for macOS/*BSD in the releases.

Already running WireGuard, or on a container platform? Use the **relay** instead —
it fronts your existing WireGuard without touching it.

---

## Relay (front an existing WireGuard)

The relay is a single static binary shipped as a multi-arch container image
(`linux/amd64` + `linux/arm64`, ~3.5 MB):

```
ghcr.io/kurtserdar/stealthwg-gateway:latest
```

It unmasks StealthWG client traffic and forwards it to an **unmodified** upstream
WireGuard endpoint. Configure it with flags or `STEALTHWG_*` environment
variables (flag > env > default):

| Flag         | Env var               | Default    | Meaning                              |
|--------------|-----------------------|------------|--------------------------------------|
| `-listen`    | `STEALTHWG_LISTEN`    | `:51819`   | mask-side UDP listen address         |
| `-upstream`  | `STEALTHWG_UPSTREAM`  | (required) | real WireGuard endpoint `host:port`  |
| `-psk`       | `STEALTHWG_PSK`       | (required) | obfuscation PSK, base64              |
| `-psk-file`  | `STEALTHWG_PSK_FILE`  | —          | file holding the base64 PSK          |
| `-timeout`   | `STEALTHWG_TIMEOUT`   | `180s`     | idle session timeout                 |
| `-padmax`    | `STEALTHWG_PADMAX`    | `32`       | max random padding per packet (0..255) |

The PSK must match the `[Stealth] MaskKey` in the client profile.

## Generic Linux / VPS (Docker)

```sh
docker run -d --name stealthwg-gateway --restart unless-stopped \
    -p 51819:51819/udp \
    -e STEALTHWG_UPSTREAM=<wireguard-host>:51820 \
    -e STEALTHWG_PSK=<base64 PSK> \
    ghcr.io/kurtserdar/stealthwg-gateway:latest
```

Or with Compose:

```yaml
services:
  gateway:
    image: ghcr.io/kurtserdar/stealthwg-gateway:latest
    restart: unless-stopped
    ports: ["51819:51819/udp"]
    environment:
      STEALTHWG_UPSTREAM: "<wireguard-host>:51820"
      STEALTHWG_PSK: "<base64 PSK>"
```

Point the public UDP 51819 at this host, and the client `[Peer] Endpoint` at the
public address.

## Standalone bundle — WireGuard included (no existing WG server)

If you do **not** already run WireGuard, the standalone bundle in
`deploy/standalone/` brings up the masking relay **and** a WireGuard server
together, and prints a ready-to-import StealthWG client profile (with a QR code).

```sh
cd deploy/standalone
cp .env.example .env
# edit .env: set PUBLIC_HOST to your server's public IP or DNS name
docker compose up -d
docker compose logs wg      # shows the client profile + QR to scan on your phone
```

Both images are published (`ghcr.io/kurtserdar/stealthwg-gateway` and
`ghcr.io/kurtserdar/stealthwg-wg`), so `up` just pulls them — no local build.
To build the WireGuard-server image from source instead, run
`docker compose build`.

Generated client profiles are also written to `deploy/standalone/profiles/`.
Keys and the PSK persist in `deploy/standalone/data/` across restarts. To add
more devices, set `PEERS` before the first `up` (or delete `data/` to
reprovision). The host needs kernel WireGuard support (built into Linux 5.6+).

The bundle also exposes the relay on UDP 443. To use both (so the client falls
back to 443 when 51819 is blocked), list both in the profile's `[Stealth]`
section:

```
[Stealth]
MaskKey = <PSK>
Endpoints = <PUBLIC_HOST>:51819, <PUBLIC_HOST>:443
```

The client tries them in order and stays on the first that completes a handshake.

Already have a WireGuard server? Don't use this bundle — run the relay alone (see
"Generic Linux / VPS" above) and point `STEALTHWG_UPSTREAM` at your existing
WireGuard. The relay is transparent to it: the only client change is
`[Peer] Endpoint` → the relay `:51819` and adding `[Stealth] MaskKey`.

## MikroTik RB5009 (RouterOS container)

This runs the gateway on the router itself, next to its WireGuard server, so no
separate machine is needed.

### 1. One-time: enable containers

Requires the `container` extra package installed and container device-mode. The
device-mode toggle needs **physical confirmation** (press the reset button when
prompted):

```rsc
/system/device-mode/update container=yes
# then confirm on the device (reset button / power-cycle within the window)
```

### 2. Container network (a veth on its own bridge, NAT to the LAN)

```rsc
/interface/veth/add name=veth-stealth address=172.19.0.2/24 gateway=172.19.0.1
/interface/bridge/add name=br-containers
/ip/address/add address=172.19.0.1/24 interface=br-containers
/interface/bridge/port/add bridge=br-containers interface=veth-stealth
```

### 3. Environment + image

```rsc
/container/envs/add name=stealthwg key=STEALTHWG_UPSTREAM value="192.168.10.1:51820"
/container/envs/add name=stealthwg key=STEALTHWG_PSK value="<base64 PSK>"
/container/envs/add name=stealthwg key=STEALTHWG_LISTEN value=":51819"

/container/add remote-image=ghcr.io/kurtserdar/stealthwg-gateway:latest \
    interface=veth-stealth envlist=stealthwg \
    root-dir=disk1/containers/stealthwg \
    logging=yes start-on-boot=yes
/container/start [find where root-dir~"stealthwg"]
```

`root-dir` must be on writable storage (internal disk or a USB stick). Check
`/container/print` until the status is `running`, and `/log/print` for output.

### 4. Firewall + DNAT (repoint from any previous host)

The gateway container listens on `172.19.0.2:51819` and forwards to the router's
WireGuard at `192.168.10.1:51820`.

```rsc
# Internet-facing port forward -> the container
/ip/firewall/nat/add chain=dstnat in-interface=<WAN> protocol=udp \
    dst-port=51819 action=dst-nat to-addresses=172.19.0.2 to-ports=51819 \
    comment="StealthWG mask -> gateway container"

# Allow the forwarded traffic to reach the container (above the WAN drop)
/ip/firewall/filter/add chain=forward action=accept protocol=udp \
    dst-address=172.19.0.2 dst-port=51819 place-before=[find chain=forward comment="FORWARD - Drop unsolicited WAN"] \
    comment="StealthWG allow to container"

# Let the container reach the WireGuard listener on the router
/ip/firewall/filter/add chain=input action=accept protocol=udp \
    src-address=172.19.0.2 dst-port=51820 \
    place-before=[find chain=input comment="INPUT - Drop WAN"] \
    comment="StealthWG container -> WG"
```

(Adjust rule comments/placement to match your ruleset.) The client profile is
unchanged: `[Peer] Endpoint = <public IP>:51819`, `[Stealth] MaskKey = <PSK>`.
