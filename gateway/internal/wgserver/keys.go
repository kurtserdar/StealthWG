// Package wgserver is the all-in-one masked WireGuard server: it embeds
// wireguard-go with the StealthWG masking bind so a single process terminates a
// masked WireGuard tunnel (mirroring the iOS/macOS client architecture).
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
	if _, err = rand.Read(p[:]); err != nil {
		return "", "", err
	}
	pubBytes, err := curve25519.X25519(p[:], curve25519.Basepoint)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(p[:]),
		base64.StdEncoding.EncodeToString(pubBytes), nil
}

// PublicKeyFromPrivate derives the base64 public key from a base64 private key.
func PublicKeyFromPrivate(privB64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(privB64)
	if err != nil || len(raw) != 32 {
		return "", fmt.Errorf("invalid private key")
	}
	pub, err := curve25519.X25519(raw, curve25519.Basepoint)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}

// GeneratePSK returns 32 random bytes, base64 — the mask PSK.
func GeneratePSK() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(b[:]), nil
}
