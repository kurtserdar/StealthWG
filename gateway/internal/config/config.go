// Package config parses gateway command-line flags into a validated Config.
//
// Every flag also has a STEALTHWG_* environment-variable fallback so the gateway
// is easy to configure inside a container. Precedence: explicit flag > env var >
// built-in default.
package config

import (
	"encoding/base64"
	"errors"
	"flag"
	"os"
	"strconv"
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

// envStr returns the environment variable value, or def if it is unset/empty.
func envStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// envDuration parses a duration from the environment, falling back to def.
func envDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

// envInt parses an int from the environment, falling back to def.
func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// Parse reads flags from args (excluding the program name). Each flag falls back
// to its STEALTHWG_* environment variable when not passed explicitly.
func Parse(args []string) (*Config, error) {
	fs := flag.NewFlagSet("stealthwg-gateway", flag.ContinueOnError)
	listen := fs.String("listen", envStr("STEALTHWG_LISTEN", ":51819"), "mask-side UDP listen address")
	upstream := fs.String("upstream", envStr("STEALTHWG_UPSTREAM", ""), "upstream WireGuard endpoint host:port (required)")
	psk := fs.String("psk", envStr("STEALTHWG_PSK", ""), "obfuscation PSK, base64 (or use -psk-file)")
	pskFile := fs.String("psk-file", envStr("STEALTHWG_PSK_FILE", ""), "path to a file containing the base64 PSK")
	timeout := fs.Duration("timeout", envDuration("STEALTHWG_TIMEOUT", 180*time.Second), "idle session timeout")
	padMax := fs.Int("padmax", envInt("STEALTHWG_PADMAX", 32), "maximum random padding per packet (0..255)")
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
