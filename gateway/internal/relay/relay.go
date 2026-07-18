// Package relay is a NAT-like UDP relay. It receives masked datagrams from
// clients, unmasks them and forwards the inner WireGuard packet to an
// unmodified upstream WireGuard endpoint, then masks replies back to the
// originating client. Per-client sessions are garbage-collected when idle.
package relay

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/kurtserdar/StealthWG/gateway/internal/mask"
)

type session struct {
	clientAddr *net.UDPAddr
	upstream   *net.UDPConn
	lastSeen   time.Time
}

// Relay forwards masked client traffic to an upstream WireGuard endpoint.
type Relay struct {
	listen   *net.UDPConn
	upstream *net.UDPAddr
	codec    *mask.Codec
	timeout  time.Duration

	mu       sync.Mutex
	sessions map[string]*session
}

// New binds the listen socket and resolves the upstream address.
func New(listenAddr, upstreamAddr string, codec *mask.Codec, timeout time.Duration) (*Relay, error) {
	lAddr, err := net.ResolveUDPAddr("udp", listenAddr)
	if err != nil {
		return nil, err
	}
	uAddr, err := net.ResolveUDPAddr("udp", upstreamAddr)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", lAddr)
	if err != nil {
		return nil, err
	}
	return &Relay{
		listen:   conn,
		upstream: uAddr,
		codec:    codec,
		timeout:  timeout,
		sessions: make(map[string]*session),
	}, nil
}

// LocalAddr returns the bound listen address.
func (r *Relay) LocalAddr() net.Addr { return r.listen.LocalAddr() }

// Run processes datagrams until ctx is cancelled.
func (r *Relay) Run(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		r.listen.Close()
		r.mu.Lock()
		for _, s := range r.sessions {
			s.upstream.Close()
		}
		r.mu.Unlock()
	}()
	go r.gcLoop(ctx)

	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := r.listen.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
				return err
			}
		}
		wg, err := r.codec.Open(buf[:n])
		if err != nil {
			continue // drop silently
		}
		s := r.getOrCreate(clientAddr)
		if s == nil {
			continue
		}
		s.upstream.Write(wg)
		r.touch(s)
	}
}

func (r *Relay) getOrCreate(clientAddr *net.UDPAddr) *session {
	key := clientAddr.String()
	r.mu.Lock()
	defer r.mu.Unlock()
	if s, ok := r.sessions[key]; ok {
		return s
	}
	up, err := net.DialUDP("udp", nil, r.upstream)
	if err != nil {
		return nil
	}
	s := &session{clientAddr: clientAddr, upstream: up, lastSeen: time.Now()}
	r.sessions[key] = s
	go r.upstreamReader(s)
	return s
}

// upstreamReader masks upstream replies back to the client until the socket
// is closed (by GC or shutdown).
func (r *Relay) upstreamReader(s *session) {
	buf := make([]byte, 65535)
	for {
		n, err := s.upstream.Read(buf)
		if err != nil {
			return
		}
		masked, err := r.codec.Seal(buf[:n])
		if err != nil {
			continue
		}
		r.listen.WriteToUDP(masked, s.clientAddr)
		r.touch(s)
	}
}

func (r *Relay) touch(s *session) {
	r.mu.Lock()
	s.lastSeen = time.Now()
	r.mu.Unlock()
}

func (r *Relay) gcLoop(ctx context.Context) {
	ticker := time.NewTicker(r.timeout / 2)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			now := time.Now()
			r.mu.Lock()
			for key, s := range r.sessions {
				if now.Sub(s.lastSeen) > r.timeout {
					s.upstream.Close()
					delete(r.sessions, key)
				}
			}
			r.mu.Unlock()
		}
	}
}
