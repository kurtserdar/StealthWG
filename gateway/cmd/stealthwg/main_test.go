package main

import (
	"os"
	"testing"
)

func TestNoSystemd(t *testing.T) {
	os.Unsetenv("STEALTHWG_NO_SYSTEMD")
	if noSystemd() {
		t.Fatal("noSystemd should be false when the env var is unset")
	}
	t.Setenv("STEALTHWG_NO_SYSTEMD", "1")
	if !noSystemd() {
		t.Fatal("noSystemd should be true when STEALTHWG_NO_SYSTEMD is set")
	}
}
