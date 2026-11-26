package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"slices"
	"strings"
	"sync"

	"tailscale.com/net/dns"
	"tailscale.com/net/tsaddr"
	"tailscale.com/tsnet"
)

type baseDNSInput struct {
	Nameservers []string `json:"nameservers"`
}

func parseBaseDNS(text string) ([]netip.Addr, error) {
	if len(text) == 0 || len(text) > 16384 {
		return nil, errors.New("input capacity")
	}
	var input baseDNSInput
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil {
		return nil, errors.New("invalid input")
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil, errors.New("invalid input")
	}
	if len(input.Nameservers) == 0 || len(input.Nameservers) > 64 {
		return nil, errors.New("resolver capacity")
	}
	addresses := make([]netip.Addr, 0, len(input.Nameservers))
	for _, value := range input.Nameservers {
		address, err := netip.ParseAddr(value)
		if err != nil {
			return nil, errors.New("invalid resolver")
		}
		address = address.Unmap()
		plain := address.WithZone("")
		if plain.IsUnspecified() || plain.IsLoopback() || plain.IsMulticast() ||
			(!plain.IsGlobalUnicast() && !plain.IsLinkLocalUnicast()) ||
			(address.Zone() != "" && !plain.IsLinkLocalUnicast()) {
			return nil, errors.New("invalid resolver")
		}
		if plain == tsaddr.TailscaleServiceIP() || plain == tsaddr.TailscaleServiceIPv6() {
			return nil, errors.New("resolver loop")
		}
		if !slices.Contains(addresses, address) {
			addresses = append(addresses, address)
		}
	}
	return addresses, nil
}

// setBaseDNS accepts only platform-supplied physical resolvers. It never
// substitutes a public resolver or changes the control-plane split-DNS policy.
func (b *backendController) setBaseDNS(text string) string {
	base, err := parseBaseDNS(text)
	if err != nil {
		return "FAILED | DNS base | " + err.Error()
	}
	b.dnsUpdateMu.Lock()
	defer b.dnsUpdateMu.Unlock()
	b.mu.Lock()
	b.dnsBase = slices.Clone(base)
	server, adapter, generation := b.server, b.dnsAdapter, b.generation
	if adapter != nil {
		adapter.replaceBase(base)
	}
	b.mu.Unlock()
	if server == nil || adapter == nil {
		return "OK | DNS base staged"
	}
	err = server.RecompileDNSConfig()
	b.mu.Lock()
	current := b.server == server && b.dnsAdapter == adapter && b.generation == generation
	b.mu.Unlock()
	if !current {
		return "FAILED | DNS base | session changed"
	}
	if errors.Is(err, tsnet.ErrDNSNotReady) || errors.Is(err, dns.ErrNoDNSConfig) {
		// A later netmap will compile using the staged physical DNS base.
		return "OK | DNS base staged"
	}
	if err != nil {
		return "FAILED | DNS base | compilation unavailable"
	}
	return "OK | DNS base updated"
}

// harmonyDNSConfigurator lets Tailscale compile its complete DNS policy while
// HarmonyOS retains ownership of VPN DNS application. The physical DNS base is
// independent of SetDNS output so Quad100 can never become its own upstream.
type harmonyDNSConfigurator struct {
	mu     sync.Mutex
	base   []netip.Addr
	closed bool
}

func newHarmonyDNSConfigurator(base []netip.Addr) *harmonyDNSConfigurator {
	return &harmonyDNSConfigurator{base: slices.Clone(base)}
}

func (d *harmonyDNSConfigurator) replaceBase(base []netip.Addr) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.closed {
		d.base = slices.Clone(base)
	}
}

func (d *harmonyDNSConfigurator) SupportsSplitDNS() bool { return false }

func (d *harmonyDNSConfigurator) GetBaseConfig() (dns.OSConfig, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return dns.OSConfig{}, errors.New("DNS configurator closed")
	}
	if len(d.base) == 0 {
		return dns.OSConfig{}, dns.ErrGetBaseConfigNotSupported
	}
	return dns.OSConfig{Nameservers: slices.Clone(d.base)}, nil
}

func (d *harmonyDNSConfigurator) SetDNS(dns.OSConfig) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return errors.New("DNS configurator closed")
	}
	// The ArkTS VPN extension applies the DNS server through VpnConnection.
	return nil
}

func (d *harmonyDNSConfigurator) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.closed = true
	d.base = nil
	return nil
}
