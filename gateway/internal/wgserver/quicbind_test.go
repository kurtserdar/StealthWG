package wgserver

import (
	"context"
	"testing"
	"time"

	"github.com/kurtserdar/StealthWG/quictransport"
)

// TestQUICServerBindRoundTrip drives a QUIC client through QUICServerBind: an
// inbound datagram surfaces on the receive func tagged with the client endpoint,
// and Send routes a reply back to that same client.
func TestQUICServerBindRoundTrip(t *testing.T) {
	b := NewQUICServerBind("127.0.0.1:0")
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer b.Close()
	if b.Addr() == nil {
		t.Fatal("nil listen addr after Open")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sess, err := quictransport.Dial(ctx, b.Addr().String(), "example.com")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer sess.Close()

	payload := []byte("wireguard handshake init")
	if err := sess.SendDatagram(payload); err != nil {
		t.Fatalf("send: %v", err)
	}

	buf := make([]byte, 65535)
	n, ep, err := fns[0](buf)
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if string(buf[:n]) != string(payload) {
		t.Fatalf("inbound mismatch: %q", buf[:n])
	}

	// Route a reply back to the same client via Send.
	reply := []byte("wireguard handshake resp")
	if err := b.Send(reply, ep); err != nil {
		t.Fatalf("server send: %v", err)
	}
	got, err := sess.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatalf("client recv: %v", err)
	}
	if string(got) != string(reply) {
		t.Fatalf("reply mismatch: %q", got)
	}
}
