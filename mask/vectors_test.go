package mask

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
)

var updateVectors = flag.Bool("update", false, "regenerate testdata/vectors.json")

type vector struct {
	PSK    string `json:"psk"`
	Nonce  string `json:"nonce"`
	WG     string `json:"wg"`
	Pad    string `json:"pad"`
	Masked string `json:"masked"`
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func mustDecode(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatalf("base64 decode: %v", err)
	}
	return b
}

// vectorInputs are the fixed (psk, nonce, wg, pad) tuples. Keep these stable;
// the committed vectors.json is the interop contract with the Swift codec.
func vectorInputs() []vector {
	psk := []byte("stealthwg-interop-psk-v1")
	zeros := make([]byte, NonceSize)
	nonceA := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	return []vector{
		{PSK: b64(psk), Nonce: b64(zeros), WG: b64([]byte{0x01, 0x00, 0x00, 0x00}), Pad: b64(nil)},
		{PSK: b64(psk), Nonce: b64(nonceA), WG: b64([]byte("hello wireguard")), Pad: b64([]byte{0xde, 0xad})},
		{PSK: b64(psk), Nonce: b64(nonceA), WG: b64(make([]byte, 1400)), Pad: b64([]byte{0x00, 0xff, 0x10})},
	}
}

func goldenPath() string { return filepath.Join("testdata", "vectors.json") }

func TestInteropVectors(t *testing.T) {
	inputs := vectorInputs()

	// Fill in the Masked field by running the codec over each input.
	generated := make([]vector, len(inputs))
	for i, in := range inputs {
		c, err := NewCodec(mustDecode(t, in.PSK), 32)
		if err != nil {
			t.Fatalf("NewCodec: %v", err)
		}
		masked, err := c.MaskWith(mustDecode(t, in.Nonce), mustDecode(t, in.WG), mustDecode(t, in.Pad))
		if err != nil {
			t.Fatalf("MaskWith: %v", err)
		}
		in.Masked = b64(masked)
		generated[i] = in

		// Open must recover the original wg bytes.
		got, err := c.Open(masked)
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		if b64(got) != in.WG {
			t.Fatalf("vector %d: open mismatch", i)
		}
	}

	if *updateVectors {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		data, err := json.MarshalIndent(generated, "", "  ")
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		if err := os.WriteFile(goldenPath(), append(data, '\n'), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
	}

	// Compare against the committed golden file.
	want, err := os.ReadFile(goldenPath())
	if err != nil {
		t.Fatalf("read golden (run with -update first): %v", err)
	}
	var golden []vector
	if err := json.Unmarshal(want, &golden); err != nil {
		t.Fatalf("unmarshal golden: %v", err)
	}
	if len(golden) != len(generated) {
		t.Fatalf("golden has %d vectors, generated %d", len(golden), len(generated))
	}
	for i := range golden {
		if golden[i].Masked != generated[i].Masked {
			t.Fatalf("vector %d drift: golden %s generated %s", i, golden[i].Masked, generated[i].Masked)
		}
	}
}
