//go:build !linux && !windows

package main

import (
	"fmt"
	"os"
)

// The client's tunnel engine is Linux/Windows only. This stub keeps `go build ./...`
// working on other platforms (e.g. macOS, the dev machine).
func main() {
	fmt.Fprintln(os.Stderr, "stealthwg-client runs on Linux or Windows only")
	os.Exit(1)
}
