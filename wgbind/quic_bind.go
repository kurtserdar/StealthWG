package wgbind

import (
	"context"
	"net"
	"sync"

	"github.com/kurtserdar/StealthWG/quictransport"
	"golang.zx2c4.com/wireguard/conn"
)

// QUICBind is a wireguard-go conn.Bind that tunnels WireGuard packets over a real
// QUIC connection (DATAGRAM frames), so the traffic blends with HTTP/3 on UDP 443.
// It is a sibling of MaskBind: a whole transport, not a per-datagram obfuscator.
type QUICBind struct {
	parse conn.Bind // used only for ParseEndpoint
	sni   string

	mu      sync.Mutex
	sess    *quictransport.Session
	ep      conn.Endpoint
	dialErr error
	ready   chan struct{}
}

// NewQUIC returns a QUICBind that dials the peer endpoint over QUIC, presenting sni.
func NewQUIC(sni string) *QUICBind {
	return &QUICBind{parse: conn.NewStdNetBind(), sni: sni, ready: make(chan struct{})}
}

// Open returns a receive function that yields datagrams once the session is dialed
// (on the first Send, which is when wireguard-go knows the peer endpoint).
func (b *QUICBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	recv := func(buf []byte) (int, conn.Endpoint, error) {
		<-b.ready
		b.mu.Lock()
		s, ep := b.sess, b.ep
		b.mu.Unlock()
		if s == nil {
			return 0, ep, net.ErrClosed
		}
		d, err := s.ReceiveDatagram(context.Background())
		if err != nil {
			return 0, ep, err
		}
		return copy(buf, d), ep, nil
	}
	return []conn.ReceiveFunc{recv}, port, nil
}

// Send dials the QUIC session lazily (once) to the peer endpoint, then sends buf
// as a datagram. quic-go retains the slice until it is packed, and wireguard-go
// reuses its buffer after Send returns, so copy.
func (b *QUICBind) Send(buf []byte, ep conn.Endpoint) error {
	if err := b.ensureSession(ep); err != nil {
		return err
	}
	return b.sess.SendDatagram(append([]byte(nil), buf...))
}

func (b *QUICBind) ensureSession(ep conn.Endpoint) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.sess != nil {
		return nil
	}
	if b.dialErr != nil {
		return b.dialErr
	}
	s, err := quictransport.Dial(context.Background(), ep.DstToString(), b.sni)
	if err != nil {
		b.dialErr = err
		return err
	}
	b.sess = s
	b.ep = ep
	close(b.ready)
	return nil
}

// Close, SetMark and ParseEndpoint. ParseEndpoint reuses the standard parser so
// wireguard-go can turn the profile's host:port into an endpoint to dial.
func (b *QUICBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.sess != nil {
		err := b.sess.Close()
		b.sess = nil
		return err
	}
	return nil
}

func (b *QUICBind) SetMark(mark uint32) error { return nil }

func (b *QUICBind) ParseEndpoint(s string) (conn.Endpoint, error) { return b.parse.ParseEndpoint(s) }
