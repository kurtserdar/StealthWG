package relay

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/kurtserdar/StealthWG/quictransport"
)

// TestQUICRelayForwards runs a loopback UDP "WireGuard" upstream that echoes with
// a prefix, then drives a datagram client -> QUIC relay -> upstream and back.
func TestQUICRelayForwards(t *testing.T) {
	// Loopback upstream: echo each UDP packet back with an "up:" prefix.
	upConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer upConn.Close()
	go func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := upConn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			upConn.WriteToUDP(append([]byte("up:"), buf[:n]...), addr)
		}
	}()

	r, err := NewQUIC("127.0.0.1:0", upConn.LocalAddr().String(), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(ctx)

	dialCtx, dialCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer dialCancel()
	sess, err := quictransport.Dial(dialCtx, r.Addr().String(), "example.com")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer sess.Close()

	payload := []byte("wireguard handshake init")
	if err := sess.SendDatagram(payload); err != nil {
		t.Fatalf("send: %v", err)
	}
	got, err := sess.ReceiveDatagram(dialCtx)
	if err != nil {
		t.Fatalf("receive: %v", err)
	}
	if string(got) != "up:"+string(payload) {
		t.Fatalf("relay round trip mismatch: %q", got)
	}
}
