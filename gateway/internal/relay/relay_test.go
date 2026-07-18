package relay

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/kurtserdar/StealthWG/mask"
)

// startEchoUpstream stands in for the real WireGuard server: it echoes any
// datagram back to its sender.
func startEchoUpstream(t *testing.T) *net.UDPConn {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen upstream: %v", err)
	}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			conn.WriteToUDP(buf[:n], addr)
		}
	}()
	return conn
}

func TestRelayRoundTrip(t *testing.T) {
	upstream := startEchoUpstream(t)
	defer upstream.Close()

	codec, err := mask.NewCodec([]byte("relay-test-psk-000000000"), 32)
	if err != nil {
		t.Fatalf("NewCodec: %v", err)
	}

	r, err := New("127.0.0.1:0", upstream.LocalAddr().String(), codec, 2*time.Second)
	if err != nil {
		t.Fatalf("New relay: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(ctx)

	client, err := net.DialUDP("udp", nil, r.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatalf("dial relay: %v", err)
	}
	defer client.Close()

	wg := []byte("packet that should survive the round trip")
	masked, err := codec.Seal(wg)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if _, err := client.Write(masked); err != nil {
		t.Fatalf("client write: %v", err)
	}

	client.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 65535)
	n, err := client.Read(buf)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	got, err := codec.Open(buf[:n])
	if err != nil {
		t.Fatalf("open reply: %v", err)
	}
	if string(got) != string(wg) {
		t.Fatalf("round trip mismatch: got %q want %q", got, wg)
	}
}

func TestRelayDropsGarbageSilently(t *testing.T) {
	upstream := startEchoUpstream(t)
	defer upstream.Close()
	codec, _ := mask.NewCodec([]byte("relay-test-psk-000000000"), 32)

	r, err := New("127.0.0.1:0", upstream.LocalAddr().String(), codec, 2*time.Second)
	if err != nil {
		t.Fatalf("New relay: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(ctx)

	client, _ := net.DialUDP("udp", nil, r.LocalAddr().(*net.UDPAddr))
	defer client.Close()

	// A datagram shorter than the 14-byte minimum can never be a valid frame,
	// so the relay must drop it silently and never reply (probe resistance).
	client.Write([]byte("tooshort"))
	client.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	buf := make([]byte, 65535)
	if _, err := client.Read(buf); err == nil {
		t.Fatal("expected no reply to garbage, got one")
	}
}

func TestNewRejectsNonPositiveTimeout(t *testing.T) {
	codec, err := mask.NewCodec([]byte("relay-test-psk-000000000"), 32)
	if err != nil {
		t.Fatalf("NewCodec: %v", err)
	}
	if _, err := New("127.0.0.1:0", "127.0.0.1:51820", codec, 0); err == nil {
		t.Fatal("expected error for zero timeout")
	}
}
