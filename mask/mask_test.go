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
