package main

import "golang.org/x/sys/windows"

// elevated reports whether the process runs with an elevated (Administrator) token.
func elevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}
