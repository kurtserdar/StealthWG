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
//
// The session is dialed lazily on the first Send and re-dialed when the peer
// endpoint changes (endpoint fallback), so a single QUICBind follows the tunnel
// across its candidate endpoints.
type QUICBind struct {
	parse conn.Bind // used only for ParseEndpoint
	sni   string

	mu     sync.Mutex
	sess   *quictransport.Session
	ep     conn.Endpoint
	epStr  string
	signal chan struct{} // closed to wake the receiver when a session appears
	closed bool
}

// NewQUIC returns a QUICBind that dials the peer endpoint over QUIC, presenting sni.
func NewQUIC(sni string) *QUICBind {
	return &QUICBind{parse: conn.NewStdNetBind(), sni: sni}
}

// Open returns a receive function that yields datagrams from the current session,
// blocking until one is dialed (on the first Send) and transparently following
// re-dials to a new endpoint.
func (b *QUICBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	recv := func(buf []byte) (int, conn.Endpoint, error) {
		for {
			b.mu.Lock()
			if b.closed {
				b.mu.Unlock()
				return 0, nil, net.ErrClosed
			}
			s, ep := b.sess, b.ep
			if s == nil {
				if b.signal == nil {
					b.signal = make(chan struct{})
				}
				ch := b.signal
				b.mu.Unlock()
				<-ch // wait for a session (or Close)
				continue
			}
			b.mu.Unlock()

			d, err := s.ReceiveDatagram(s.Context())
			if err != nil {
				b.mu.Lock()
				if b.sess == s {
					b.sess = nil // session died; a later Send re-dials
				}
				b.mu.Unlock()
				continue
			}
			return copy(buf, d), ep, nil
		}
	}
	return []conn.ReceiveFunc{recv}, port, nil
}

// Send dials (or re-dials) the QUIC session for ep, then sends buf as a datagram.
// quic-go retains the slice until it is packed, and wireguard-go reuses its
// buffer after Send returns, so copy.
func (b *QUICBind) Send(buf []byte, ep conn.Endpoint) error {
	s, err := b.sessionFor(ep)
	if err != nil {
		return err
	}
	return s.SendDatagram(append([]byte(nil), buf...))
}

// sessionFor returns a session connected to ep, dialing a new one when there is
// none or the endpoint changed. Dialing happens outside the lock.
func (b *QUICBind) sessionFor(ep conn.Endpoint) (*quictransport.Session, error) {
	epStr := ep.DstToString()

	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return nil, net.ErrClosed
	}
	if b.sess != nil && b.epStr == epStr {
		s := b.sess
		b.mu.Unlock()
		return s, nil
	}
	b.mu.Unlock()

	s, err := quictransport.Dial(context.Background(), epStr, b.sni)
	if err != nil {
		return nil, err
	}

	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		s.Close()
		return nil, net.ErrClosed
	}
	// A concurrent Send may have already dialed this endpoint; keep that one.
	if b.sess != nil && b.epStr == epStr {
		existing := b.sess
		b.mu.Unlock()
		s.Close()
		return existing, nil
	}
	old := b.sess
	b.sess = s
	b.ep = ep
	b.epStr = epStr
	if b.signal != nil {
		close(b.signal) // wake the receiver onto the new session
		b.signal = nil
	}
	b.mu.Unlock()

	if old != nil {
		old.Close()
	}
	return s, nil
}

// Close tears down the current session and unblocks a waiting receiver.
func (b *QUICBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil
	}
	b.closed = true
	if b.signal != nil {
		close(b.signal)
		b.signal = nil
	}
	if b.sess != nil {
		err := b.sess.Close()
		b.sess = nil
		return err
	}
	return nil
}

func (b *QUICBind) SetMark(mark uint32) error { return nil }

func (b *QUICBind) ParseEndpoint(s string) (conn.Endpoint, error) { return b.parse.ParseEndpoint(s) }
