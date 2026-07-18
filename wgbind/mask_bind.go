// Package wgbind provides a wireguard-go conn.Bind that masks and unmasks UDP
// datagrams with the StealthWG UdpMask codec, so WireGuard traffic no longer
// matches its on-wire fingerprint.
//
// It is a thin wrapper: outbound packets are Sealed before the inner bind sends
// them, inbound datagrams are Opened after the inner bind receives them. All
// cryptographic security remains WireGuard's; this only reshapes the bytes.
package wgbind

import (
	"github.com/kurtserdar/StealthWG/mask"
	"golang.zx2c4.com/wireguard/conn"
)

// maxDatagram bounds the scratch buffer used to receive a masked datagram; it
// is the largest a UDP payload can be.
const maxDatagram = 65535

// MaskBind wraps an inner conn.Bind and applies the UdpMask codec at the UDP
// I/O boundary.
type MaskBind struct {
	inner conn.Bind
	codec *mask.Codec
}

// New returns a conn.Bind that masks traffic through inner using codec.
func New(inner conn.Bind, codec *mask.Codec) *MaskBind {
	return &MaskBind{inner: inner, codec: codec}
}

// Open opens the inner bind and wraps each receive function so that inbound
// datagrams are unmasked before wireguard-go sees them.
func (b *MaskBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	fns, actualPort, err := b.inner.Open(port)
	if err != nil {
		return nil, 0, err
	}
	wrapped := make([]conn.ReceiveFunc, len(fns))
	for i := range fns {
		inner := fns[i]
		// Each receive function is driven by a single goroutine in
		// wireguard-go, so one reusable scratch buffer per function is safe.
		scratch := make([]byte, maxDatagram)
		wrapped[i] = func(buf []byte) (int, conn.Endpoint, error) {
			n, ep, err := inner(scratch)
			if err != nil {
				return 0, ep, err
			}
			wg, err := b.codec.Open(scratch[:n])
			if err != nil {
				// Undecryptable/garbage datagram: drop it by reporting an
				// empty read rather than surfacing bytes to WireGuard.
				return 0, ep, nil
			}
			return copy(buf, wg), ep, nil
		}
	}
	return wrapped, actualPort, nil
}

// Send masks b and sends it through the inner bind.
func (b *MaskBind) Send(buf []byte, ep conn.Endpoint) error {
	masked, err := b.codec.Seal(buf)
	if err != nil {
		return err
	}
	return b.inner.Send(masked, ep)
}

// Close, SetMark and ParseEndpoint delegate unchanged to the inner bind.
func (b *MaskBind) Close() error                                  { return b.inner.Close() }
func (b *MaskBind) SetMark(mark uint32) error                     { return b.inner.SetMark(mark) }
func (b *MaskBind) ParseEndpoint(s string) (conn.Endpoint, error) { return b.inner.ParseEndpoint(s) }
