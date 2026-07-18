package config

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseUsesEnvVars(t *testing.T) {
	psk := base64.StdEncoding.EncodeToString([]byte("envpsk-envpsk-envpsk-envpsk-1234"))
	t.Setenv("STEALTHWG_UPSTREAM", "10.0.0.1:51820")
	t.Setenv("STEALTHWG_PSK", psk)
	t.Setenv("STEALTHWG_LISTEN", ":6000")
	t.Setenv("STEALTHWG_PADMAX", "64")
	t.Setenv("STEALTHWG_TIMEOUT", "90s")

	cfg, err := Parse(nil)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if cfg.Upstream != "10.0.0.1:51820" {
		t.Fatalf("env upstream: got %q", cfg.Upstream)
	}
	if cfg.Listen != ":6000" {
		t.Fatalf("env listen: got %q", cfg.Listen)
	}
	if cfg.PadMax != 64 {
		t.Fatalf("env padmax: got %d", cfg.PadMax)
	}
	if cfg.Timeout != 90*time.Second {
		t.Fatalf("env timeout: got %v", cfg.Timeout)
	}
	if string(cfg.PSK) != "envpsk-envpsk-envpsk-envpsk-1234" {
		t.Fatalf("env psk decode mismatch")
	}
}

func TestFlagOverridesEnv(t *testing.T) {
	t.Setenv("STEALTHWG_UPSTREAM", "10.0.0.1:51820")
	t.Setenv("STEALTHWG_PSK", base64.StdEncoding.EncodeToString([]byte("x")))

	cfg, err := Parse([]string{"-upstream", "192.168.1.1:51820"})
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if cfg.Upstream != "192.168.1.1:51820" {
		t.Fatalf("explicit flag should override env: got %q", cfg.Upstream)
	}
}

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
