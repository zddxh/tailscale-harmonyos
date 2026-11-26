// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package tsnet

import (
	"errors"
	"net"
)

// ErrDNSNotReady means startup has not created the DNS manager yet.
var ErrDNSNotReady = errors.New("tsnet: DNS manager not ready")

type dnsConfigRecompiler interface {
	RecompileDNSConfig() error
}

// RecompileDNSConfig refreshes the physical DNS base without starting a server.
// Close waits for an in-flight compilation before closing the DNS manager.
func (s *Server) RecompileDNSConfig() error {
	s.dnsOpMu.Lock()
	defer s.dnsOpMu.Unlock()
	if s.dnsClosing {
		return net.ErrClosed
	}
	if s.dnsRecompiler == nil {
		return ErrDNSNotReady
	}
	return s.dnsRecompiler.RecompileDNSConfig()
}
