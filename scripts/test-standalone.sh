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
  for b in wg-quick sysctl ip qrencode; do
    cat > "$d/$b" <<EOF
#!/bin/sh
echo "$b \$*" >> "\$STUB_STATE/calls"
exit 0
EOF
  done
  # iptables: -C (check) returns non-zero when the rule is absent, like the real
  # tool, so the entrypoint proceeds to -A (add).
  cat > "$d/iptables" <<'EOF'
#!/bin/sh
echo "iptables $*" >> "$STUB_STATE/calls"
for a in "$@"; do [ "$a" = "-C" ] && exit 1; done
exit 0
EOF
  chmod +x "$d"/*
}

# run_entry TMPDIR extra-env... — provision into TMPDIR/data with fresh stub state.
run_entry() {
  TMP="$1"; shift
  export STUB_STATE="$TMP/state"; mkdir -p "$STUB_STATE"
  make_stubs "$TMP/bin"
  env PATH="$TMP/bin:$PATH" DATA_DIR="$TMP/data" PROFILES_DIR="$TMP/profiles" \
      WG_CONF_DIR="$TMP/data" SUPERVISE=0 "$@" sh "$ENTRY" \
      >"$TMP/out" 2>"$TMP/err" || echo "ENTRY_EXIT=$?" >>"$TMP/err"
}

# --- Task 1: PSK resolution ---
T="$(mktemp -d)"
run_entry "$T" PUBLIC_HOST=vpn.example.com
check "psk file created" "$( [ -f "$T/data/psk" ] && echo yes )" "yes"
check "generated psk value" "$(cat "$T/data/psk")" "STUBPSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

T="$(mktemp -d)"
run_entry "$T" PUBLIC_HOST=vpn.example.com STEALTHWG_PSK=MyExplicitPSK=
check "explicit psk honored" "$(cat "$T/data/psk")" "MyExplicitPSK="

# --- Task 2: keys + server conf + idempotency ---
T="$(mktemp -d)"
run_entry "$T" PUBLIC_HOST=vpn.example.com PEERS=2
check "server key persisted" "$( [ -f "$T/data/server.key" ] && echo yes )" "yes"
check "peer1 key persisted"  "$( [ -f "$T/data/peer1.key" ] && echo yes )" "yes"
check "peer2 key persisted"  "$( [ -f "$T/data/peer2.key" ] && echo yes )" "yes"
contains "server conf ListenPort" "$T/data/wg0.conf" "ListenPort = 51820"
contains "server conf 2nd peer ip" "$T/data/wg0.conf" "AllowedIPs = 10.0.0.3/32"

FIRST_SERVER="$(cat "$T/data/server.key")"
# Second boot against the same DATA_DIR, fresh stub state — keys must be reused.
run_entry "$T" PUBLIC_HOST=vpn.example.com PEERS=2
check "server key unchanged on 2nd boot" "$(cat "$T/data/server.key")" "$FIRST_SERVER"

# --- Task 3: client profiles ---
T="$(mktemp -d)"
run_entry "$T" PUBLIC_HOST=vpn.example.com PEERS=1 WG_DNS=9.9.9.9
P="$T/profiles/client1.conf"
check "client1 profile exists" "$( [ -f "$P" ] && echo yes )" "yes"
contains "profile endpoint is relay" "$P" "Endpoint = vpn.example.com:51819"
contains "profile has MaskKey"       "$P" "MaskKey = STUBPSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
contains "profile allowedips full"   "$P" "AllowedIPs = 0.0.0.0/0, ::/0"
contains "profile server pubkey"     "$P" "PublicKey = PUB_of_KEY1"
contains "profile client addr"       "$P" "Address = 10.0.0.2/32"
contains "profile dns"               "$P" "DNS = 9.9.9.9"
contains "qrencode invoked"          "$T/state/calls" "qrencode"

# --- Task 4: bring-up calls ---
T="$(mktemp -d)"
run_entry "$T" PUBLIC_HOST=vpn.example.com
contains "sysctl ip_forward enabled" "$T/state/calls" "sysctl net.ipv4.ip_forward=1"
contains "wg-quick up called"        "$T/state/calls" "wg-quick up wg0"
contains "masquerade rule added"     "$T/state/calls" "iptables -t nat -A POSTROUTING"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
