package wgbind

import (
	"bytes"
	"net"
	"testing"
	"time"

	"github.com/kurtserdar/StealthWG/mask"
	"golang.zx2c4.com/wireguard/conn"
)

func newTestCodec(t *testing.T) *mask.Codec {
	t.Helper()
	c, err := mask.NewCodec([]byte("wgbind-test-psk-000000000"), 32)
	if err != nil {
		t.Fatalf("NewCodec: %v", err)
	}
	return c
}

// startFakeGateway mimics the StealthWG gateway: it unmasks each datagram and
// echoes it back re-masked. A MaskBind round trip through it must therefore
// recover the original payload.
func startFakeGateway(t *testing.T, codec *mask.Codec) *net.UDPConn {
	t.Helper()
	gw, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen gateway: %v", err)
	}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := gw.ReadFromUDP(buf)
			if err != nil {
				return
			}
			wg, err := codec.Open(buf[:n])
			if err != nil {
				continue // drop garbage, like the real gateway
			}
			back, err := codec.Seal(wg)
			if err != nil {
				continue
			}
			gw.WriteToUDP(back, addr)
		}
	}()
	return gw
}

func TestMaskBindRoundTripThroughGateway(t *testing.T) {
	codec := newTestCodec(t)
	gw := startFakeGateway(t, codec)
	defer gw.Close()

	mb := New(conn.NewStdNetBind(), codec)
	fns, _, err := mb.Open(0)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer mb.Close()

	ep, err := mb.ParseEndpoint(gw.LocalAddr().String())
	if err != nil {
		t.Fatalf("ParseEndpoint: %v", err)
	}

	payload := []byte("this stands in for a WireGuard packet")
	if err := mb.Send(payload, ep); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// The echo returns on exactly one of the receive functions; run them all
	// and take the first non-empty delivery. Losing functions unblock when the
	// deferred Close runs.
	results := make(chan []byte, len(fns))
	for _, fn := range fns {
		fn := fn
		go func() {
			buf := make([]byte, 65535)
			n, _, err := fn(buf)
			if err != nil || n == 0 {
				return
			}
			results <- append([]byte(nil), buf[:n]...)
		}()
	}

	select {
	case got := <-results:
		if !bytes.Equal(got, payload) {
			t.Fatalf("round trip mismatch: got %q want %q", got, payload)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for masked round trip")
	}
}

// TestSendPutsMaskedBytesOnWire confirms that what Send emits is masked (not the
// plaintext) and that the gateway-side Open recovers it — i.e. the fingerprint
// is gone on the wire.
func TestSendPutsMaskedBytesOnWire(t *testing.T) {
	codec := newTestCodec(t)

	// A raw listener stands in for the wire: it captures the exact datagram.
	wire, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen wire: %v", err)
	}
	defer wire.Close()

	mb := New(conn.NewStdNetBind(), codec)
	if _, _, err := mb.Open(0); err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer mb.Close()

	ep, err := mb.ParseEndpoint(wire.LocalAddr().String())
	if err != nil {
		t.Fatalf("ParseEndpoint: %v", err)
	}

	payload := []byte("wireguard-ish payload")
	if err := mb.Send(payload, ep); err != nil {
		t.Fatalf("Send: %v", err)
	}

	wire.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 65535)
	n, _, err := wire.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("read wire: %v", err)
	}
	onWire := buf[:n]

	if bytes.Equal(onWire, payload) {
		t.Fatal("payload was sent in the clear; masking did not run")
	}
	recovered, err := codec.Open(onWire)
	if err != nil {
		t.Fatalf("gateway-side Open failed: %v", err)
	}
	if !bytes.Equal(recovered, payload) {
		t.Fatalf("recovered mismatch: got %q want %q", recovered, payload)
	}
}
