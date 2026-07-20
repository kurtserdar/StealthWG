# QUIC Transport (full) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Checkbox steps. Keep wireguard-go pinned to 2023 (do not `go mod tidy` it up).

**Goal:** Real QUIC transport (quic-go, DATAGRAM) as a sibling of UdpMask, across client + relay + all-in-one + profile + fallback + UI.

**Architecture:** A shared `quictransport` package; a client `wgbind.QUICBind` (conn.Bind); a relay QUIC mode; an all-in-one `QUICServerBind`; profile `Transport`/`SNI`; a bridge patch for transport selection; UI selectors.

**Tech Stack:** Go, quic-go (`github.com/quic-go/quic-go`, pure Go), wireguard-go (2023 pin), TLS, Swift bridge.

## Global Constraints

- CGO-free; cross-compiles linux amd64/arm64 + iphoneos. `wireguard-go` stays at the 2023 pin.
- Real quic-go; DATAGRAM frames; self-signed cert + configurable SNI; ALPN `h3`.
- Go units + Swift `scripts/test-parser.sh` green; device builds green.

## File Structure

- `quictransport/` — new module: `quic.go` (Dial/Listen/Session/SelfSignedCert) + tests (Task 1).
- `wgbind/quic_bind.go` — client QUICBind (Task 2).
- `Shared/StealthProfile.swift` — Transport/SNI parse (Task 3).
- `gateway/internal/relay` (+ config) — relay QUIC mode (Task 4).
- `gateway/internal/wgserver` — QUICServerBind + init flag (Task 5).
- `patches/wireguard-apple/0003-quic-transport.patch` + `Tunnel/*` + Swift wiring (Task 6).
- `App/Views/ProfileFormView.swift` + fallback wiring (Task 7).
- builds (Task 8).

---

### Task 1: `quictransport` package + tests

**Files:** new module `quictransport/{go.mod,quic.go,quic_test.go}`.

- [ ] **Step 1:** `go mod init github.com/kurtserdar/StealthWG/quictransport`; `go get github.com/quic-go/quic-go`.
- [ ] **Step 2: Write failing test** `quic_test.go`: start a `Listen` on `127.0.0.1:0` with `SelfSignedCert`, `Dial` to it (sni "example.com"), send a datagram client→server and server→client, assert round-trip.
- [ ] **Step 3: Implement** `quic.go`:
  - `SelfSignedCert() (tls.Certificate, error)` — ephemeral ed25519/ECDSA cert.
  - `type Session` wrapping `quic.Connection` with `SendDatagram([]byte) error`, `ReceiveDatagram(ctx) ([]byte, error)`.
  - `Dial(ctx, addr, sni string) (*Session, error)` — `quic.DialAddr` with `tls.Config{InsecureSkipVerify:true, ServerName:sni, NextProtos:["h3"]}`, `quic.Config{EnableDatagrams:true}`.
  - `Listen(addr string, cert tls.Certificate) (*Listener, error)` — `quic.ListenAddr` with datagrams; `Accept(ctx) (*Session, error)`.
- [ ] **Step 4:** `cd quictransport && go test ./...` → ok; `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build ./...`.
- [ ] **Step 5: Commit.**

---

### Task 2: `wgbind.QUICBind`

**Files:** `wgbind/quic_bind.go` (+ go.mod add quictransport + quic-go), `wgbind/quic_bind_test.go`.

- [ ] QUICBind implements `conn.Bind`: `Open` dials the session lazily on first `Send`/from the configured endpoint; a receive func reads datagrams; `Send` writes a datagram; `ParseEndpoint`/`Close`/`SetMark`. Test: round-trip through a `quictransport.Listen` echo server (mirrors MaskBind's fake-gateway test). Cross-compile check.

---

### Task 3: `StealthProfile` Transport/SNI

**Files:** `Shared/StealthProfile.swift`, `Tests/StealthProfileTests.swift`.

- [ ] Parse `[Stealth] Transport` (default `"mask"`) + `SNI`; add to the struct + `serialize`; round-trip test. Store both in `providerConfiguration` in `TunnelManager`.

---

### Task 4: Relay QUIC mode

**Files:** `gateway/internal/relay`, `gateway/internal/config`, `gateway/cmd/stealthwg-gateway`.

- [ ] Add a QUIC listener (`STEALTHWG_QUIC=:443`): accept sessions, per-session forward each datagram to the upstream WG over UDP, relay replies back on the session (reuse the session/GC model). Runs alongside the mask listener. Go test with a loopback upstream.

---

### Task 5: All-in-one `QUICServerBind`

**Files:** `gateway/internal/wgserver/quicbind.go`, `engine.go`, `cmd/stealthwg`.

- [ ] `QUICServerBind` (conn.Bind) over `quictransport.Listener`: map connection↔synthetic endpoint; receive tags datagrams, `Send` routes by endpoint. `engine.Start` uses it when `Transport==quic`; `stealthwg init --transport quic --listen 443`. Cross-compile check.

---

### Task 6: Bridge patch + Swift wiring

**Files:** `patches/wireguard-apple/0003-quic-transport.patch`, `scripts/setup-wireguard.sh`, `Tunnel/StealthBridge.h`, `Tunnel/PacketTunnelProvider.swift`.

- [ ] Add `wgSetTransport(mode, sni)` export; `wgTurnOn` builds `QUICBind` when `mode=="quic"`. Bridge go.mod requires wgbind/quictransport/quic-go (replace paths). Swift passes transport+SNI from `providerConfiguration`. Unsigned iOS + macOS device builds green (libwg-go.a links QUIC).

---

### Task 7: UI + fallback

**Files:** `App/Views/ProfileFormView.swift`, `App/Views/ProfileDetailView.swift`, fallback wiring.

- [ ] Form: **Transport** picker (Mask/QUIC) + **SNI** (advanced), written into the built profile. Fallback endpoints carry a transport; the endpoint loop dials mask or QUIC accordingly (extend `PacketTunnelProvider` + `[Stealth] Endpoints` to allow a `quic://host:443` scheme). iOS + macOS builds green.

---

### Task 8: Full build + tests

- [ ] `go test ./...` in quictransport/wgbind/gateway; `bash scripts/test-parser.sh`; unsigned iOS + macOS device builds; all green.

---

## Self-Review

- **Spec coverage:** quictransport (T1), client QUICBind (T2), profile (T3), relay QUIC (T4), all-in-one QUIC (T5), bridge+Swift (T6), UI+fallback (T7), builds (T8). ✓
- **Placeholder scan:** Tasks specify concrete files + the quic-go/conn.Bind APIs; view/patch bodies written during implementation against these contracts.
- **Type/name consistency:** `quictransport.Dial/Listen/Session/SelfSignedCert` consumed by QUICBind (T2), relay (T4), QUICServerBind (T5). `wgSetTransport(mode,sni)` (T6) matches the Swift call. `StealthProfile.transport/sni` (T3) flow to the bridge (T6) and UI (T7).
