//go:build !windows

package main

import "os"

// elevated reports whether the process runs as root.
func elevated() bool { return os.Geteuid() == 0 }
