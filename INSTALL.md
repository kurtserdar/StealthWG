# Installing StealthWG

StealthWG has two parts:

- **The app** — a WireGuard client for **iOS and macOS** that masks its traffic.
- **The server** — one of **two engines**, depending on whether you already run
  WireGuard:
  - **All-in-one** (`stealthwg`) — WireGuard **and** masking in one binary. It
    terminates the tunnel itself, so it needs no other WireGuard. Best for a
    fresh host.
  - **Relay** (`stealthwg-gateway`) — masking **in front of an existing
    WireGuard**. It unmasks client traffic and forwards plain WireGuard to your
    upstream, which it never modifies.

You need one server and at least one app. This guide covers both.

> Honest status: the apps are **built from source** (not yet on the App Store /
> notarized distribution channel), and the server packages are built from source or
> installed from release files (no public apt/rpm repo yet). Commands below reflect
> that reality.

---

## 1. The app (iOS / macOS)

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); the WireGuard engine is a pinned
`wireguard-apple` submodule that takes a small patch set (applied idempotently by
the setup script), and the masking bind (`wgbind`) is built into the wireguard-go
bridge.

### Prerequisites

```sh
brew install xcodegen go
git clone https://github.com/kurtserdar/StealthWG.git && cd StealthWG
./scripts/setup-wireguard.sh                 # init submodule + apply patches (idempotent)
cp Local.xcconfig.example Local.xcconfig     # then set your DEVELOPMENT_TEAM
xcodegen generate
```

A paid Apple Developer account is required (Network Extensions is a paid
capability).

### iOS

```sh
open StealthWG.xcodeproj
# Scheme: StealthWG · destination: your physical iPhone · Run
```

The packet-tunnel extension only runs on a **physical device** — Network Extensions
don't run in the Simulator, and the wireguard-go bridge builds for `iphoneos` only.
On first run, trust the developer certificate on the device and allow the VPN
configuration.

### macOS

macOS packages the tunnel as a **System Extension**, which must be signed with a
**Developer ID Application** certificate, **notarized**, and run from
`/Applications`:

1. In the Developer portal, enable **Network Extensions** on the App IDs
   `com.stealthwg.mac` + `com.stealthwg.mac.tunnel` and create **Developer ID**
   provisioning profiles for them (they authorize the
   `packet-tunnel-provider-systemextension` entitlement).
2. In Xcode: **Product → Archive** → **Distribute App → Direct Distribution**
   (notarize) → **Export**.
3. Copy the exported `StealthWG.app` to **/Applications** and launch it.
4. From the menu-bar icon: **Enable VPN extension** → approve it in **System
   Settings → Privacy & Security**.

> Note: a Mac managed by an MDM with a restrictive system-extension policy (common
> with corporate security suites) may **block** third-party network extensions —
> the app is correct, but the device policy prevents activation. Use an unmanaged
> Mac.

### Using the app

Add a profile via **paste**, **scan QR**, **import a .conf file**, or **create from
scratch** (the form generates a client keypair and shows the public key to add to
your server). Multiple profiles are supported; per-profile options include
**Connect on demand** (always-on) and a **kill switch** (route all traffic).

---

## 2. The server

### Which install do I choose?

Pick **one** row. All three speak the same client profile and support both
transports (UDP mask on 51819 + QUIC on 443).

| Your situation | Use | What runs | Delivery |
|---|---|---|---|
| Fresh Linux host, **no** WireGuard, no Docker | **A. All-in-one native package** | one `stealthwg` binary (embeds WireGuard) | `apt/dnf/apk install` + systemd |
| Fresh host, **no** WireGuard, but you like **Docker** | **B. Standalone bundle** | one all-in-one container (userspace WireGuard + masking) | `docker compose up` |
| You **already** run WireGuard (kernel WG, MikroTik, wg-easy, K8s…) | **C. Relay image** | one relay container in front of your WireGuard | Docker image |

Rules of thumb:

- **No WireGuard yet?** → A (native) or B (Docker). Same all-in-one engine, different
  packaging.
- **Already have WireGuard?** → C only. Don't run A/B — they'd stand up a *second*
  WireGuard you don't need.
- A and B both use **userspace** WireGuard (`wireguard-go`) — no kernel module
  needed. C carries no WireGuard at all; it just forwards to the WireGuard you
  already run. (For max throughput, B has an opt-in **kernel-WireGuard** variant —
  see Option B.)

#### In plain words

- **A — "Just give me one box with everything inside, no Docker."** You install a
  single program (`apt install`), run `stealthwg init`, done. WireGuard **and** the
  masking live inside that one program.
- **B — "Empty server, but I like Docker."** You run `docker compose up` and it
  brings up **one all-in-one box** — WireGuard **and** masking in a single container.
  Same as A, just via Docker.
- **C — "I already run WireGuard and don't want to touch it."** You install **only
  the masker box** and tell it "my WireGuard is over there." It masks in front of
  it — it does **not** start a second WireGuard (you already have one).

Golden rule: **no WireGuard yet → A or B** (same job, one without Docker, one with).
**Already have WireGuard → C only** (A/B would stand up a second WireGuard you don't
need).

---

### Option A — All-in-one native package (fresh host, no Docker)

One self-contained binary that terminates a masked WireGuard tunnel (embedded
wireguard-go + masking) — no `wireguard-tools`, no Docker, no existing WireGuard.

Download the `.deb` / `.rpm` / `.apk` for your arch from the
[**latest release**](https://github.com/kurtserdar/StealthWG/releases/latest), or
build from source:

```sh
go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
VERSION=0.2.0 ./scripts/build-packages.sh   # → dist/*.deb *.rpm *.apk (+ raw binaries)
```

Install and initialise:

```sh
# Debian / Ubuntu
sudo apt install ./stealthwg_0.2.0_amd64.deb
# Fedora / RHEL / Rocky / Alma
sudo dnf install ./stealthwg-0.2.0-1.x86_64.rpm
# Alpine
sudo apk add --allow-untrusted ./stealthwg_0.2.0_x86_64.apk

sudo stealthwg init --public-host <your-public-ip-or-dns>
```

`init` generates the server keys + mask PSK, configures the interface and NAT,
starts the `stealthwg` service, and prints a client profile (with a QR) to paste
into the app. Add more devices:

```sh
sudo stealthwg add-client laptop
```

Point the app's `[Peer] Endpoint` at `<public-host>:51820` (the port `init` uses)
and forward that UDP port to the host.

To run the server over **QUIC** instead of the UDP mask (blends with HTTP/3 on
UDP 443):

```sh
sudo stealthwg init --public-host <ip-or-dns> --transport quic --sni www.cloudflare.com --listen 443
```

The printed client profile then carries `[Stealth] Transport = quic` and `SNI`,
so the app dials it over QUIC automatically.

### Option B — Standalone Docker bundle (fresh host, with Docker)

Same "no existing WireGuard" case as Option A, but for Docker hosts. The
`deploy/standalone/` compose bundle runs **one all-in-one container** — the
`stealthwg` binary with userspace WireGuard + masking + NAT in a single process —
and prints a client profile (with QR). No host kernel WireGuard needed.

```sh
cd deploy/standalone
cp .env.example .env           # set PUBLIC_HOST (your public IP/DNS)
docker compose up -d
docker compose logs stealthwg  # scan the printed QR / copy the profile
```

Add more devices later without downtime:

```sh
docker compose exec stealthwg stealthwg add-client laptop
```

For **QUIC** on 443, set `TRANSPORT=quic` and `LISTEN=443` in `.env`. The container
needs `NET_ADMIN` + `/dev/net/tun` (already set in the compose file). Full reference
(env vars, RouterOS container): **[docs/deploy-gateway.md](docs/deploy-gateway.md)**.

> Choosing between A and B? Both stand up the same all-in-one masked WireGuard
> (userspace `wireguard-go`). **A** is a native binary (no Docker); **B** is one
> Docker container. Same client profile either way.

### Option C — Relay image (you already run WireGuard)

If you already run WireGuard (kernel WG, MikroTik/RouterOS, wg-easy, Kubernetes…),
run **only** the relay in front of it — do not start a second WireGuard. Client
traffic hits the relay on `:51819`; it unmasks and forwards plain WireGuard to
your upstream, which it never modifies.

Container image (`ghcr.io/kurtserdar/stealthwg-gateway`, multi-arch):

```sh
docker run -d --name stealthwg-gateway --restart unless-stopped \
    -p 51819:51819/udp \
    -e STEALTHWG_UPSTREAM=<your-wireguard-host>:51820 \
    -e STEALTHWG_PSK=<base64 PSK> \
    ghcr.io/kurtserdar/stealthwg-gateway:latest
```

The client profile then uses `[Peer] Endpoint = <relay host>:51819` and
`[Stealth] MaskKey = <the same PSK>`.

To also accept **QUIC** clients on UDP 443, add `-p 443:443/udp` and
`-e STEALTHWG_QUIC=:443`; the relay then runs the QUIC listener alongside the
mask listener, both forwarding to the same upstream WireGuard.

RouterOS / MikroTik (e.g. RB5009), Kubernetes and other container-host recipes,
plus the full env-var reference, are in
**[docs/deploy-gateway.md](docs/deploy-gateway.md)**.

---

## Profile format

The app imports a standard wg-quick config with a StealthWG `[Stealth]` section.
`[Peer] Endpoint` points at the masked port; `MaskKey` is the shared obfuscation
PSK (base64), the same key the server runs with. Multiple endpoints (for automatic
fallback, e.g. `:51819` and `:443`) go in `[Stealth] Endpoints`.

`[Stealth] Transport` selects the transport: `mask` (UDP mask, the default) or
`quic` (QUIC DATAGRAM on UDP 443, blending with HTTP/3). For `quic`, `SNI` sets
the TLS server name the client presents. A fallback endpoint may override the
transport with a `quic://` or `mask://` scheme (e.g. `quic://host:443`), so the
app can try QUIC first and fall back to the UDP mask.

```ini
[Interface]
PrivateKey = <client private key>
Address = 10.0.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = <server public key>
Endpoint = <server public IP>:51819
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

[Stealth]
MaskKey = <base64 PSK>
Endpoints = <host>:51819, quic://<host>:443
Transport = mask
SNI = www.cloudflare.com
```

Run the parser tests with `./scripts/test-parser.sh`; the gateway tests with
`cd gateway && go test ./...`.

---

## Which server should I use?

| Situation | Use |
|---|---|
| Fresh Linux host, want one command | **All-in-one** (native package + `stealthwg init`) |
| Already run WireGuard | **Relay** pointed at your WireGuard |
| RouterOS / MikroTik / Kubernetes | **Relay** container image |
| Fresh host, want Docker | **Standalone compose bundle** (one all-in-one container) |
