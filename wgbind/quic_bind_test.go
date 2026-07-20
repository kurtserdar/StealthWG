package wgbind

import (
	"bytes"
	"context"
	"testing"

	"github.com/kurtserdar/StealthWG/quictransport"
)

// TestQUICBindRoundTrip sends a packet through QUICBind to a QUIC echo server and
// confirms it comes back — the client transport path over real QUIC datagrams.
func TestQUICBindRoundTrip(t *testing.T) {
	cert, err := quictransport.SelfSignedCert()
	if err != nil {
		t.Fatal(err)
	}
	ln, err := quictransport.Listen("127.0.0.1:0", cert)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	go func() {
		s, err := ln.Accept(context.Background())
		if err != nil {
			return
		}
		for {
			d, err := s.ReceiveDatagram(context.Background())
			if err != nil {
				return
			}
			_ = s.SendDatagram(d) // echo
		}
	}()

	b := NewQUIC("example.com")
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer b.Close()

	ep, err := b.ParseEndpoint(ln.Addr().String())
	if err != nil {
		t.Fatalf("parse endpoint: %v", err)
	}
	payload := []byte("wireguard-ish payload over quic")
	if err := b.Send(payload, ep); err != nil {
		t.Fatalf("send: %v", err)
	}
	buf := make([]byte, 65535)
	n, _, err := fns[0](buf)
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if !bytes.Equal(buf[:n], payload) {
		t.Fatalf("round trip mismatch: %q", buf[:n])
	}
}
