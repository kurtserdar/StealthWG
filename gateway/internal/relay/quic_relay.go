package relay

import (
	"context"
	"net"
	"time"

	"github.com/kurtserdar/StealthWG/quictransport"
)

// QUICRelay accepts QUIC sessions from clients and forwards each datagram (a raw
// WireGuard packet) to an unmodified upstream WireGuard endpoint over UDP, then
// sends replies back on the same session. It is the QUIC sibling of Relay: the
// QUIC/TLS layer replaces the UDP mask codec as the blending wrapper, while
// WireGuard remains the only authenticated crypto. Per-session lifetime is bound
// to the QUIC connection (idle sessions time out via QUIC's own idle timeout);
// an idle upstream socket is torn down after timeout.
type QUICRelay struct {
	ln       *quictransport.Listener
	upstream *net.UDPAddr
	timeout  time.Duration
}

// NewQUIC resolves the upstream address, generates an ephemeral self-signed TLS
// certificate (blending only — WireGuard authenticates the peer) and binds the
// QUIC listener.
func NewQUIC(listenAddr, upstreamAddr string, timeout time.Duration) (*QUICRelay, error) {
	uAddr, err := net.ResolveUDPAddr("udp", upstreamAddr)
	if err != nil {
		return nil, err
	}
	cert, err := quictransport.SelfSignedCert()
	if err != nil {
		return nil, err
	}
	ln, err := quictransport.Listen(listenAddr, cert)
	if err != nil {
		return nil, err
	}
	return &QUICRelay{ln: ln, upstream: uAddr, timeout: timeout}, nil
}

// Addr returns the bound QUIC listen address.
func (r *QUICRelay) Addr() net.Addr { return r.ln.Addr() }

// Run accepts sessions until ctx is cancelled.
func (r *QUICRelay) Run(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		r.ln.Close()
	}()
	for {
		sess, err := r.ln.Accept(ctx)
		if err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
				return err
			}
		}
		go r.handle(sess)
	}
}

// handle bridges one QUIC session to a dedicated upstream UDP socket in both
// directions until either side closes.
func (r *QUICRelay) handle(sess *quictransport.Session) {
	defer sess.Close()
	up, err := net.DialUDP("udp", nil, r.upstream)
	if err != nil {
		return
	}
	defer up.Close()

	// Upstream WireGuard replies -> client, over the QUIC session. The read
	// deadline frees a wedged upstream socket after an idle stretch; client
	// activity below keeps extending it.
	go func() {
		buf := make([]byte, 65535)
		for {
			up.SetReadDeadline(time.Now().Add(r.timeout))
			n, err := up.Read(buf)
			if err != nil {
				return
			}
			if err := sess.SendDatagram(buf[:n]); err != nil {
				return
			}
		}
	}()

	// Client datagrams -> upstream WireGuard. Session GC is governed by QUIC's
	// own idle timeout; when the session ends, ReceiveDatagram errors and the
	// deferred up.Close() unblocks the reader above.
	sctx := sess.Context()
	for {
		d, err := sess.ReceiveDatagram(sctx)
		if err != nil {
			return
		}
		up.SetReadDeadline(time.Now().Add(r.timeout))
		if _, err := up.Write(d); err != nil {
			return
		}
	}
}
