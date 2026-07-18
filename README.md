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

### First milestone

A successful WireGuard handshake from the app on a physical iPhone (over mobile
data) to a WireGuard endpoint behind a home gateway. That validates the concept
end-to-end; UI, fallback, and containerized server gateway come after.

## Design principles

- **Privacy by design.** No logging of user traffic. Keys never leave the device.
- **Security stays in WireGuard.** Obfuscation is fingerprint-breaking only, not a
  second crypto layer.

## Status

Early development. See the roadmap above for current scope.

## License

[MIT](LICENSE). Built on the MIT-licensed WireGuard Apple project.
