module github.com/kurtserdar/StealthWG/gateway

go 1.25.0

require (
	github.com/kurtserdar/StealthWG/wgbind v0.0.0-00010101000000-000000000000
	golang.org/x/crypto v0.54.0
	golang.zx2c4.com/wireguard v0.0.0-20230209153558-1e2c3e5a3c14
)

require (
	golang.org/x/net v0.56.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2 // indirect
)

require (
	github.com/kurtserdar/StealthWG/mask v0.0.0
	github.com/kurtserdar/StealthWG/quictransport v0.0.0
	golang.org/x/sys v0.47.0 // indirect
)

require github.com/quic-go/quic-go v0.60.0 // indirect

replace github.com/kurtserdar/StealthWG/mask => ../mask

replace github.com/kurtserdar/StealthWG/wgbind => ../wgbind

replace github.com/kurtserdar/StealthWG/quictransport => ../quictransport
