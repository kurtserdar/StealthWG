#ifndef STEALTH_BRIDGE_H
#define STEALTH_BRIDGE_H

// Declares the StealthWG export from the patched wireguard-go bridge. The symbol
// lives in libwg-go.a, which the packet tunnel extension links transitively via
// WireGuardKit, so it resolves at link time without importing the Go module.
//
// Pass a base64-encoded PSK to enable the UdpMask bind on the next tunnel
// start; pass an empty string to clear it (plain WireGuard). Returns 0 on
// success, -1 on an invalid key.
extern int wgSetStealthKey(const char *key_base64);

// Selects the transport for the next tunnel start. mode is "mask" (or "", the
// UdpMask bind with the key from wgSetStealthKey) or "quic" (QUIC datagram
// transport presenting sni as the TLS server name). Always returns 0.
extern int wgSetTransport(const char *mode, const char *sni);

#endif /* STEALTH_BRIDGE_H */
