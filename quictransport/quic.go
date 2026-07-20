// Package quictransport carries WireGuard packets as QUIC DATAGRAM frames, so the
// tunnel blends with legitimate HTTP/3 (QUIC on UDP 443). It uses real quic-go;
// WireGuard remains the only trusted crypto, so the QUIC TLS is for blending only
// (self-signed server + InsecureSkipVerify client).
package quictransport

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"time"

	"github.com/quic-go/quic-go"
)

// alpn advertises HTTP/3 so the connection blends with ordinary web QUIC.
const alpn = "h3"

// Session is a QUIC connection used to exchange WireGuard packets as datagrams.
type Session struct{ conn *quic.Conn }

// SendDatagram sends one WireGuard packet as a QUIC datagram.
func (s *Session) SendDatagram(b []byte) error { return s.conn.SendDatagram(b) }

// ReceiveDatagram blocks for the next datagram.
func (s *Session) ReceiveDatagram(ctx context.Context) ([]byte, error) {
	return s.conn.ReceiveDatagram(ctx)
}

// Close terminates the session.
func (s *Session) Close() error { return s.conn.CloseWithError(0, "") }

// Context is done when the session ends.
func (s *Session) Context() context.Context { return s.conn.Context() }

// RemoteAddr is the peer address.
func (s *Session) RemoteAddr() net.Addr { return s.conn.RemoteAddr() }

// Dial opens a QUIC session to addr, presenting sni (self-signed servers accepted).
func Dial(ctx context.Context, addr, sni string) (*Session, error) {
	conn, err := quic.DialAddr(ctx, addr, &tls.Config{
		InsecureSkipVerify: true,
		ServerName:         sni,
		NextProtos:         []string{alpn},
	}, &quic.Config{EnableDatagrams: true})
	if err != nil {
		return nil, err
	}
	return &Session{conn: conn}, nil
}

// Listener accepts QUIC sessions.
type Listener struct{ ln *quic.Listener }

// Accept returns the next incoming session.
func (l *Listener) Accept(ctx context.Context) (*Session, error) {
	conn, err := l.ln.Accept(ctx)
	if err != nil {
		return nil, err
	}
	return &Session{conn: conn}, nil
}

// Addr is the listen address.
func (l *Listener) Addr() net.Addr { return l.ln.Addr() }

// Close stops the listener.
func (l *Listener) Close() error { return l.ln.Close() }

// Listen starts a QUIC listener with datagrams enabled.
func Listen(addr string, cert tls.Certificate) (*Listener, error) {
	ln, err := quic.ListenAddr(addr, &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{alpn},
	}, &quic.Config{EnableDatagrams: true})
	if err != nil {
		return nil, err
	}
	return &Listener{ln: ln}, nil
}

// SelfSignedCert generates an ephemeral self-signed TLS certificate. WireGuard,
// not this cert, authenticates the peer — the cert only lets QUIC/TLS complete.
func SelfSignedCert() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "stealthwg"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(10 * 365 * 24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}
