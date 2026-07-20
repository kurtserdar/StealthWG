package wgserver

import (
	"context"
	"fmt"
	"net"
	"sync"

	"github.com/kurtserdar/StealthWG/quictransport"
	"golang.zx2c4.com/wireguard/conn"
)

// QUICServerBind is a wireguard-go conn.Bind for the all-in-one server's QUIC
// transport. It listens for QUIC sessions, maps each session to the client's
// UDP address (used as the WireGuard endpoint), funnels inbound datagrams into a
// single receive channel, and routes Send back to the right session by endpoint.
// It is the server-side sibling of the client wgbind.QUICBind.
type QUICServerBind struct {
	listenAddr string
	parse      conn.Bind // builds endpoints from the session's remote address
	recv       chan recvItem

	mu       sync.Mutex
	ln       *quictransport.Listener
	sessions map[string]*quictransport.Session
	cancel   context.CancelFunc
	closed   bool
}

type recvItem struct {
	data []byte
	ep   conn.Endpoint
}

// NewQUICServerBind returns a bind that will listen on listenAddr (e.g. ":443").
func NewQUICServerBind(listenAddr string) *QUICServerBind {
	return &QUICServerBind{
		listenAddr: listenAddr,
		parse:      conn.NewStdNetBind(),
		recv:       make(chan recvItem, 64),
		sessions:   make(map[string]*quictransport.Session),
	}
}

// Open binds the QUIC listener and starts accepting sessions. The single receive
// function blocks on the shared channel.
func (b *QUICServerBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	cert, err := quictransport.SelfSignedCert()
	if err != nil {
		return nil, 0, err
	}
	ln, err := quictransport.Listen(b.listenAddr, cert)
	if err != nil {
		return nil, 0, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	b.mu.Lock()
	b.ln = ln
	b.cancel = cancel
	b.mu.Unlock()

	go b.acceptLoop(ctx)

	fn := func(buf []byte) (int, conn.Endpoint, error) {
		item, ok := <-b.recv
		if !ok {
			return 0, nil, net.ErrClosed
		}
		return copy(buf, item.data), item.ep, nil
	}

	actual := uint16(port)
	if ua, ok := ln.Addr().(*net.UDPAddr); ok {
		actual = uint16(ua.Port)
	}
	return []conn.ReceiveFunc{fn}, actual, nil
}

// Addr returns the bound QUIC listen address (valid after Open).
func (b *QUICServerBind) Addr() net.Addr {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln == nil {
		return nil
	}
	return b.ln.Addr()
}

func (b *QUICServerBind) acceptLoop(ctx context.Context) {
	for {
		sess, err := b.ln.Accept(ctx)
		if err != nil {
			return
		}
		ep, err := b.parse.ParseEndpoint(sess.RemoteAddr().String())
		if err != nil {
			sess.Close()
			continue
		}
		key := ep.DstToString()
		b.mu.Lock()
		if b.closed {
			b.mu.Unlock()
			sess.Close()
			return
		}
		if old := b.sessions[key]; old != nil {
			old.Close() // a reconnecting client replaces its stale session
		}
		b.sessions[key] = sess
		b.mu.Unlock()
		go b.readSession(ctx, sess, ep, key)
	}
}

func (b *QUICServerBind) readSession(ctx context.Context, sess *quictransport.Session, ep conn.Endpoint, key string) {
	for {
		d, err := sess.ReceiveDatagram(ctx)
		if err != nil {
			b.mu.Lock()
			if b.sessions[key] == sess {
				delete(b.sessions, key)
			}
			b.mu.Unlock()
			sess.Close()
			return
		}
		select {
		case b.recv <- recvItem{data: append([]byte(nil), d...), ep: ep}:
		case <-ctx.Done():
			return
		}
	}
}

// Send routes buf to the session matching ep. quic-go retains the slice until it
// is packed, and wireguard-go reuses its buffer after Send returns, so copy.
func (b *QUICServerBind) Send(buf []byte, ep conn.Endpoint) error {
	b.mu.Lock()
	sess := b.sessions[ep.DstToString()]
	b.mu.Unlock()
	if sess == nil {
		return fmt.Errorf("quicserverbind: no session for %s", ep.DstToString())
	}
	return sess.SendDatagram(append([]byte(nil), buf...))
}

// Close stops the listener and tears down every session.
func (b *QUICServerBind) Close() error {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return nil
	}
	b.closed = true
	if b.cancel != nil {
		b.cancel()
	}
	for key, s := range b.sessions {
		s.Close()
		delete(b.sessions, key)
	}
	ln := b.ln
	b.mu.Unlock()
	close(b.recv)
	if ln != nil {
		return ln.Close()
	}
	return nil
}

func (b *QUICServerBind) SetMark(mark uint32) error { return nil }

func (b *QUICServerBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	return b.parse.ParseEndpoint(s)
}
