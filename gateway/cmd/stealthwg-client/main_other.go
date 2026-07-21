//go:build !linux

package main

import (
	"fmt"
	"os"
)

// The client's tunnel engine (TUN + `ip` routing) is Linux-only. This stub keeps
// `go build ./...` working on other platforms.
func main() {
	fmt.Fprintln(os.Stderr, "stealthwg-client runs on Linux only")
	os.Exit(1)
}
