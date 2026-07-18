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
	lenPrefix   = 2 // big-endian uint16 length of wg_packet
	minDatagram = NonceSize + lenPrefix
	infoV1      = "stealthwg/udpmask/v1"
	maxWGPacket = 65535 // bounded by the 2-byte length prefix
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
