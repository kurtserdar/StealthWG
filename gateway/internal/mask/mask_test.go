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
