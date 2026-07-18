# UdpMask Gateway & Codec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the device-independent half of Phase 1 — a Go reference codec for the UdpMask wire format, frozen interop test vectors, and a runnable UDP gateway that unmasks client traffic and relays it to an unmodified upstream WireGuard endpoint.

**Architecture:** A `mask` package implements the wire format (ChaCha20 keystream keyed by `HKDF-SHA256(PSK)`, random nonce + random padding, no MAC). A `relay` package is a NAT-like UDP relay: it opens a per-client upstream socket, unmasks client→upstream traffic and masks upstream→client replies, and garbage-collects idle sessions. A thin `cmd` wires flags into codec + relay under a signal-cancelled context.

**Tech Stack:** Go 1.25+ (floor set by `golang.org/x/crypto`), `golang.org/x/crypto/chacha20`, `golang.org/x/crypto/hkdf`, standard `net`/`crypto/rand`.

## Global Constraints

- All code comments in English.
- Go module path: `github.com/kurtserdar/StealthWG/gateway`; module rooted at `gateway/`.
- The `go` directive tracks the minor floor required by dependencies (currently `go 1.25.0` for `golang.org/x/crypto`); never pin an exact patch version (e.g. `1.26.5`).
- Wire format is authoritative in `docs/design/2026-07-18-udpmask-transport.md`; do not deviate.
- Key derivation: `HKDF-SHA256(ikm = PSK, salt = nil, info = "stealthwg/udpmask/v1")` → 32-byte key. Protocol version lives only in the `info` string — **no version byte on the wire**.
- Datagram layout: `nonce(12) ‖ ChaCha20_keystream ⊕ ( plen(2, big-endian) ‖ wg_packet ‖ pad )`.
- Nonce size = 12 bytes (ChaCha20). Length prefix = 2 bytes. Minimum valid datagram = 14 bytes.
- `PADMAX` default = 32; allowed range 0..255.
- **No MAC / no authentication** — this layer is obfuscation, not security.
- Malformed or undecryptable datagrams are **dropped silently** (no reply) — probe resistance.
- Commit messages: no Claude/Anthropic signature, no `Co-Authored-By`.

---

### Task 1: Go module + codec key derivation and deterministic mask/open

**Files:**
- Create: `gateway/go.mod`
- Create: `gateway/internal/mask/mask.go`
- Test: `gateway/internal/mask/mask_test.go`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `func NewCodec(psk []byte, padMax int) (*Codec, error)`
  - `func (c *Codec) MaskWith(nonce, wg, pad []byte) ([]byte, error)` — deterministic; used by tests and by `Seal`.
  - `func (c *Codec) Open(datagram []byte) ([]byte, error)` — returns the recovered `wg_packet`, or an error to drop on.
  - Sentinel errors: `ErrShortDatagram`, `ErrMalformed`, `ErrNonceSize`, `ErrTooLong`, `ErrNoPSK`, `ErrPadMax`.
  - Exported const: `NonceSize = 12`.

- [ ] **Step 1: Initialize the Go module and add dependencies**

```bash
cd gateway
go mod init github.com/kurtserdar/StealthWG/gateway
go get golang.org/x/crypto/chacha20@latest
go get golang.org/x/crypto/hkdf@latest
```

Expected: `go.mod` and `go.sum` created listing `golang.org/x/crypto`.

- [ ] **Step 2: Write the failing round-trip test**

Create `gateway/internal/mask/mask_test.go`:

```go
package mask

import (
	"bytes"
	"testing"
)

func testCodec(t *testing.T) *Codec {
	t.Helper()
	c, err := NewCodec([]byte("unit-test-psk-0123456789"), 32)
	if err != nil {
		t.Fatalf("NewCodec: %v", err)
	}
	return c
}

func TestMaskOpenRoundTrip(t *testing.T) {
	c := testCodec(t)
	nonce := make([]byte, NonceSize) // all-zero nonce is fine for a test
	wg := []byte("this stands in for a WireGuard packet")
	pad := []byte{0xaa, 0xbb, 0xcc}

	datagram, err := c.MaskWith(nonce, wg, pad)
	if err != nil {
		t.Fatalf("MaskWith: %v", err)
	}
	if bytes.Contains(datagram[NonceSize:], wg) {
		t.Fatal("plaintext leaked into ciphertext region")
	}

	got, err := c.Open(datagram)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(got, wg) {
		t.Fatalf("round trip mismatch: got %q want %q", got, wg)
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd gateway && go test ./internal/mask/ -run TestMaskOpenRoundTrip -v`
Expected: FAIL — build error, `NewCodec`/`MaskWith`/`Open`/`NonceSize` undefined.

- [ ] **Step 4: Write the codec implementation**

Create `gateway/internal/mask/mask.go`:

```go
// Package mask implements the StealthWG UdpMask wire format: a keyed,
// random-looking obfuscation of WireGuard UDP packets. It provides no
// cryptographic security — WireGuard's own Noise protocol does that. The
// keystream here is a quality noise generator that erases WireGuard's
// fingerprint (fixed type/zero bytes and fixed handshake lengths).
package mask

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"

	"golang.org/x/crypto/chacha20"
	"golang.org/x/crypto/hkdf"
)

// NonceSize is the per-packet ChaCha20 nonce length, sent in the clear.
const NonceSize = 12

const (
	lenPrefix    = 2  // big-endian uint16 length of wg_packet
	minDatagram  = NonceSize + lenPrefix
	infoV1       = "stealthwg/udpmask/v1"
	maxWGPacket  = 65535 // bounded by the 2-byte length prefix
)

var (
	ErrShortDatagram = errors.New("mask: datagram shorter than minimum")
	ErrMalformed     = errors.New("mask: declared length exceeds datagram")
	ErrNonceSize     = errors.New("mask: nonce must be 12 bytes")
	ErrTooLong       = errors.New("mask: wg packet exceeds 65535 bytes")
	ErrNoPSK         = errors.New("mask: empty PSK")
	ErrPadMax        = errors.New("mask: padMax out of range 0..255")
)

// Codec masks and opens datagrams under a single derived key.
type Codec struct {
	key    [32]byte
	padMax int
}

// NewCodec derives the obfuscation key from the pre-shared key via HKDF and
// returns a codec. padMax bounds the random padding added per packet.
func NewCodec(psk []byte, padMax int) (*Codec, error) {
	if len(psk) == 0 {
		return nil, ErrNoPSK
	}
	if padMax < 0 || padMax > 255 {
		return nil, ErrPadMax
	}
	c := &Codec{padMax: padMax}
	r := hkdf.New(sha256.New, psk, nil, []byte(infoV1))
	if _, err := io.ReadFull(r, c.key[:]); err != nil {
		return nil, err
	}
	return c, nil
}

// MaskWith builds a datagram from an explicit nonce and padding. It is
// deterministic, which makes it usable for interop test vectors; production
// code uses Seal to supply a random nonce and padding.
func (c *Codec) MaskWith(nonce, wg, pad []byte) ([]byte, error) {
	if len(nonce) != NonceSize {
		return nil, ErrNonceSize
	}
	if len(wg) > maxWGPacket {
		return nil, ErrTooLong
	}
	pt := make([]byte, lenPrefix+len(wg)+len(pad))
	binary.BigEndian.PutUint16(pt[:lenPrefix], uint16(len(wg)))
	copy(pt[lenPrefix:], wg)
	copy(pt[lenPrefix+len(wg):], pad)

	cipher, err := chacha20.NewUnauthenticatedCipher(c.key[:], nonce)
	if err != nil {
		return nil, err
	}
	cipher.XORKeyStream(pt, pt)

	out := make([]byte, NonceSize+len(pt))
	copy(out[:NonceSize], nonce)
	copy(out[NonceSize:], pt)
	return out, nil
}

// Open recovers the wg_packet from a datagram. Any structural problem returns
// an error so the caller can drop the datagram silently.
func (c *Codec) Open(datagram []byte) ([]byte, error) {
	if len(datagram) < minDatagram {
		return nil, ErrShortDatagram
	}
	nonce := datagram[:NonceSize]
	ct := datagram[NonceSize:]

	pt := make([]byte, len(ct))
	cipher, err := chacha20.NewUnauthenticatedCipher(c.key[:], nonce)
	if err != nil {
		return nil, err
	}
	cipher.XORKeyStream(pt, ct)

	plen := int(binary.BigEndian.Uint16(pt[:lenPrefix]))
	if plen > len(pt)-lenPrefix {
		return nil, ErrMalformed
	}
	out := make([]byte, plen)
	copy(out, pt[lenPrefix:lenPrefix+plen])
	return out, nil
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd gateway && go test ./internal/mask/ -run TestMaskOpenRoundTrip -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add gateway/go.mod gateway/go.sum gateway/internal/mask/mask.go gateway/internal/mask/mask_test.go
git commit -m "Add UdpMask codec: key derivation, deterministic mask/open"
```

---

### Task 2: Production Seal (random nonce/padding) and malformed-input handling

**Files:**
- Modify: `gateway/internal/mask/mask.go`
- Test: `gateway/internal/mask/mask_test.go`

**Interfaces:**
- Consumes: `Codec`, `MaskWith`, `Open`, sentinel errors from Task 1.
- Produces: `func (c *Codec) Seal(wg []byte) ([]byte, error)` — random nonce + random padding in `[0, padMax]`.

- [ ] **Step 1: Write the failing tests**

Append to `gateway/internal/mask/mask_test.go`:

```go
func TestSealOpenRoundTripAndVariesLength(t *testing.T) {
	c := testCodec(t)
	wg := []byte("wireguard-ish payload for seal test")

	sizes := map[int]bool{}
	for i := 0; i < 64; i++ {
		datagram, err := c.Seal(wg)
		if err != nil {
			t.Fatalf("Seal: %v", err)
		}
		sizes[len(datagram)] = true

		got, err := c.Open(datagram)
		if err != nil {
			t.Fatalf("Open sealed: %v", err)
		}
		if string(got) != string(wg) {
			t.Fatalf("sealed round trip mismatch: got %q want %q", got, wg)
		}
	}
	// Random padding must produce at least two distinct datagram lengths.
	if len(sizes) < 2 {
		t.Fatalf("expected varying datagram lengths, got %d distinct", len(sizes))
	}
}

func TestOpenRejectsMalformed(t *testing.T) {
	c := testCodec(t)

	if _, err := c.Open([]byte{0x00, 0x01, 0x02}); err != ErrShortDatagram {
		t.Fatalf("short datagram: got %v want ErrShortDatagram", err)
	}

	// A 14-byte datagram whose decrypted length prefix claims more bytes than
	// exist must be rejected. Build one deterministically then truncate padding.
	nonce := make([]byte, NonceSize)
	full, err := c.MaskWith(nonce, []byte("abcd"), nil) // plen = 4, total 18 bytes
	if err != nil {
		t.Fatalf("MaskWith: %v", err)
	}
	truncated := full[:minDatagram+1] // keeps plen=4 but only 1 body byte
	if _, err := c.Open(truncated); err != ErrMalformed {
		t.Fatalf("truncated datagram: got %v want ErrMalformed", err)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd gateway && go test ./internal/mask/ -run 'TestSeal|TestOpenRejects' -v`
Expected: FAIL — `Seal` undefined (build error).

- [ ] **Step 3: Implement Seal**

Add imports `crypto/rand` and `math/big` to `mask.go`, and append:

```go
// Seal masks a wg packet with a fresh random nonce and random padding. This is
// the production path; MaskWith is the deterministic core it delegates to.
func (c *Codec) Seal(wg []byte) ([]byte, error) {
	if len(wg) > maxWGPacket {
		return nil, ErrTooLong
	}
	nonce := make([]byte, NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	padLen := 0
	if c.padMax > 0 {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(c.padMax+1)))
		if err != nil {
			return nil, err
		}
		padLen = int(n.Int64())
	}
	pad := make([]byte, padLen)
	if padLen > 0 {
		if _, err := rand.Read(pad); err != nil {
			return nil, err
		}
	}
	return c.MaskWith(nonce, wg, pad)
}
```

Update the import block at the top of `mask.go` to include the new packages:

```go
import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"
	"math/big"

	"golang.org/x/crypto/chacha20"
	"golang.org/x/crypto/hkdf"
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd gateway && go test ./internal/mask/ -v`
Expected: PASS (all mask tests).

- [ ] **Step 5: Commit**

```bash
git add gateway/internal/mask/mask.go gateway/internal/mask/mask_test.go
git commit -m "Add Seal with random nonce/padding and malformed-input rejection"
```

---

### Task 3: Frozen interop test vectors

**Files:**
- Create: `gateway/internal/mask/testdata/vectors.json`
- Test: `gateway/internal/mask/vectors_test.go`

**Interfaces:**
- Consumes: `NewCodec`, `MaskWith`, `Open` from Task 1.
- Produces: `gateway/internal/mask/testdata/vectors.json` — the frozen golden vectors the Swift client codec must also reproduce. JSON array of objects with base64 fields `psk`, `nonce`, `wg`, `pad`, `masked`.

- [ ] **Step 1: Write the vectors test with a golden-update flag**

Create `gateway/internal/mask/vectors_test.go`:

```go
package mask

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
)

var updateVectors = flag.Bool("update", false, "regenerate testdata/vectors.json")

type vector struct {
	PSK    string `json:"psk"`
	Nonce  string `json:"nonce"`
	WG     string `json:"wg"`
	Pad    string `json:"pad"`
	Masked string `json:"masked"`
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func mustDecode(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatalf("base64 decode: %v", err)
	}
	return b
}

// vectorInputs are the fixed (psk, nonce, wg, pad) tuples. Keep these stable;
// the committed vectors.json is the interop contract with the Swift codec.
func vectorInputs() []vector {
	psk := []byte("stealthwg-interop-psk-v1")
	zeros := make([]byte, NonceSize)
	nonceA := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	return []vector{
		{PSK: b64(psk), Nonce: b64(zeros), WG: b64([]byte{0x01, 0x00, 0x00, 0x00}), Pad: b64(nil)},
		{PSK: b64(psk), Nonce: b64(nonceA), WG: b64([]byte("hello wireguard")), Pad: b64([]byte{0xde, 0xad})},
		{PSK: b64(psk), Nonce: b64(nonceA), WG: b64(make([]byte, 1400)), Pad: b64([]byte{0x00, 0xff, 0x10})},
	}
}

func goldenPath() string { return filepath.Join("testdata", "vectors.json") }

func TestInteropVectors(t *testing.T) {
	inputs := vectorInputs()

	// Fill in the Masked field by running the codec over each input.
	generated := make([]vector, len(inputs))
	for i, in := range inputs {
		c, err := NewCodec(mustDecode(t, in.PSK), 32)
		if err != nil {
			t.Fatalf("NewCodec: %v", err)
		}
		masked, err := c.MaskWith(mustDecode(t, in.Nonce), mustDecode(t, in.WG), mustDecode(t, in.Pad))
		if err != nil {
			t.Fatalf("MaskWith: %v", err)
		}
		in.Masked = b64(masked)
		generated[i] = in

		// Open must recover the original wg bytes.
		got, err := c.Open(masked)
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		if b64(got) != in.WG {
			t.Fatalf("vector %d: open mismatch", i)
		}
	}

	if *updateVectors {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		data, err := json.MarshalIndent(generated, "", "  ")
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		if err := os.WriteFile(goldenPath(), append(data, '\n'), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
	}

	// Compare against the committed golden file.
	want, err := os.ReadFile(goldenPath())
	if err != nil {
		t.Fatalf("read golden (run with -update first): %v", err)
	}
	var golden []vector
	if err := json.Unmarshal(want, &golden); err != nil {
		t.Fatalf("unmarshal golden: %v", err)
	}
	if len(golden) != len(generated) {
		t.Fatalf("golden has %d vectors, generated %d", len(golden), len(generated))
	}
	for i := range golden {
		if golden[i].Masked != generated[i].Masked {
			t.Fatalf("vector %d drift: golden %s generated %s", i, golden[i].Masked, generated[i].Masked)
		}
	}
}
```

- [ ] **Step 2: Run to verify it fails (no golden yet)**

Run: `cd gateway && go test ./internal/mask/ -run TestInteropVectors -v`
Expected: FAIL — `read golden ...: open testdata/vectors.json: no such file or directory`.

- [ ] **Step 3: Generate the golden vectors**

Run: `cd gateway && go test ./internal/mask/ -run TestInteropVectors -update`
Expected: PASS; `gateway/internal/mask/testdata/vectors.json` now exists.

- [ ] **Step 4: Verify the golden is now enforced**

Run: `cd gateway && go test ./internal/mask/ -run TestInteropVectors -v`
Expected: PASS (comparing against the committed golden).

- [ ] **Step 5: Commit**

```bash
git add gateway/internal/mask/vectors_test.go gateway/internal/mask/testdata/vectors.json
git commit -m "Add frozen interop test vectors for the UdpMask codec"
```

---

### Task 4: UDP relay with per-client sessions and idle GC

**Files:**
- Create: `gateway/internal/relay/relay.go`
- Test: `gateway/internal/relay/relay_test.go`

**Interfaces:**
- Consumes: `mask.Codec` (`Open`, `Seal`) from Tasks 1–2.
- Produces:
  - `func New(listenAddr, upstreamAddr string, codec *mask.Codec, timeout time.Duration) (*Relay, error)`
  - `func (r *Relay) LocalAddr() net.Addr` — the bound listen address (useful when listening on `:0`).
  - `func (r *Relay) Run(ctx context.Context) error` — blocks until ctx is cancelled, then closes sockets.

- [ ] **Step 1: Write the failing end-to-end relay test**

Create `gateway/internal/relay/relay_test.go`:

```go
package relay

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/kurtserdar/StealthWG/gateway/internal/mask"
)

// startEchoUpstream stands in for the real WireGuard server: it echoes any
// datagram back to its sender.
func startEchoUpstream(t *testing.T) *net.UDPConn {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen upstream: %v", err)
	}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			conn.WriteToUDP(buf[:n], addr)
		}
	}()
	return conn
}

func TestRelayRoundTrip(t *testing.T) {
	upstream := startEchoUpstream(t)
	defer upstream.Close()

	codec, err := mask.NewCodec([]byte("relay-test-psk-000000000"), 32)
	if err != nil {
		t.Fatalf("NewCodec: %v", err)
	}

	r, err := New("127.0.0.1:0", upstream.LocalAddr().String(), codec, 2*time.Second)
	if err != nil {
		t.Fatalf("New relay: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(ctx)

	client, err := net.DialUDP("udp", nil, r.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatalf("dial relay: %v", err)
	}
	defer client.Close()

	wg := []byte("packet that should survive the round trip")
	masked, err := codec.Seal(wg)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if _, err := client.Write(masked); err != nil {
		t.Fatalf("client write: %v", err)
	}

	client.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 65535)
	n, err := client.Read(buf)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	got, err := codec.Open(buf[:n])
	if err != nil {
		t.Fatalf("open reply: %v", err)
	}
	if string(got) != string(wg) {
		t.Fatalf("round trip mismatch: got %q want %q", got, wg)
	}
}

func TestRelayDropsGarbageSilently(t *testing.T) {
	upstream := startEchoUpstream(t)
	defer upstream.Close()
	codec, _ := mask.NewCodec([]byte("relay-test-psk-000000000"), 32)

	r, err := New("127.0.0.1:0", upstream.LocalAddr().String(), codec, 2*time.Second)
	if err != nil {
		t.Fatalf("New relay: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(ctx)

	client, _ := net.DialUDP("udp", nil, r.LocalAddr().(*net.UDPAddr))
	defer client.Close()

	// A datagram shorter than the 14-byte minimum can never be a valid frame,
	// so the relay must drop it silently and never reply (probe resistance).
	client.Write([]byte("tooshort"))
	client.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	buf := make([]byte, 65535)
	if _, err := client.Read(buf); err == nil {
		t.Fatal("expected no reply to garbage, got one")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd gateway && go test ./internal/relay/ -v`
Expected: FAIL — build error, `New`/`Run`/`LocalAddr` undefined.

- [ ] **Step 3: Implement the relay**

Create `gateway/internal/relay/relay.go`:

```go
// Package relay is a NAT-like UDP relay. It receives masked datagrams from
// clients, unmasks them and forwards the inner WireGuard packet to an
// unmodified upstream WireGuard endpoint, then masks replies back to the
// originating client. Per-client sessions are garbage-collected when idle.
package relay

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/kurtserdar/StealthWG/gateway/internal/mask"
)

type session struct {
	clientAddr *net.UDPAddr
	upstream   *net.UDPConn
	lastSeen   time.Time
}

// Relay forwards masked client traffic to an upstream WireGuard endpoint.
type Relay struct {
	listen   *net.UDPConn
	upstream *net.UDPAddr
	codec    *mask.Codec
	timeout  time.Duration

	mu       sync.Mutex
	sessions map[string]*session
}

// New binds the listen socket and resolves the upstream address.
func New(listenAddr, upstreamAddr string, codec *mask.Codec, timeout time.Duration) (*Relay, error) {
	lAddr, err := net.ResolveUDPAddr("udp", listenAddr)
	if err != nil {
		return nil, err
	}
	uAddr, err := net.ResolveUDPAddr("udp", upstreamAddr)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", lAddr)
	if err != nil {
		return nil, err
	}
	return &Relay{
		listen:   conn,
		upstream: uAddr,
		codec:    codec,
		timeout:  timeout,
		sessions: make(map[string]*session),
	}, nil
}

// LocalAddr returns the bound listen address.
func (r *Relay) LocalAddr() net.Addr { return r.listen.LocalAddr() }

// Run processes datagrams until ctx is cancelled.
func (r *Relay) Run(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		r.listen.Close()
		r.mu.Lock()
		for _, s := range r.sessions {
			s.upstream.Close()
		}
		r.mu.Unlock()
	}()
	go r.gcLoop(ctx)

	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := r.listen.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
				return err
			}
		}
		wg, err := r.codec.Open(buf[:n])
		if err != nil {
			continue // drop silently
		}
		s := r.getOrCreate(clientAddr)
		if s == nil {
			continue
		}
		s.upstream.Write(wg)
		r.touch(s)
	}
}

func (r *Relay) getOrCreate(clientAddr *net.UDPAddr) *session {
	key := clientAddr.String()
	r.mu.Lock()
	defer r.mu.Unlock()
	if s, ok := r.sessions[key]; ok {
		return s
	}
	up, err := net.DialUDP("udp", nil, r.upstream)
	if err != nil {
		return nil
	}
	s := &session{clientAddr: clientAddr, upstream: up, lastSeen: time.Now()}
	r.sessions[key] = s
	go r.upstreamReader(s)
	return s
}

// upstreamReader masks upstream replies back to the client until the socket
// is closed (by GC or shutdown).
func (r *Relay) upstreamReader(s *session) {
	buf := make([]byte, 65535)
	for {
		n, err := s.upstream.Read(buf)
		if err != nil {
			return
		}
		masked, err := r.codec.Seal(buf[:n])
		if err != nil {
			continue
		}
		r.listen.WriteToUDP(masked, s.clientAddr)
		r.touch(s)
	}
}

func (r *Relay) touch(s *session) {
	r.mu.Lock()
	s.lastSeen = time.Now()
	r.mu.Unlock()
}

func (r *Relay) gcLoop(ctx context.Context) {
	ticker := time.NewTicker(r.timeout / 2)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			now := time.Now()
			r.mu.Lock()
			for key, s := range r.sessions {
				if now.Sub(s.lastSeen) > r.timeout {
					s.upstream.Close()
					delete(r.sessions, key)
				}
			}
			r.mu.Unlock()
		}
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd gateway && go test ./internal/relay/ -v`
Expected: PASS (both `TestRelayRoundTrip` and `TestRelayDropsGarbageSilently`).

- [ ] **Step 5: Run the race detector on the relay**

Run: `cd gateway && go test -race ./internal/relay/ -v`
Expected: PASS with no data races reported.

- [ ] **Step 6: Commit**

```bash
git add gateway/internal/relay/relay.go gateway/internal/relay/relay_test.go
git commit -m "Add UDP relay with per-client sessions and idle GC"
```

---

### Task 5: CLI wiring (config parsing + main)

**Files:**
- Create: `gateway/internal/config/config.go`
- Create: `gateway/cmd/stealthwg-gateway/main.go`
- Test: `gateway/internal/config/config_test.go`

**Interfaces:**
- Consumes: `mask.NewCodec`, `relay.New`, `relay.Run`.
- Produces:
  - `type Config struct { Listen, Upstream string; PSK []byte; Timeout time.Duration; PadMax int }`
  - `func Parse(args []string) (*Config, error)` — parses flags from an explicit args slice (testable); decodes the base64 PSK from `-psk` or reads it from `-psk-file`.

- [ ] **Step 1: Write the failing config tests**

Create `gateway/internal/config/config_test.go`:

```go
package config

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseInlinePSK(t *testing.T) {
	psk := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))
	cfg, err := Parse([]string{"-upstream", "192.168.10.1:51820", "-psk", psk})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if cfg.Listen != ":51819" {
		t.Fatalf("default listen: got %q", cfg.Listen)
	}
	if cfg.Upstream != "192.168.10.1:51820" {
		t.Fatalf("upstream: got %q", cfg.Upstream)
	}
	if string(cfg.PSK) != "0123456789abcdef0123456789abcdef" {
		t.Fatalf("psk decode mismatch")
	}
	if cfg.Timeout != 180*time.Second {
		t.Fatalf("default timeout: got %v", cfg.Timeout)
	}
	if cfg.PadMax != 32 {
		t.Fatalf("default padmax: got %d", cfg.PadMax)
	}
}

func TestParsePSKFile(t *testing.T) {
	psk := base64.StdEncoding.EncodeToString([]byte("filepsk-filepsk-filepsk-filepsk!"))
	dir := t.TempDir()
	path := filepath.Join(dir, "psk.txt")
	if err := os.WriteFile(path, []byte(psk+"\n"), 0o600); err != nil {
		t.Fatalf("write psk file: %v", err)
	}
	cfg, err := Parse([]string{"-upstream", "x:1", "-psk-file", path})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if string(cfg.PSK) != "filepsk-filepsk-filepsk-filepsk!" {
		t.Fatalf("psk file decode mismatch")
	}
}

func TestParseRequiresUpstreamAndPSK(t *testing.T) {
	if _, err := Parse([]string{"-psk", base64.StdEncoding.EncodeToString([]byte("x"))}); err == nil {
		t.Fatal("expected error when upstream missing")
	}
	if _, err := Parse([]string{"-upstream", "x:1"}); err == nil {
		t.Fatal("expected error when psk missing")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd gateway && go test ./internal/config/ -v`
Expected: FAIL — build error, `Parse`/`Config` undefined.

- [ ] **Step 3: Implement config parsing**

Create `gateway/internal/config/config.go`:

```go
// Package config parses gateway command-line flags into a validated Config.
package config

import (
	"encoding/base64"
	"errors"
	"flag"
	"os"
	"strings"
	"time"
)

// Config holds the resolved gateway settings.
type Config struct {
	Listen   string
	Upstream string
	PSK      []byte
	Timeout  time.Duration
	PadMax   int
}

// Parse reads flags from args (excluding the program name).
func Parse(args []string) (*Config, error) {
	fs := flag.NewFlagSet("stealthwg-gateway", flag.ContinueOnError)
	listen := fs.String("listen", ":51819", "mask-side UDP listen address")
	upstream := fs.String("upstream", "", "upstream WireGuard endpoint host:port (required)")
	psk := fs.String("psk", "", "obfuscation PSK, base64 (or use -psk-file)")
	pskFile := fs.String("psk-file", "", "path to a file containing the base64 PSK")
	timeout := fs.Duration("timeout", 180*time.Second, "idle session timeout")
	padMax := fs.Int("padmax", 32, "maximum random padding per packet (0..255)")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}

	if *upstream == "" {
		return nil, errors.New("config: -upstream is required")
	}

	pskB64 := *psk
	if pskB64 == "" && *pskFile != "" {
		data, err := os.ReadFile(*pskFile)
		if err != nil {
			return nil, err
		}
		pskB64 = strings.TrimSpace(string(data))
	}
	if pskB64 == "" {
		return nil, errors.New("config: -psk or -psk-file is required")
	}
	pskBytes, err := base64.StdEncoding.DecodeString(pskB64)
	if err != nil {
		return nil, errors.New("config: PSK is not valid base64")
	}
	if *padMax < 0 || *padMax > 255 {
		return nil, errors.New("config: -padmax must be 0..255")
	}

	return &Config{
		Listen:   *listen,
		Upstream: *upstream,
		PSK:      pskBytes,
		Timeout:  *timeout,
		PadMax:   *padMax,
	}, nil
}
```

- [ ] **Step 4: Run config tests to verify they pass**

Run: `cd gateway && go test ./internal/config/ -v`
Expected: PASS.

- [ ] **Step 5: Implement main**

Create `gateway/cmd/stealthwg-gateway/main.go`:

```go
// Command stealthwg-gateway unmasks StealthWG client traffic and relays it to
// an unmodified upstream WireGuard endpoint.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/kurtserdar/StealthWG/gateway/internal/config"
	"github.com/kurtserdar/StealthWG/gateway/internal/mask"
	"github.com/kurtserdar/StealthWG/gateway/internal/relay"
)

func main() {
	cfg, err := config.Parse(os.Args[1:])
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	codec, err := mask.NewCodec(cfg.PSK, cfg.PadMax)
	if err != nil {
		log.Fatalf("codec: %v", err)
	}
	r, err := relay.New(cfg.Listen, cfg.Upstream, codec, cfg.Timeout)
	if err != nil {
		log.Fatalf("relay: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	log.Printf("stealthwg-gateway listening on %s, upstream %s", r.LocalAddr(), cfg.Upstream)
	if err := r.Run(ctx); err != nil {
		log.Fatalf("run: %v", err)
	}
	log.Print("stealthwg-gateway stopped")
}
```

- [ ] **Step 6: Build the whole module and vet it**

Run: `cd gateway && go build ./... && go vet ./...`
Expected: no output, exit 0.

- [ ] **Step 7: Manual smoke test (documented, optional to run)**

```bash
# Terminal A: a fake upstream that prints what it receives
# (any UDP listener works; this is just to see traffic arrive)
# Terminal B:
cd gateway
PSK=$(head -c 32 /dev/urandom | base64)
go run ./cmd/stealthwg-gateway -upstream 127.0.0.1:51820 -psk "$PSK" -listen 127.0.0.1:51819
# Expected log line: "stealthwg-gateway listening on 127.0.0.1:51819, upstream 127.0.0.1:51820"
# Ctrl-C -> "stealthwg-gateway stopped"
```

- [ ] **Step 8: Commit**

```bash
git add gateway/internal/config/config.go gateway/internal/config/config_test.go gateway/cmd/stealthwg-gateway/main.go
git commit -m "Add gateway CLI: config parsing and main entrypoint"
```

---

## Notes for the implementer

- Run `cd gateway && go test ./...` after each task; everything must stay green.
- The `testdata/vectors.json` golden is the interop contract with the Swift client codec (written later). If a codec change is intentional, regenerate with `-update` and explain why in the commit; unintentional drift is a bug.
- Do not add a MAC, authentication, or a second crypto layer — that is explicitly out of scope (security is WireGuard's job).
- Do not add QUIC/DNS/TCP transports here — they belong to a later phase behind the same interface.
