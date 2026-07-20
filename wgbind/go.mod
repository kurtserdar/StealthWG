module github.com/kurtserdar/StealthWG/wgbind

go 1.25.0

require (
	github.com/kurtserdar/StealthWG/mask v0.0.0
	github.com/kurtserdar/StealthWG/quictransport v0.0.0
	golang.zx2c4.com/wireguard v0.0.0-20230209153558-1e2c3e5a3c14
)

require (
	github.com/quic-go/quic-go v0.60.0 // indirect
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
)

replace github.com/kurtserdar/StealthWG/mask => ../mask

replace github.com/kurtserdar/StealthWG/quictransport => ../quictransport
