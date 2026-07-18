# UdpMask Transport & Gateway — Design

**Status:** Approved (2026-07-18)
**Scope:** The device-independent half of Phase 1 — the obfuscation wire format,
the reference codec, and the server-side gateway. iOS/WireGuardKit wiring and the
real on-device handshake are a later step and are out of scope here.

## 1. Problem & threat model

The adversary is any **DPI-based network operator** — mobile carriers (GSM/LTE/5G)
and fixed-line ISPs — that inspects traffic and blocks WireGuard by its protocol
signature. The observed behaviour on the first validation network (a mobile
carrier) is representative of the class: WireGuard is blocked on **every** UDP
port while non-WireGuard UDP keeps working. This points to
**protocol fingerprinting**, not port or blanket-UDP blocking. WireGuard is easy
to fingerprint:

- Handshake initiation: first byte `0x01`, then three reserved `0x00` bytes,
  fixed total length **148 bytes**.
- Handshake response: first byte `0x02`, fixed **92 bytes**.
- Cookie / data messages: first byte `0x03` / `0x04`, then three `0x00` bytes.

So the on-wire signature is *"type byte in {1,2,3,4} followed by three zero bytes,
plus fixed handshake sizes."*

**Strategy:** reshape the WireGuard packet into a **high-entropy, variable-length
UDP payload** with no fixed bytes, so it no longer matches the WireGuard
fingerprint. On networks where generic UDP passes (the common case for the
fingerprinting operators above), this is sufficient and we do **not** need
protocol mimicry (looking like QUIC/DNS). Mimicry is deliberately deferred; done
poorly it becomes a *more* reliable fingerprint (cf. "The Parrot is Dead",
Houmansadr et al., 2013). Operators that block all UDP are handled later by a
separate TCP/443 transport behind the same interface, not by this one.

**Non-goal:** this layer provides **no** cryptographic security. All security
comes from WireGuard's own Noise protocol. The keyed transform here is a *quality
noise generator*, not a cipher, and carries no MAC — tampered bytes are rejected
by WireGuard itself.

## 2. Transport architecture (extensibility)

Obfuscation lives behind a single protocol so the product is multi-transport from
day one, with an automatic fallback chain:

```
ObfuscationTransport (interface)
├── PlainUDPTransport   — passthrough plain WireGuard (baseline / fallback)
├── UdpMaskTransport    — keyed random-noise  (implemented first)
├── QUICMaskTransport   — look like QUIC/443   (deferred)
├── DNSMaskTransport    — look like DNS         (deferred)
└── TCPTransport        — if all UDP is ever blocked (deferred)
```

```swift
protocol ObfuscationTransport {
    func send(_ packet: Data) async throws
    func receive() async throws -> Data
}
```

Only `PlainUDPTransport` and `UdpMaskTransport` are in scope now. The others are
future implementations behind the same interface, added when a validated need
appears.

## 3. UdpMask wire format

Every UDP datagram carries exactly one WireGuard packet:

```
┌──────────────┬──────────────────────────────────────────────┐
│ nonce (12 B) │ ciphertext                                    │
│ random, clear│ = keystream XOR ( plen(2 B) ‖ wg_packet ‖ pad)│
└──────────────┴──────────────────────────────────────────────┘
```

- `nonce` — 12 random bytes, sent in the clear. New per packet.
- `plen` — length of `wg_packet`, unsigned big-endian 2 bytes.
- `wg_packet` — the original WireGuard UDP payload emitted by the engine.
- `pad` — `0..PADMAX` random bytes; length chosen at random per packet.
- `keystream` — `ChaCha20(key, nonce, counter=0)` XORed over
  `plen ‖ wg_packet ‖ pad`.
- `key` — `HKDF-SHA256(ikm = PSK, info = "stealthwg/udpmask/v1")`, 32 bytes.

### Properties

- **No fixed bytes.** The leading bytes are a random nonce; the remainder is
  keystream-XORed, so it is indistinguishable from random. The WireGuard
  type-byte + zero-bytes signature is gone.
- **Variable length.** `pad` breaks the fixed 148/92 handshake sizes.
- **No on-wire version.** The protocol version is folded into the HKDF `info`
  string, so `v1`/`v2` derive different keystreams with no version byte on the
  wire. v1 is the only version for now; the gateway assumes v1.
- **No authentication.** Intentionally. WireGuard rejects corrupted inner
  packets; adding a MAC would be a security claim we do not make here.

### Framing rules

- Minimum valid datagram length: `12 (nonce) + 2 (plen) = 14` bytes. Shorter is
  dropped.
- After decrypt, `plen` must satisfy `plen <= len(ciphertext) - 2`. Otherwise the
  datagram is malformed and dropped.
- `PADMAX` is a tunable (default proposed: 32). Padding primarily matters for the
  fixed-size handshake packets; data packets already vary.

## 4. Keying (PSK)

- A dedicated **obfuscation PSK**, independent of WireGuard's optional
  `PresharedKey` (no layer mixing).
- Client side: carried in a StealthWG-specific `[Stealth]` section of our own
  profile format, so the standard `[Interface]`/`[Peer]` sections stay clean and
  are parsed by our own importer (not `wg-quick`):

  ```
  [Stealth]
  MaskKey = <base64 32-byte PSK>
  # The [Peer] Endpoint points at the gateway's mask port (e.g. host:51819).
  ```

- Gateway side: the same PSK in the gateway config.
- The PSK is the input keying material to HKDF; it is never sent on the wire.

## 5. Gateway (Go)

Chosen language: **Go** — matches the wireguard-go ecosystem, compiles to a
single static binary (easy Docker today, easy ARM64 cross-compile for the
RB5009 container later), and `golang.org/x/crypto/chacha20` + `.../hkdf` are
available.

### Behaviour — UDP relay

```
Internet ──mask──▶ :51819 (gateway) ──unmask──▶ upstream WireGuard :51820
                        ◀──mask──                ◀──plain──
```

- Listen for masked datagrams on `-listen` (e.g. `:51819`).
- For each client source address, lazily create a dedicated upstream UDP socket
  to `-upstream` (the real WireGuard endpoint). Maintain a
  `clientAddr → upstreamSocket` session map with a `lastSeen` timestamp.
- Client → upstream: unmask the datagram, write `wg_packet` to the upstream
  socket.
- Upstream → client: read the plain WireGuard reply, mask it, send to the client
  address.
- Garbage-collect idle sessions after `-timeout` (default 180s, longer than the
  WireGuard keepalive).

### Probe resistance

Datagrams that are too short or fail to decrypt cleanly are **dropped silently**
— never answered — so the gateway does not act as a probe oracle that reveals it
is a proxy.

### Configuration

| Flag        | Meaning                                   | Default    |
|-------------|-------------------------------------------|------------|
| `-listen`   | mask-side UDP listen address              | `:51819`   |
| `-upstream` | real WireGuard endpoint                   | (required) |
| `-psk`      | obfuscation PSK (or `-psk-file`)          | (required) |
| `-timeout`  | idle session timeout                      | `180s`     |
| `-padmax`   | maximum random padding per packet (bytes) | `32`       |

## 6. Cross-implementation interop

The Go (gateway) and Swift (client) codecs must produce **byte-identical**
output. This is guaranteed by a shared set of **test vectors**:

```json
{ "psk": "...", "nonce": "...", "wg": "...", "pad": "...", "masked": "..." }
```

All fields are base64. `pad` is included because it is XORed into the keystream,
so `masked` is **not** reproducible from `(psk, nonce, wg)` alone. Both
implementations must reproduce `masked` from `(psk, nonce, wg, pad)` and recover
`wg` from `masked`. To make this testable, `mask()` takes the nonce and pad as
explicit parameters; production `send()` generates a random nonce and padding.

The Swift codec is written during the WireGuardKit integration step and validated
against the same vectors; this phase produces the vectors from the Go side.

## 7. MTU budget

Masking adds `12 (nonce) + 2 (plen) + pad` bytes of overhead. To keep the outer
UDP datagram under the path MTU on real-world carrier/ISP paths (safe target
≈ 1280 bytes),
the WireGuard interface MTU must be lowered from its 1420 default. Exact value is
tuned against real measurements during on-device testing; the codec itself does
not hardcode it.

## 8. Deliverables for this phase (device-independent)

1. This wire-format spec.
2. The Go gateway (unmask relay), runnable and testable on the Mac.
3. A Go reference codec with round-trip tests and an exported set of interop test
   vectors.
4. Recorded MTU-budget note for the later on-device tuning step.

Out of scope here: the Swift `UdpMaskTransport`, WireGuardKit/Go bridge
integration, and the real on-device handshake through a fingerprinting carrier
(first validated on Vodafone → RB5009) — all handled in the subsequent on-device
phase.
