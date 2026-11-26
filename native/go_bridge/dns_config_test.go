package main

import (
	"context"
	"errors"
	"net/netip"
	"reflect"
	"strings"
	"testing"
	"time"

	mdns "github.com/miekg/dns"
	"tailscale.com/control/controlknobs"
	"tailscale.com/health"
	"tailscale.com/net/dns"
	"tailscale.com/net/netmon"
	"tailscale.com/net/tsdial"
	"tailscale.com/types/dnstype"
	"tailscale.com/util/dnsname"
)

func TestParseBaseDNS(t *testing.T) {
	for _, input := range []string{
		``, `{}`, `null`, `{"nameservers":[]}`, `{"nameservers":["bad.example"]}`,
		`{"nameservers":["192.0.2.53"],"extra":true}`, `{"nameservers":["192.0.2.53"]} {}`,
		`{"nameservers":["127.0.0.1"]}`, `{"nameservers":["::ffff:127.0.0.1"]}`,
		`{"nameservers":["0.0.0.0"]}`, `{"nameservers":["::ffff:0.0.0.0"]}`,
		`{"nameservers":["::"]}`, `{"nameservers":["::1"]}`,
		`{"nameservers":["224.0.0.1"]}`, `{"nameservers":["ff02::1"]}`,
		`{"nameservers":["255.255.255.255"]}`, `{"nameservers":["100.100.100.100"]}`,
		`{"nameservers":["::ffff:100.100.100.100"]}`, `{"nameservers":["fd7a:115c:a1e0::53"]}`,
		`{"nameservers":["fd7a:115c:a1e0::53%wlan0"]}`, `{"nameservers":["2001:db8::53%wlan0"]}`,
		strings.Repeat(" ", 16385),
	} {
		if _, err := parseBaseDNS(input); err == nil {
			t.Errorf("parseBaseDNS(%q) accepted invalid input", input)
		}
	}
	got, err := parseBaseDNS(`{"nameservers":["192.0.2.53","::ffff:192.0.2.53","2001:db8::53","fe80::53%wlan0"]}`)
	want := []netip.Addr{netip.MustParseAddr("192.0.2.53"), netip.MustParseAddr("2001:db8::53"), netip.MustParseAddr("fe80::53%wlan0")}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("parseBaseDNS = %v, %v; want %v", got, err, want)
	}
}

func newDNSManagerForTest(t *testing.T, oscfg dns.OSConfigurator) *dns.Manager {
	t.Helper()
	dialer := tsdial.NewDialer(netmon.NewStatic())
	t.Cleanup(func() { dialer.Close() })
	manager := dns.NewManager(t.Logf, oscfg, new(health.Tracker), dialer, nil, &controlknobs.Knobs{}, "openharmony")
	t.Cleanup(func() { manager.Down() })
	return manager
}

func magicDNSConfig() dns.Config {
	return dns.Config{
		Routes:        map[dnsname.FQDN][]*dnstype.Resolver{"tail-test.ts.net.": nil},
		Hosts:         map[dnsname.FQDN][]netip.Addr{"laptop.tail-test.ts.net.": {netip.MustParseAddr("100.101.102.103")}},
		SearchDomains: []dnsname.FQDN{"tail-test.ts.net."},
	}
}

func assertMagicDNSAnswer(t *testing.T, manager *dns.Manager) {
	t.Helper()
	query := new(mdns.Msg)
	query.SetQuestion("laptop.tail-test.ts.net.", mdns.TypeA)
	wire, err := query.Pack()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	response, err := manager.Query(ctx, wire, "udp", netip.MustParseAddrPort("100.101.102.104:2000"))
	if err != nil {
		t.Fatal(err)
	}
	var reply mdns.Msg
	if err := reply.Unpack(response); err != nil {
		t.Fatal(err)
	}
	if reply.Rcode != mdns.RcodeSuccess || len(reply.Answer) != 1 {
		t.Fatalf("MagicDNS reply = %v", &reply)
	}
	answer, ok := reply.Answer[0].(*mdns.A)
	if !ok || answer.A.String() != "100.101.102.103" {
		t.Fatalf("MagicDNS answer = %v", reply.Answer)
	}
}

func assertDNSRoute(t *testing.T, manager *dns.Manager, name, want string) {
	t.Helper()
	got := manager.Resolver().GetUpstreamResolvers(dnsname.FQDN(name))
	if len(got) != 1 || got[0].Addr != want {
		t.Fatalf("upstream for %s = %v; want %s", name, got, want)
	}
}

// This reproduces the old nil-DNS tsnet configuration's compile failure, then
// proves the physical-base adapter installs a functioning MagicDNS host table.
func TestHarmonyDNSCompilesMagicDNS(t *testing.T) {
	noop, err := dns.NewNoopManager()
	if err != nil {
		t.Fatal(err)
	}
	oldManager := newDNSManagerForTest(t, noop)
	if err := oldManager.Set(magicDNSConfig()); !errors.Is(err, dns.ErrGetBaseConfigNotSupported) {
		t.Fatalf("old DNS manager.Set = %v; want unsupported base configuration", err)
	}
	adapter := newHarmonyDNSConfigurator([]netip.Addr{netip.MustParseAddr("192.0.2.53")})
	manager := newDNSManagerForTest(t, adapter)
	if err := manager.Set(magicDNSConfig()); err != nil {
		t.Fatal(err)
	}
	assertMagicDNSAnswer(t, manager)
	assertDNSRoute(t, manager, "www.example.com.", "192.0.2.53")
}

func TestHarmonyDNSPreservesSplitDNSAndRefreshesPhysicalBase(t *testing.T) {
	adapter := newHarmonyDNSConfigurator(nil)
	manager := newDNSManagerForTest(t, adapter)
	cfg := magicDNSConfig()
	cfg.Routes["corp.example."] = []*dnstype.Resolver{{Addr: "100.102.103.53"}}
	if err := manager.Set(cfg); !errors.Is(err, dns.ErrGetBaseConfigNotSupported) {
		t.Fatalf("Set before capture = %v", err)
	}
	// Recovery must reuse the last attempted config; no new netmap is required.
	for _, physicalDNS := range []string{"192.0.2.53", "198.51.100.53"} {
		adapter.replaceBase([]netip.Addr{netip.MustParseAddr(physicalDNS)})
		if err := manager.RecompileDNSConfig(); err != nil {
			t.Fatal(err)
		}
		assertMagicDNSAnswer(t, manager)
		assertDNSRoute(t, manager, "files.corp.example.", "100.102.103.53")
		assertDNSRoute(t, manager, "www.example.com.", physicalDNS)
	}
	// A tailnet-admin default resolver retains precedence over physical DNS.
	cfg.DefaultResolvers = []*dnstype.Resolver{{Addr: "203.0.113.53"}}
	if err := manager.Set(cfg); err != nil {
		t.Fatal(err)
	}
	assertMagicDNSAnswer(t, manager)
	assertDNSRoute(t, manager, "files.corp.example.", "100.102.103.53")
	assertDNSRoute(t, manager, "www.example.com.", "203.0.113.53")
}

func TestBaseDNSStagingAndAdapterIsolation(t *testing.T) {
	var backend backendController
	if got := backend.setBaseDNS(`{"nameservers":["192.0.2.53"]}`); got != "OK | DNS base staged" {
		t.Fatal(got)
	}
	if backend.server != nil {
		t.Fatal("DNS staging implicitly started backend")
	}
	backend.stop()
	if len(backend.dnsBase) != 1 || backend.dnsBase[0].String() != "192.0.2.53" {
		t.Fatal("backend stop lost physical DNS for TUN restart")
	}
	if got := backend.setBaseDNS(`{"nameservers":["private.invalid.example"]}`); got != "FAILED | DNS base | invalid resolver" {
		t.Fatalf("failure was not redacted: %q", got)
	}
	adapter := newHarmonyDNSConfigurator(backend.dnsBase)
	backend.dnsBase[0] = netip.MustParseAddr("198.51.100.53")
	base, err := adapter.GetBaseConfig()
	if err != nil || base.Nameservers[0].String() != "192.0.2.53" {
		t.Fatalf("adapter aliased staged base: %v, %v", base, err)
	}
	base.Nameservers[0] = netip.MustParseAddr("203.0.113.53")
	base, _ = adapter.GetBaseConfig()
	if base.Nameservers[0].String() != "192.0.2.53" {
		t.Fatal("returned base aliases adapter state")
	}
	if err := adapter.Close(); err != nil {
		t.Fatal(err)
	}
	adapter.replaceBase(backend.dnsBase)
	if _, err := adapter.GetBaseConfig(); err == nil {
		t.Fatal("closed adapter revived")
	}
}
