# StealthWG

An iOS WireGuard client with a pluggable **traffic obfuscation** transport layer,
designed to keep working on networks that fingerprint and block standard
WireGuard traffic via DPI (Deep Packet Inspection).

StealthWG does **not** reimplement WireGuard. It builds on the official,
MIT-licensed [WireGuard Apple](https://github.com/WireGuard/wireguard-apple)
engine (`WireGuardKit` + `wireguard-go`) and inserts a masking layer between the
WireGuard engine and the network socket.

```
Normal WireGuard:   WG engine ──────────────────────► server:51820
StealthWG:          WG engine ─► UdpMaskTransport ──► server:51819 ─► unmask ─► WG:51820
```

The obfuscation only reshapes the on-wire byte pattern to break DPI fingerprints.
All cryptographic security is still provided by WireGuard itself.

## Why this exists

Standard WireGuard is easy for a network operator to recognize: its handshake
packets have a fixed shape — a message-type byte followed by reserved zero bytes,
plus fixed 148/92-byte handshake sizes. Some mobile carriers and ISPs use exactly
this signature to block WireGuard on **every** port, so the tunnel never connects,
no matter how you configure it — while ordinary UDP keeps flowing.

StealthWG was built for that situation. It reshapes every packet into
high-entropy, variable-length noise, so the operator sees no recognizable
WireGuard pattern to match against — yet WireGuard itself still provides all the
real security. This was validated in practice: masked WireGuard completed a
handshake and carried live traffic over a mobile carrier that blocks plain
WireGuard on every port.

## Neden bu proje? (Türkçe)

Standart WireGuard, bir ağ operatörü için tanınması kolaydır: el sıkışma (handshake)
paketlerinin sabit bir deseni vardır — bir mesaj-tipi baytı, ardından sıfır baytlar,
ve sabit 148/92 baytlık boyutlar. Bazı GSM operatörleri ve internet sağlayıcıları tam
olarak bu parmak izini kullanıp WireGuard'ı **her portta** engeller; nasıl
yapılandırırsan yapılandır tünel bir türlü kurulmaz — oysa sıradan UDP trafiği akmaya
devam eder.

StealthWG tam da bunun için yazıldı. Her paketi yüksek entropili, değişken uzunlukta
bir gürültüye dönüştürür; böylece operatör eşleştirebileceği tanıdık bir WireGuard
deseni göremez — ama güvenliği yine WireGuard'ın kendisi sağlar. Pratikte
doğrulandı: maskeli WireGuard, düz WireGuard'ı her portta engelleyen bir GSM
operatörü üzerinden el sıkışmayı tamamladı ve canlı trafik taşıdı.

## Architecture

- **iOS App** — profile management, WireGuard config import, connect/disconnect, status.
- **PacketTunnel Extension** (`NEPacketTunnelProvider`) — WireGuardKit, the WireGuard
  engine, the obfuscation transport, and the UDP socket.

The transport is pluggable behind a single protocol, so the app is not tied to one
masking scheme:

```swift
protocol ObfuscationTransport {
    func send(_ packet: Data) async throws
    func receive() async throws -> Data
}
```

Planned implementations: `PlainUDPTransport`, `UdpMaskTransport`, and later
`QUICTransport` / `ShadowsocksTransport`.

## Roadmap

1. **Baseline** — plain WireGuard connection working through the Packet Tunnel Extension.
2. **UDP masking** — simple transport that alters the leading bytes (and optional
   random padding) of WireGuard packets, reversed on the server side.
3. **Automatic fallback** — try plain WireGuard → UDP mask → QUIC/UDP 443.

### First milestone — reached ✅

A successful WireGuard handshake from the app on a physical iPhone (over mobile
data) to a WireGuard endpoint behind a home gateway, on a carrier that blocks
plain WireGuard. Reached: masked handshake plus live traffic (internet and LAN).
The concept is validated end-to-end.

## Building

### iOS app

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), and the WireGuard engine is a
pinned `wireguard-apple` submodule that needs a small patch set (Xcode-current
build fixes today, the masking bind later).

```sh
brew install xcodegen go        # toolchain (Go builds the wireguard-go bridge)
./scripts/setup-wireguard.sh    # init the submodule + apply patches (idempotent)
cp Local.xcconfig.example Local.xcconfig   # then set your DEVELOPMENT_TEAM
xcodegen generate
open StealthWG.xcodeproj
```

The packet tunnel extension only runs on a physical device (Network Extensions do
not run in the Simulator), and the wireguard-go bridge builds for `iphoneos` only.

### Gateway

```sh
cd gateway && go test ./... && go build ./cmd/stealthwg-gateway
```

### Profile format

The app imports a standard wg-quick config with a StealthWG `[Stealth]` section.
`[Peer] Endpoint` points at the gateway's mask port; `MaskKey` is the shared
obfuscation PSK (base64), the same key the gateway runs with.

```ini
[Interface]
PrivateKey = <client private key>
Address = 10.0.0.2/32

[Peer]
PublicKey = <server public key>
Endpoint = <gateway public IP>:51819
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

[Stealth]
MaskKey = <base64 PSK>
```

Run the parser tests with `./scripts/test-parser.sh`.

## Design principles

- **Privacy by design.** No logging of user traffic. Keys never leave the device.
- **Security stays in WireGuard.** Obfuscation is fingerprint-breaking only, not a
  second crypto layer.

## Status

Proof of concept complete — masked WireGuard validated end-to-end (handshake and
live traffic) on a physical iPhone over a mobile carrier that blocks plain
WireGuard. Hardening and productization are ongoing.

## License

[MIT](LICENSE). Built on the MIT-licensed WireGuard Apple project.
