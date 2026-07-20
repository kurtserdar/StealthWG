package quictransport

import (
	"bytes"
	"context"
	"testing"
	"time"
)

func TestDatagramRoundTrip(t *testing.T) {
	cert, err := SelfSignedCert()
	if err != nil {
		t.Fatal(err)
	}
	ln, err := Listen("127.0.0.1:0", cert)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	// Server: accept one session and echo the first datagram back.
	go func() {
		s, err := ln.Accept(context.Background())
		if err != nil {
			return
		}
		d, err := s.ReceiveDatagram(context.Background())
		if err != nil {
			return
		}
		_ = s.SendDatagram(append([]byte("echo:"), d...))
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sess, err := Dial(ctx, ln.Addr().String(), "example.com")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer sess.Close()

	payload := []byte("this stands in for a WireGuard packet")
	if err := sess.SendDatagram(payload); err != nil {
		t.Fatalf("send: %v", err)
	}
	got, err := sess.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatalf("receive: %v", err)
	}
	if !bytes.Equal(got, append([]byte("echo:"), payload...)) {
		t.Fatalf("round trip mismatch: %q", got)
	}
}
