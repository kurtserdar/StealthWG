# All-in-one Masked WG Server + Native Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Checkbox (`- [ ]`) steps. TDD the pure core.

**Goal:** A single `stealthwg` Linux binary that is a masked WireGuard server (wireguard-go + MaskBind), with `init`/`add-client`/`up` CLI, packaged as deb/rpm/apk. The relay stays.

**Architecture:** `gateway/internal/wgserver` holds the engine + pure helpers (keys, config, IP alloc, UAPI render, client profile). `gateway/cmd/stealthwg` is the daemon + CLI. `packaging/` + a build script produce packages.

**Tech Stack:** Go, wireguard-go (`golang.zx2c4.com/wireguard` device/tun/conn), `wgbind`, `mask`, `x/crypto/curve25519`, nfpm, systemd.

## Global Constraints

- Go, CGO-free, cross-compiles for linux/{amd64,arm64}. `go test ./...` green in `gateway`.
- Reuse `wgbind.MaskBind` + `mask.Codec` (do not reimplement masking).
- UAPI keys are hex; config/profile keys are base64.
- No `wireguard-tools` dependency (keys via Go). `Recommends: iproute2, iptables, qrencode`.

## File Structure

- `gateway/go.mod` — add wgbind + wireguard-go (Task 1).
- `gateway/internal/wgserver/{keys,config,profile,uapi}.go` + `*_test.go` (Task 1).
- `gateway/internal/wgserver/engine.go` — TUN + device + NAT (Task 2).
- `gateway/cmd/stealthwg/main.go` — daemon + CLI (Task 3).
- `packaging/{nfpm.yaml,stealthwg.service}`, `scripts/build-packages.sh` (Task 4).
- `docs/deploy-gateway.md` — native section (Task 5).

---

### Task 1: `wgserver` pure core (keys, config, IP alloc, UAPI, profile) + tests

**Files:** `gateway/go.mod`; create `gateway/internal/wgserver/{keys,config,profile,uapi}.go` + tests.

- [ ] **Step 1: Wire the module** — in `gateway/go.mod` add:
```
require (
	github.com/kurtserdar/StealthWG/wgbind v0.0.0
	golang.zx2c4.com/wireguard v0.0.0-20230209153558-1e2c3e5a3c14
)
replace github.com/kurtserdar/StealthWG/wgbind => ../wgbind
```
then `cd gateway && go mod tidy`.

- [ ] **Step 2: Write failing tests** — `gateway/internal/wgserver/core_test.go`:
```go
package wgserver

import "strings"
import "testing"

func TestKeypairRoundTrip(t *testing.T) {
	priv, pub, err := GenerateKeypair()
	if err != nil { t.Fatal(err) }
	pub2, err := PublicKeyFromPrivate(priv)
	if err != nil { t.Fatal(err) }
	if pub != pub2 { t.Fatalf("pub mismatch: %s vs %s", pub, pub2) }
	if len(priv) != 44 || len(pub) != 44 { t.Fatalf("bad base64 lengths") }
}

func TestConfigRoundTrip(t *testing.T) {
	c := &Config{PrivateKey: "PRIV", MaskKey: "PSK", ListenPort: 51820,
		Subnet: "10.8.0.0/24", PublicHost: "vpn.example.com", DNS: "1.1.1.1",
		Clients: []Client{{Name: "phone", PublicKey: "PUB", Address: "10.8.0.2/32"}}}
	got, err := ParseConfig(c.Marshal())
	if err != nil { t.Fatal(err) }
	if got.ListenPort != 51820 || got.PublicHost != "vpn.example.com" || len(got.Clients) != 1 ||
		got.Clients[0].Name != "phone" || got.Clients[0].Address != "10.8.0.2/32" {
		t.Fatalf("round trip mismatch: %+v", got)
	}
}

func TestNextClientAddress(t *testing.T) {
	c := &Config{Subnet: "10.8.0.0/24", Clients: []Client{{Address: "10.8.0.2/32"}, {Address: "10.8.0.4/32"}}}
	a, err := c.NextClientAddress()
	if err != nil { t.Fatal(err) }
	if a != "10.8.0.5/32" { t.Fatalf("want 10.8.0.5/32 got %s", a) }
}

func TestClientProfileShape(t *testing.T) {
	c := &Config{PrivateKey: mustPriv(t), MaskKey: "PSKVALUE", ListenPort: 51820,
		PublicHost: "vpn.example.com", DNS: "1.1.1.1"}
	p := c.ClientProfile("CLIENTPRIV", "10.8.0.2/32")
	for _, want := range []string{"[Interface]", "PrivateKey = CLIENTPRIV", "Address = 10.8.0.2/32",
		"DNS = 1.1.1.1", "[Peer]", "Endpoint = vpn.example.com:51820", "AllowedIPs = 0.0.0.0/0",
		"[Stealth]", "MaskKey = PSKVALUE"} {
		if !strings.Contains(p, want) { t.Fatalf("profile missing %q\n%s", want, p) }
	}
}

func TestIpcConfigHex(t *testing.T) {
	c := &Config{PrivateKey: mustPriv(t), ListenPort: 51820,
		Clients: []Client{{PublicKey: mustPub(t), Address: "10.8.0.2/32"}}}
	s, err := c.IpcConfig()
	if err != nil { t.Fatal(err) }
	if !strings.Contains(s, "listen_port=51820") || !strings.Contains(s, "private_key=") ||
		!strings.Contains(s, "public_key=") || !strings.Contains(s, "allowed_ip=10.8.0.2/32") {
		t.Fatalf("bad uapi: %s", s)
	}
}

func mustPriv(t *testing.T) string { p, _, err := GenerateKeypair(); if err != nil { t.Fatal(err) }; return p }
func mustPub(t *testing.T) string { _, p, err := GenerateKeypair(); if err != nil { t.Fatal(err) }; return p }
```

- [ ] **Step 3: Run to verify it fails** — `cd gateway && go test ./internal/wgserver/` (undefined symbols).

- [ ] **Step 4: Implement** — create the four files.

`keys.go`:
```go
package wgserver

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"golang.org/x/crypto/curve25519"
)

// GenerateKeypair returns a base64 X25519 (private, public) pair, wg-compatible.
func GenerateKeypair() (priv, pub string, err error) {
	var p [32]byte
	if _, err = rand.Read(p[:]); err != nil { return "", "", err }
	pubBytes, err := curve25519.X25519(p[:], curve25519.Basepoint)
	if err != nil { return "", "", err }
	return base64.StdEncoding.EncodeToString(p[:]),
		base64.StdEncoding.EncodeToString(pubBytes), nil
}

// PublicKeyFromPrivate derives the base64 public key from a base64 private key.
func PublicKeyFromPrivate(privB64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(privB64)
	if err != nil || len(raw) != 32 { return "", fmt.Errorf("invalid private key") }
	pub, err := curve25519.X25519(raw, curve25519.Basepoint)
	if err != nil { return "", err }
	return base64.StdEncoding.EncodeToString(pub), nil
}

// GeneratePSK returns 32 random bytes, base64 — the mask PSK.
func GeneratePSK() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil { return "", err }
	return base64.StdEncoding.EncodeToString(b[:]), nil
}
```

`config.go`:
```go
package wgserver

import (
	"bufio"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

type Client struct {
	Name      string
	PublicKey string
	Address   string
}

type Config struct {
	PrivateKey string
	MaskKey    string
	ListenPort int
	Subnet     string
	PublicHost string
	DNS        string
	Clients    []Client
}

func (c *Config) Marshal() string {
	var b strings.Builder
	fmt.Fprintf(&b, "PrivateKey = %s\n", c.PrivateKey)
	fmt.Fprintf(&b, "MaskKey = %s\n", c.MaskKey)
	fmt.Fprintf(&b, "ListenPort = %d\n", c.ListenPort)
	fmt.Fprintf(&b, "Subnet = %s\n", c.Subnet)
	fmt.Fprintf(&b, "PublicHost = %s\n", c.PublicHost)
	fmt.Fprintf(&b, "DNS = %s\n", c.DNS)
	for _, cl := range c.Clients {
		fmt.Fprintf(&b, "\n[Client %q]\nPublicKey = %s\nAddress = %s\n", cl.Name, cl.PublicKey, cl.Address)
	}
	return b.String()
}

func ParseConfig(s string) (*Config, error) {
	c := &Config{}
	var cur *Client
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" { continue }
		if strings.HasPrefix(line, "[Client") {
			name := strings.Trim(strings.TrimSuffix(strings.TrimPrefix(line, "[Client "), "]"), "\"")
			c.Clients = append(c.Clients, Client{Name: name})
			cur = &c.Clients[len(c.Clients)-1]
			continue
		}
		k, v, ok := kv(line)
		if !ok { continue }
		if cur != nil {
			switch k {
			case "PublicKey": cur.PublicKey = v
			case "Address": cur.Address = v
			}
			continue
		}
		switch k {
		case "PrivateKey": c.PrivateKey = v
		case "MaskKey": c.MaskKey = v
		case "ListenPort": c.ListenPort, _ = strconv.Atoi(v)
		case "Subnet": c.Subnet = v
		case "PublicHost": c.PublicHost = v
		case "DNS": c.DNS = v
		}
	}
	return c, sc.Err()
}

func kv(line string) (string, string, bool) {
	i := strings.Index(line, "=")
	if i < 0 { return "", "", false }
	return strings.TrimSpace(line[:i]), strings.TrimSpace(line[i+1:]), true
}

// NextClientAddress returns the next free <base>.N/32 (server takes .1). /24 only.
func (c *Config) NextClientAddress() (string, error) {
	base := subnetBase(c.Subnet)
	if base == "" { return "", fmt.Errorf("invalid subnet %q", c.Subnet) }
	used := map[int]bool{1: true}
	for _, cl := range c.Clients {
		if n := hostOctet(cl.Address, base); n > 0 { used[n] = true }
	}
	hosts := []int{}
	for n := 2; n < 255; n++ { if !used[n] { hosts = append(hosts, n) } }
	sort.Ints(hosts)
	if len(hosts) == 0 { return "", fmt.Errorf("subnet full") }
	return fmt.Sprintf("%s.%d/32", base, hosts[0]), nil
}

func subnetBase(subnet string) string {
	p := strings.SplitN(subnet, "/", 2)
	octs := strings.Split(p[0], ".")
	if len(octs) != 4 { return "" }
	return strings.Join(octs[:3], ".")
}

func hostOctet(addr, base string) int {
	a := strings.SplitN(addr, "/", 2)[0]
	if !strings.HasPrefix(a, base+".") { return 0 }
	n, _ := strconv.Atoi(strings.TrimPrefix(a, base+"."))
	return n
}
```

`profile.go`:
```go
package wgserver

import "fmt"
import "strings"

// ClientProfile builds the StealthWG client .conf (the shape the app parses).
func (c *Config) ClientProfile(clientPrivateKey, address string) string {
	serverPub, _ := PublicKeyFromPrivate(c.PrivateKey)
	var b strings.Builder
	b.WriteString("[Interface]\n")
	fmt.Fprintf(&b, "PrivateKey = %s\n", clientPrivateKey)
	fmt.Fprintf(&b, "Address = %s\n", address)
	if c.DNS != "" { fmt.Fprintf(&b, "DNS = %s\n", c.DNS) }
	b.WriteString("MTU = 1280\n\n[Peer]\n")
	fmt.Fprintf(&b, "PublicKey = %s\n", serverPub)
	fmt.Fprintf(&b, "Endpoint = %s:%d\n", c.PublicHost, c.ListenPort)
	b.WriteString("AllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n\n[Stealth]\n")
	fmt.Fprintf(&b, "MaskKey = %s\n", c.MaskKey)
	return b.String()
}
```

`uapi.go`:
```go
package wgserver

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
)

func b64ToHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil { return "", err }
	return hex.EncodeToString(raw), nil
}

// IpcConfig renders the wireguard-go UAPI 'set' config (hex keys).
func (c *Config) IpcConfig() (string, error) {
	privHex, err := b64ToHex(c.PrivateKey)
	if err != nil { return "", fmt.Errorf("private key: %w", err) }
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", privHex)
	fmt.Fprintf(&b, "listen_port=%d\n", c.ListenPort)
	fmt.Fprintf(&b, "replace_peers=true\n")
	for _, cl := range c.Clients {
		pubHex, err := b64ToHex(cl.PublicKey)
		if err != nil { return "", fmt.Errorf("peer %s: %w", cl.Name, err) }
		fmt.Fprintf(&b, "public_key=%s\n", pubHex)
		fmt.Fprintf(&b, "allowed_ip=%s\n", cl.Address)
	}
	return b.String(), nil
}
```

- [ ] **Step 5: Run to verify it passes** — `cd gateway && go test ./internal/wgserver/` → `ok`.

- [ ] **Step 6: Commit** — `git add gateway/go.mod gateway/go.sum gateway/internal/wgserver && git commit -m "wgserver: pure core (keys, config, IP alloc, UAPI, client profile) with tests"`

---

### Task 2: `wgserver` engine (TUN + device + MaskBind + NAT)

**Files:** Create `gateway/internal/wgserver/engine.go`.

- [ ] **Step 1:** `Engine` with `Start(cfg *Config)`: `tun.CreateTUN("wg-stealth", 1420)`, `codec = mask.NewCodec(pskBytes, padMax)`, `dev = device.NewDevice(tun, wgbind.New(conn.NewStdNetBind(), codec), logger)`, `dev.IpcSet(cfg.IpcConfig())`, `dev.Up()`; then OS networking via `exec` of `ip addr add <base>.1/24 dev wg-stealth`, `ip link set wg-stealth up`, `sysctl -w net.ipv4.ip_forward=1`, and an `iptables -t nat -A POSTROUTING -s <subnet> -o <wan> -j MASQUERADE` (detect `<wan>` from `ip route`). `Reload(cfg)` → `dev.IpcSet` again. `Stop()` → `dev.Close()` + remove the iptables rule. Keep OS calls in small helpers so they are swappable.
- [ ] **Step 2: Cross-compile check** — `cd gateway && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build ./...` → succeeds.
- [ ] **Step 3: Commit** — `git commit -am "wgserver: engine (TUN + wireguard-go + MaskBind + NAT)"`

---

### Task 3: `cmd/stealthwg` (daemon + CLI)

**Files:** Create `gateway/cmd/stealthwg/main.go`.

- [ ] **Step 1:** Subcommands: `up` (load `/etc/stealthwg/server.conf`, `Engine.Start`, wait for SIGHUP→`Reload`, SIGTERM→`Stop`); `init` (keys+PSK, write config, `add-client client1`, `systemctl enable --now stealthwg`, print profile+QR); `add-client NAME` (keypair, `NextClientAddress`, append to config, `systemctl reload stealthwg`, print profile+QR via `qrencode -t ANSIUTF8` if present); `status`. Config path overridable by `STEALTHWG_CONFIG`.
- [ ] **Step 2: Cross-compile** — `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/stealthwg ./cmd/stealthwg` → succeeds.
- [ ] **Step 3: Commit** — `git commit -am "cmd/stealthwg: daemon + init/add-client/status CLI"`

---

### Task 4: Packaging + build script

**Files:** Create `packaging/nfpm.yaml`, `packaging/stealthwg.service`, `scripts/build-packages.sh`.

- [ ] **Step 1:** `stealthwg.service` (`ExecStart=/usr/bin/stealthwg up`, `ExecReload=/bin/kill -HUP $MAINPID`, `AmbientCapabilities=CAP_NET_ADMIN`, `Restart=on-failure`). `nfpm.yaml` (name stealthwg, contents: binary→/usr/bin/stealthwg, unit→/lib/systemd/system, recommends iproute2/iptables/qrencode, arch from `$ARCH`, postinstall echo "run: sudo stealthwg init"). `build-packages.sh`: for each arch build the binary, `nfpm pkg -p deb|rpm|apk` into `dist/`; also emit raw darwin/windows/freebsd binaries.
- [ ] **Step 2: Local package build** — `go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest`; run the script for amd64; `dpkg -c dist/*.deb` (or `ar t`) shows `/usr/bin/stealthwg` + the unit.
- [ ] **Step 3: Commit** — `git commit -m "Packaging: nfpm deb/rpm/apk + systemd unit + build script"`

---

### Task 5: Docs

**Files:** Modify `docs/deploy-gateway.md`.

- [ ] **Step 1:** Add a "Native install (all-in-one masked WG server)" section: `apt install ./stealthwg_*.deb` → `sudo stealthwg init` → paste the printed profile; `sudo stealthwg add-client laptop` for more. Note the relay remains for fronting an existing WireGuard.
- [ ] **Step 2: Commit** — `git commit -am "Docs: native all-in-one install"`

---

## Self-Review

- **Spec coverage:** all-in-one engine (Task 2) reusing wgbind/mask, pure core+tests (Task 1), CLI init/add-client/up (Task 3), deb/rpm/apk+raw (Task 4), docs+relay-kept note (Task 5). ✓
- **Placeholder scan:** Task 1 fully coded/tested; Tasks 2–4 specify concrete files/commands; engine OS calls are named helpers.
- **Type/name consistency:** `Config`/`Client` fields, `GenerateKeypair`/`PublicKeyFromPrivate`/`GeneratePSK`, `NextClientAddress`, `ClientProfile`, `IpcConfig` used identically across engine (Task 2) and CLI (Task 3). `wgbind.New`/`mask.NewCodec` signatures match the existing modules.
