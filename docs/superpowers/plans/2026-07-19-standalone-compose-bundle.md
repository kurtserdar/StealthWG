# Standalone Compose Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `docker compose` bundle that brings up the StealthWG masking relay plus a bundled kernel-WireGuard server on a WG-less Linux host, and emits ready-to-paste StealthWG client profiles.

**Architecture:** Two compose services. `gateway` is the existing relay image, unchanged, exposing `51819/udp`. `wg` is a new thin Alpine image whose `entrypoint.sh` provisions keys + PSK (persisted, idempotent), runs `wg-quick` with NAT, and writes StealthWG client profiles whose `Endpoint` points at the relay and that carry `[Stealth] MaskKey`. The relay reads the same PSK from a shared `/data/psk` file, so relay and profiles always agree.

**Tech Stack:** POSIX `sh`, `wireguard-tools` (`wg`, `wg-quick`), `iptables`, `qrencode`, Alpine, Docker Compose. Tests are POSIX shell harnesses that stub the wg/network binaries on `PATH` (mirrors the existing `scripts/test-parser.sh` style).

## Global Constraints

- New files live under `deploy/standalone/` (compose, `.env.example`, `wg/Dockerfile`, `wg/entrypoint.sh`). Test harness under `scripts/`.
- The existing gateway image (`ghcr.io/kurtserdar/stealthwg-gateway`) is reused **unchanged** — no edits to `gateway/`.
- Shell is POSIX `sh` (Alpine `/bin/sh` = BusyBox ash), not bash. No bashisms.
- Code comments in English.
- Client profile `Endpoint` = `${PUBLIC_HOST}:51819` (the relay), never the WG port.
- Every generated profile ends with a `[Stealth]` section containing `MaskKey = <PSK>`.
- PSK is base64 (produced by `wg genpsk`); gateway consumes it via `STEALTHWG_PSK_FILE=/data/psk` (gateway `TrimSpace`s the file, so a trailing newline is fine).
- `entrypoint.sh` is idempotent: a second boot reuses persisted keys/PSK and never regenerates them.
- Config knobs and defaults (from the spec): `PUBLIC_HOST` (required), `STEALTHWG_PSK` (optional→generated), `PEERS`=1, `WG_SUBNET`=`10.0.0.0/24`, `WG_DNS`=`1.1.1.1`, WG listen port `51820`, relay port `51819`.
- `WG_SUBNET` is assumed a `/24` (documented); server takes `.1`, client _i_ takes `.(i+1)`.

## File Structure

- `deploy/standalone/wg/entrypoint.sh` — provisioning + WG lifecycle (the core; built via TDD in Tasks 1–4).
- `deploy/standalone/wg/Dockerfile` — Alpine image with wireguard-tools/iptables/qrencode (Task 5).
- `deploy/standalone/docker-compose.yml` — the two-service wiring (Task 6).
- `deploy/standalone/.env.example` — documented config template (Task 6).
- `scripts/test-standalone.sh` — shell test harness with binary stubs (Tasks 1–4).
- `docs/deploy-gateway.md` — add a "Standalone (WireGuard included)" section (Task 7).

The test harness sources or executes `entrypoint.sh` with `SUPERVISE=0` (skips the foreground keep-alive loop) and `DATA_DIR`/`PROFILES_DIR` pointed at a temp dir, with stub `wg`/`wg-quick`/`iptables`/`sysctl`/`ip`/`qrencode` earlier on `PATH`.

---

### Task 1: Entrypoint skeleton + PSK resolution, with test harness

**Files:**
- Create: `deploy/standalone/wg/entrypoint.sh`
- Create: `scripts/test-standalone.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `entrypoint.sh` reads env `DATA_DIR` (default `/data`), `PROFILES_DIR` (default `/profiles`), `PUBLIC_HOST` (required), `STEALTHWG_PSK` (optional), `PEERS` (default `1`), `WG_SUBNET` (default `10.0.0.0/24`), `WG_DNS` (default `1.1.1.1`), `WG_PORT` (default `51820`), `RELAY_PORT` (default `51819`), `SUPERVISE` (default `1`). Function `resolve_psk` sets global `PSK` and writes `$DATA_DIR/psk`. `main` requires `PUBLIC_HOST`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-standalone.sh`:

```sh
#!/bin/sh
# Test harness for deploy/standalone/wg/entrypoint.sh.
# Stubs wg/wg-quick/iptables/sysctl/ip/qrencode on PATH and runs the entrypoint
# with SUPERVISE=0 against a temp DATA_DIR/PROFILES_DIR.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$ROOT/deploy/standalone/wg/entrypoint.sh"
PASS=0
FAIL=0

check() { # desc, actual, expected
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2"
  fi
}
contains() { # desc, haystack-file, needle
  if grep -qF "$3" "$2" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: %s\n  file %s missing: %s\n' "$1" "$2" "$3"
  fi
}

make_stubs() { # dir
  d="$1"; mkdir -p "$d"
  cat > "$d/wg" <<'EOF'
#!/bin/sh
case "$1" in
  genkey) c=$(cat "$STUB_STATE/c" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$STUB_STATE/c"; echo "KEY$c";;
  pubkey) read k; echo "PUB_of_${k}";;
  genpsk) echo "STUBPSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";;
  *) : ;;
esac
EOF
  for b in wg-quick iptables sysctl ip qrencode; do
    cat > "$d/$b" <<EOF
#!/bin/sh
echo "$b \$*" >> "\$STUB_STATE/calls"
exit 0
EOF
  done
  chmod +x "$d"/*
}

run_entry() { # extra env as KEY=VAL ...
  TMP="$(mktemp -d)"; export STUB_STATE="$TMP/state"; mkdir -p "$STUB_STATE"
  make_stubs "$TMP/bin"
  env PATH="$TMP/bin:$PATH" DATA_DIR="$TMP/data" PROFILES_DIR="$TMP/profiles" \
      SUPERVISE=0 "$@" sh "$ENTRY" >"$TMP/out" 2>"$TMP/err" || echo "ENTRY_EXIT=$?" >>"$TMP/err"
  echo "$TMP"
}

# --- Task 1: PSK resolution ---
T=$(run_entry PUBLIC_HOST=vpn.example.com)
check "psk file created" "$( [ -f "$T/data/psk" ] && echo yes )" "yes"
check "generated psk value" "$(cat "$T/data/psk")" "STUBPSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

T=$(run_entry PUBLIC_HOST=vpn.example.com STEALTHWG_PSK=MyExplicitPSK=)
check "explicit psk honored" "$(cat "$T/data/psk")" "MyExplicitPSK="

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/test-standalone.sh`
Expected: FAIL — `entrypoint.sh` does not exist yet (harness reports failures / non-zero exit).

- [ ] **Step 3: Write minimal implementation**

Create `deploy/standalone/wg/entrypoint.sh`:

```sh
#!/bin/sh
# StealthWG standalone bundle — provisions keys/PSK, runs the WireGuard server,
# and emits StealthWG client profiles. POSIX sh (BusyBox ash), idempotent.
set -eu

DATA_DIR="${DATA_DIR:-/data}"
PROFILES_DIR="${PROFILES_DIR:-/profiles}"
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.0.0.0/24}"
WG_DNS="${WG_DNS:-1.1.1.1}"
PEERS="${PEERS:-1}"
RELAY_PORT="${RELAY_PORT:-51819}"
SUPERVISE="${SUPERVISE:-1}"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# resolve_psk sets $PSK and writes $DATA_DIR/psk (base64). The PSK file is the
# single source of truth shared with the relay via STEALTHWG_PSK_FILE. Written
# first, before anything else, so the relay can start as soon as it appears.
resolve_psk() {
    psk_file="$DATA_DIR/psk"
    if [ -n "${STEALTHWG_PSK:-}" ]; then
        printf '%s' "$STEALTHWG_PSK" > "$psk_file"
    elif [ ! -f "$psk_file" ]; then
        wg genpsk | tr -d '\n' > "$psk_file"
    fi
    chmod 600 "$psk_file"
    PSK="$(cat "$psk_file")"
}

main() {
    [ -n "${PUBLIC_HOST:-}" ] || die "PUBLIC_HOST is required"
    mkdir -p "$DATA_DIR" "$PROFILES_DIR" /etc/wireguard
    resolve_psk
}

main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh scripts/test-standalone.sh`
Expected: PASS — `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add deploy/standalone/wg/entrypoint.sh scripts/test-standalone.sh
git commit -m "Add standalone entrypoint skeleton with PSK resolution + test harness"
```

---

### Task 2: Key generation + server config + idempotency

**Files:**
- Modify: `deploy/standalone/wg/entrypoint.sh`
- Modify: `scripts/test-standalone.sh`

**Interfaces:**
- Consumes: `resolve_psk`, globals from Task 1.
- Produces: functions `subnet_base` (echoes the `/24` prefix, e.g. `10.0.0`), `subnet_prefixlen` (echoes `24`), `ensure_server_keys` (sets `SERVER_KEY`/`SERVER_PUB`, persists `$DATA_DIR/server.key|.pub`), `ensure_peer_keys` (persists `$DATA_DIR/peerN.key|.pub`), `render_server_conf` (writes `/etc/wireguard/$WG_IF.conf`).

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-standalone.sh` before the final `printf`/exit:

```sh
# --- Task 2: keys + server conf + idempotency ---
T=$(run_entry PUBLIC_HOST=vpn.example.com PEERS=2)
check "server key persisted" "$( [ -f "$T/data/server.key" ] && echo yes )" "yes"
check "peer1 key persisted"  "$( [ -f "$T/data/peer1.key" ] && echo yes )" "yes"
check "peer2 key persisted"  "$( [ -f "$T/data/peer2.key" ] && echo yes )" "yes"
contains "server conf has ListenPort" "/etc/wireguard/wg0.conf.copy" ""  # placeholder; replaced below

# Idempotency: capture keys, run again against the SAME data dir, expect unchanged.
FIRST_SERVER="$(cat "$T/data/server.key")"
env PATH="$T/../bin:$PATH" 2>/dev/null || true
# Re-run reusing the same DATA_DIR/PROFILES_DIR + a fresh stub state:
S2="$T/state2"; mkdir -p "$S2"
env PATH="$(dirname "$T")/bin:$PATH" DATA_DIR="$T/data" PROFILES_DIR="$T/profiles" \
    STUB_STATE="$S2" SUPERVISE=0 PUBLIC_HOST=vpn.example.com PEERS=2 \
    sh "$ENTRY" >/dev/null 2>&1 || true
check "server key unchanged on 2nd boot" "$(cat "$T/data/server.key")" "$FIRST_SERVER"
```

Note: remove the temporary `contains ... wg0.conf.copy` placeholder line — replace it with reading the real conf. The image writes `/etc/wireguard/wg0.conf`; in tests we cannot write to `/etc/wireguard`, so make the conf path configurable. Update the harness instead to assert on a test-visible path (see Step 3, which routes `WG_CONF_DIR`).

Replace the placeholder line with:

```sh
contains "server conf has ListenPort 51820" "$T/data/wg0.conf" "ListenPort = 51820"
contains "server conf has 2 peers"          "$T/data/wg0.conf" "AllowedIPs = 10.0.0.3/32"
```

And in `run_entry`, add `WG_CONF_DIR="$TMP/data"` to the `env` line so the conf is written somewhere the test (and a non-root run) can read:

```sh
  env PATH="$TMP/bin:$PATH" DATA_DIR="$TMP/data" PROFILES_DIR="$TMP/profiles" \
      WG_CONF_DIR="$TMP/data" SUPERVISE=0 "$@" sh "$ENTRY" >"$TMP/out" 2>"$TMP/err" || echo "ENTRY_EXIT=$?" >>"$TMP/err"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/test-standalone.sh`
Expected: FAIL — key files and `wg0.conf` not produced yet.

- [ ] **Step 3: Write minimal implementation**

In `entrypoint.sh`, add `WG_CONF_DIR="${WG_CONF_DIR:-/etc/wireguard}"` to the env block, and add these functions above `main`:

```sh
subnet_base()      { printf '%s' "$WG_SUBNET" | sed 's#\.[0-9]*/[0-9]*$##'; }
subnet_prefixlen() { printf '%s' "$WG_SUBNET" | sed 's#.*/##'; }

ensure_server_keys() {
    if [ ! -f "$DATA_DIR/server.key" ]; then
        ( umask 077; wg genkey > "$DATA_DIR/server.key" )
        wg pubkey < "$DATA_DIR/server.key" > "$DATA_DIR/server.pub"
    fi
    SERVER_KEY="$(cat "$DATA_DIR/server.key")"
    SERVER_PUB="$(cat "$DATA_DIR/server.pub")"
}

ensure_peer_keys() {
    i=1
    while [ "$i" -le "$PEERS" ]; do
        if [ ! -f "$DATA_DIR/peer$i.key" ]; then
            ( umask 077; wg genkey > "$DATA_DIR/peer$i.key" )
            wg pubkey < "$DATA_DIR/peer$i.key" > "$DATA_DIR/peer$i.pub"
        fi
        i=$((i+1))
    done
}

render_server_conf() {
    base="$(subnet_base)"; plen="$(subnet_prefixlen)"
    conf="$WG_CONF_DIR/$WG_IF.conf"
    {
        printf '[Interface]\n'
        printf 'Address = %s.1/%s\n' "$base" "$plen"
        printf 'ListenPort = %s\n' "$WG_PORT"
        printf 'PrivateKey = %s\n' "$SERVER_KEY"
        i=1
        while [ "$i" -le "$PEERS" ]; do
            printf '\n[Peer]\n'
            printf 'PublicKey = %s\n' "$(cat "$DATA_DIR/peer$i.pub")"
            printf 'AllowedIPs = %s.%s/32\n' "$base" "$((i+1))"
            i=$((i+1))
        done
    } > "$conf"
    chmod 600 "$conf"
}
```

Then extend `main` to call them after `resolve_psk`:

```sh
    resolve_psk
    ensure_server_keys
    ensure_peer_keys
    render_server_conf
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh scripts/test-standalone.sh`
Expected: PASS — all Task 1 + Task 2 checks green.

- [ ] **Step 5: Commit**

```bash
git add deploy/standalone/wg/entrypoint.sh scripts/test-standalone.sh
git commit -m "Standalone: generate server/peer keys and render idempotent wg0.conf"
```

---

### Task 3: Client StealthWG profiles + QR + outputs

**Files:**
- Modify: `deploy/standalone/wg/entrypoint.sh`
- Modify: `scripts/test-standalone.sh`

**Interfaces:**
- Consumes: `SERVER_PUB`, `PSK`, `subnet_base`, peer keys from Task 2.
- Produces: function `write_profiles` — for each peer writes `$PROFILES_DIR/clientN.conf` (a StealthWG profile), prints it, and renders a QR via `qrencode`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-standalone.sh` before the final `printf`/exit:

```sh
# --- Task 3: client profiles ---
T=$(run_entry PUBLIC_HOST=vpn.example.com PEERS=1 WG_DNS=9.9.9.9)
P="$T/profiles/client1.conf"
check "client1 profile exists" "$( [ -f "$P" ] && echo yes )" "yes"
contains "profile endpoint is relay"   "$P" "Endpoint = vpn.example.com:51819"
contains "profile has MaskKey"          "$P" "MaskKey = STUBPSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
contains "profile allowedips full"      "$P" "AllowedIPs = 0.0.0.0/0, ::/0"
contains "profile server pubkey"        "$P" "PublicKey = PUB_of_KEY1"
contains "profile client addr"          "$P" "Address = 10.0.0.2/32"
contains "profile dns"                  "$P" "DNS = 9.9.9.9"
contains "qrencode invoked"             "$T/state/calls" "qrencode"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/test-standalone.sh`
Expected: FAIL — no `client1.conf` produced.

- [ ] **Step 3: Write minimal implementation**

Add to `entrypoint.sh` above `main`:

```sh
write_profiles() {
    base="$(subnet_base)"
    i=1
    while [ "$i" -le "$PEERS" ]; do
        out="$PROFILES_DIR/client$i.conf"
        ( umask 077
          {
            printf '[Interface]\n'
            printf 'PrivateKey = %s\n' "$(cat "$DATA_DIR/peer$i.key")"
            printf 'Address = %s.%s/32\n' "$base" "$((i+1))"
            printf 'DNS = %s\n' "$WG_DNS"
            printf '\n[Peer]\n'
            printf 'PublicKey = %s\n' "$SERVER_PUB"
            printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
            printf 'Endpoint = %s:%s\n' "$PUBLIC_HOST" "$RELAY_PORT"
            printf '\n[Stealth]\n'
            printf 'MaskKey = %s\n' "$PSK"
          } > "$out" )
        log "===== StealthWG profile: client$i ($out) ====="
        cat "$out"
        log "----- scan this QR to import on a phone -----"
        qrencode -t ANSIUTF8 < "$out" || true
        i=$((i+1))
    done
}
```

Extend `main` after `render_server_conf`:

```sh
    write_profiles
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh scripts/test-standalone.sh`
Expected: PASS — Task 3 checks green.

- [ ] **Step 5: Commit**

```bash
git add deploy/standalone/wg/entrypoint.sh scripts/test-standalone.sh
git commit -m "Standalone: emit StealthWG client profiles with relay endpoint, MaskKey, QR"
```

---

### Task 4: Tunnel bring-up + IP forwarding + NAT + supervise loop

**Files:**
- Modify: `deploy/standalone/wg/entrypoint.sh`
- Modify: `scripts/test-standalone.sh`

**Interfaces:**
- Consumes: `WG_IF`, `WG_SUBNET`, globals.
- Produces: function `start_tunnel` (enables `ip_forward`, `wg-quick up`, MASQUERADE); `main` runs a foreground supervise loop unless `SUPERVISE=0`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-standalone.sh` before the final `printf`/exit:

```sh
# --- Task 4: bring-up calls ---
T=$(run_entry PUBLIC_HOST=vpn.example.com)
contains "sysctl ip_forward enabled" "$T/state/calls" "sysctl net.ipv4.ip_forward=1"
contains "wg-quick up called"        "$T/state/calls" "wg-quick up wg0"
contains "masquerade rule added"     "$T/state/calls" "iptables -t nat -A POSTROUTING"
```

Also make the `ip route`/`iptables -C` calls in the stub not abort the run: the generic stub already `exit 0`s, and the `ip` stub returns empty for `route show default`, so `out_if` is empty — acceptable in tests. Ensure `start_tunnel` tolerates an empty out-interface (falls back to a subnet-only MASQUERADE without `-o`).

- [ ] **Step 2: Run test to verify it fails**

Run: `sh scripts/test-standalone.sh`
Expected: FAIL — no `sysctl`/`wg-quick`/`iptables` calls recorded.

- [ ] **Step 3: Write minimal implementation**

Add to `entrypoint.sh` above `main`:

```sh
start_tunnel() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || sysctl net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    wg-quick up "$WG_IF"
    out_if="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [ -n "$out_if" ]; then
        iptables -t nat -C POSTROUTING -s "$WG_SUBNET" -o "$out_if" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -o "$out_if" -j MASQUERADE
    else
        iptables -t nat -C POSTROUTING -s "$WG_SUBNET" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -j MASQUERADE
    fi
}

supervise() {
    trap 'wg-quick down "$WG_IF" 2>/dev/null || true; exit 0' TERM INT
    log "StealthWG standalone up: relay :$RELAY_PORT -> wg :$WG_PORT. Ctrl-C to stop."
    while :; do sleep 3600 & wait $!; done
}
```

Note: the `sysctl -w` call must record `sysctl net.ipv4.ip_forward=1` in the stub call log. Since the stub logs `sysctl $*`, invoke it so the args contain that string. Use the explicit form the test asserts:

```sh
    sysctl net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    wg-quick up "$WG_IF"
```

(Replace the double-fallback first line above with this single line so the recorded call matches `sysctl net.ipv4.ip_forward=1`.)

Extend `main` after `write_profiles`:

```sh
    start_tunnel
    [ "$SUPERVISE" = "1" ] && supervise
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh scripts/test-standalone.sh`
Expected: PASS — all checks green (`SUPERVISE=0` in tests skips the loop).

- [ ] **Step 5: Make the harness executable and commit**

```bash
chmod +x scripts/test-standalone.sh
git add deploy/standalone/wg/entrypoint.sh scripts/test-standalone.sh
git commit -m "Standalone: bring up tunnel with forwarding + NAT, add supervise loop"
```

---

### Task 5: `wg` image Dockerfile

**Files:**
- Create: `deploy/standalone/wg/Dockerfile`

**Interfaces:**
- Consumes: `entrypoint.sh` from Tasks 1–4.
- Produces: a buildable image whose entrypoint is `entrypoint.sh`.

- [ ] **Step 1: Write the Dockerfile**

Create `deploy/standalone/wg/Dockerfile`:

```dockerfile
# Bundled WireGuard server for the StealthWG standalone compose bundle.
# Kernel WireGuard via wg-quick when the host module is present; wireguard-go
# userspace fallback otherwise.
FROM alpine:3.20

RUN apk add --no-cache \
        wireguard-tools \
        iptables \
        ip6tables \
        qrencode \
        wireguard-go \
        iproute2

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 2: Build to verify it succeeds**

Run: `docker build -t stealthwg-wg:dev deploy/standalone/wg`
Expected: build completes; final image tagged `stealthwg-wg:dev`. (If `wireguard-go` is not in the pinned Alpine repo, drop that package — `wg-quick` uses the kernel module and the userspace fallback can be added later; note the change in the commit.)

- [ ] **Step 3: Commit**

```bash
git add deploy/standalone/wg/Dockerfile
git commit -m "Standalone: Dockerfile for the bundled WireGuard server image"
```

---

### Task 6: `docker-compose.yml` + `.env.example`

**Files:**
- Create: `deploy/standalone/docker-compose.yml`
- Create: `deploy/standalone/.env.example`

**Interfaces:**
- Consumes: the `wg` image (Task 5), the existing gateway image, the shared `/data/psk` contract.
- Produces: a runnable compose project.

- [ ] **Step 1: Write the compose file**

Create `deploy/standalone/docker-compose.yml`:

```yaml
# StealthWG standalone bundle: masking relay + bundled WireGuard server.
# One command on a WG-less Linux host: `docker compose up -d`.
services:
  wg:
    build: ./wg
    image: stealthwg-wg:dev
    restart: unless-stopped
    cap_add: ["NET_ADMIN"]
    sysctls:
      net.ipv4.ip_forward: "1"
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      PUBLIC_HOST: "${PUBLIC_HOST:?set PUBLIC_HOST in .env}"
      STEALTHWG_PSK: "${STEALTHWG_PSK:-}"
      PEERS: "${PEERS:-1}"
      WG_SUBNET: "${WG_SUBNET:-10.0.0.0/24}"
      WG_DNS: "${WG_DNS:-1.1.1.1}"
    volumes:
      - ./data:/data
      - ./profiles:/profiles

  gateway:
    image: ghcr.io/kurtserdar/stealthwg-gateway:latest
    restart: unless-stopped
    depends_on:
      - wg
    ports:
      - "51819:51819/udp"
    environment:
      STEALTHWG_UPSTREAM: "wg:51820"
      STEALTHWG_PSK_FILE: "/data/psk"
    volumes:
      - ./data:/data:ro
```

- [ ] **Step 2: Write the env template**

Create `deploy/standalone/.env.example`:

```sh
# Copy to .env and edit. Only PUBLIC_HOST is required.

# Public IP or DNS name clients dial. Written as the profile Endpoint (:51819).
PUBLIC_HOST=vpn.example.com

# Obfuscation PSK (base64). Leave blank to auto-generate on first boot;
# the generated value is persisted to ./data/psk and printed with the profile.
STEALTHWG_PSK=

# Number of client profiles to provision on first boot.
PEERS=1

# Tunnel subnet (assumed /24) and client DNS.
WG_SUBNET=10.0.0.0/24
WG_DNS=1.1.1.1
```

- [ ] **Step 3: Validate the compose file**

Run: `docker compose -f deploy/standalone/docker-compose.yml --env-file /dev/null config -q 2>&1 || PUBLIC_HOST=x docker compose -f deploy/standalone/docker-compose.yml config -q`
Expected: with `PUBLIC_HOST` set, the config validates (no schema errors). The `:?` guard errors only when `PUBLIC_HOST` is unset — that is intended.

- [ ] **Step 4: Commit**

```bash
git add deploy/standalone/docker-compose.yml deploy/standalone/.env.example
git commit -m "Standalone: docker-compose wiring (relay + wg, shared PSK file)"
```

---

### Task 7: Documentation

**Files:**
- Modify: `docs/deploy-gateway.md`

**Interfaces:**
- Consumes: the finished bundle.
- Produces: user-facing instructions.

- [ ] **Step 1: Add the Standalone section**

Add a new section to `docs/deploy-gateway.md` after the "Generic Linux / VPS (Docker)" section:

```markdown
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

Generated client profiles are also written to `deploy/standalone/profiles/`.
Keys and the PSK persist in `deploy/standalone/data/` across restarts. To add
more devices, set `PEERS` before the first `up` (or delete `data/` to reprovision).

Already have a WireGuard server? Don't use this bundle — run the relay alone
(see "Generic Linux / VPS" above) and point `STEALTHWG_UPSTREAM` at your existing
WireGuard. The only client change is `[Peer] Endpoint` → the relay `:51819` and
adding `[Stealth] MaskKey`.
```

- [ ] **Step 2: Verify the doc renders**

Run: `grep -n "Standalone bundle" docs/deploy-gateway.md`
Expected: the new heading is present.

- [ ] **Step 3: Commit**

```bash
git add docs/deploy-gateway.md
git commit -m "Docs: standalone (WireGuard-included) bundle instructions"
```

---

## Self-Review

**Spec coverage:**
- Two services, gateway unchanged, wg new → Tasks 5/6. ✓
- Only gateway exposes a port → compose (Task 6) publishes only `51819/udp`. ✓
- Entrypoint first-boot/idempotent behavior → Tasks 1–4. ✓
- Shared PSK, no race (wg writes `/data/psk` first, gateway `STEALTHWG_PSK_FILE` + `depends_on`, restart retries) → Task 1 (psk first) + Task 6 (wiring). ✓
- Profile with relay Endpoint + MaskKey + QR + file output → Task 3. ✓
- Config knobs/defaults → Task 1 env block + Task 6 `.env.example`. ✓
- Persistence via `./data` + `./profiles` bind mounts → Task 6. ✓
- Kernel WG + userspace fallback, NET_ADMIN, /dev/net/tun → Task 5 (packages) + Task 6 (caps/devices). ✓
- Testing via shell harness stubbing wg tools → Tasks 1–4. ✓
- Docs section → Task 7. ✓

**Placeholder scan:** The only "placeholder" is the intentional `wg0.conf.copy` throwaway line in Task 2 Step 1, which the same step explicitly instructs to replace with the real `$T/data/wg0.conf` assertions and the `WG_CONF_DIR` wiring. No unresolved TODOs.

**Type/name consistency:** `resolve_psk`→`PSK`, `ensure_server_keys`→`SERVER_KEY`/`SERVER_PUB`, `subnet_base`, `write_profiles`, `start_tunnel`, `supervise` are used consistently across tasks. `WG_CONF_DIR` introduced in Task 2 and defaulted to `/etc/wireguard`; the real image writes there (root), tests override it. Stub key naming (`KEY1`→`PUB_of_KEY1`) is consistent between Task 2 (server = first `genkey` = `KEY1`) and Task 3's `PUBLIC_KEY = PUB_of_KEY1` assertion.

**Note on stub ordering:** server keys are generated before peer keys, so with the counter stub `server.key=KEY1`, `peer1.key=KEY2`. Task 3 asserts the profile's `[Peer] PublicKey = PUB_of_KEY1` (server pub) and does not assert the client PrivateKey value, avoiding brittleness.
