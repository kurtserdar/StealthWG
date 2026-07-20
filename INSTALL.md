# Installing StealthWG

StealthWG has two parts:

- **The app** — a WireGuard client for **iOS and macOS** that masks its traffic.
- **The server** — either an **all-in-one masked WireGuard server** (one native
  binary) or the **relay** (masking in front of an existing WireGuard).

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

### Option A — All-in-one masked WireGuard server (recommended for a fresh host)

One self-contained binary that terminates a masked WireGuard tunnel (embedded
wireguard-go + masking) — no `wireguard-tools` needed.

Build the packages from source (or download release files):

```sh
go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
./scripts/build-packages.sh          # → dist/*.deb *.rpm *.apk (+ raw binaries)
```

Install and initialise:

```sh
# Debian / Ubuntu
sudo apt install ./dist/stealthwg_0.1.0_amd64.deb
# Fedora / RHEL / Rocky / Alma
sudo dnf install ./dist/stealthwg-0.1.0-1.x86_64.rpm
# Alpine
sudo apk add --allow-untrusted ./dist/stealthwg_0.1.0_x86_64.apk

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

### Option B — Relay (front an existing WireGuard)

If you already run WireGuard (kernel WG, MikroTik/RouterOS, wg-easy…), the relay
masks in front of it without changing it. Client traffic hits the relay on
`:51819`; it unmasks and forwards plain WireGuard to your upstream.

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

- **No WireGuard yet, but want Docker?** The `deploy/standalone/` compose bundle
  runs the relay **and** a bundled WireGuard server and prints a client profile.
- **RouterOS / MikroTik (e.g. RB5009), Kubernetes, other container hosts?** Use the
  container image.

Full server reference (env vars, standalone bundle, RouterOS container, UDP-443
fallback): **[docs/deploy-gateway.md](docs/deploy-gateway.md)**.

---

## Profile format

The app imports a standard wg-quick config with a StealthWG `[Stealth]` section.
`[Peer] Endpoint` points at the masked port; `MaskKey` is the shared obfuscation
PSK (base64), the same key the server runs with. Multiple endpoints (for automatic
fallback, e.g. `:51819` and `:443`) go in `[Stealth] Endpoints`.

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
Endpoints = <host>:51819, <host>:443
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
| Want Docker + a bundled WireGuard | **Standalone compose bundle** |
| High throughput / many clients | **Relay + kernel WireGuard** (kernel WG is faster than the all-in-one's userspace engine) |
