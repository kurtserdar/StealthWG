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
