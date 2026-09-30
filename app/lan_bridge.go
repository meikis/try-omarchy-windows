package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strings"
)

// bridgePlan is an explicit, installation-local lab opt-in. It is not inferred
// from an alias, current default route, or an installed VPN's TAP.
type bridgePlan struct {
	Version              int    `json:"version"`
	WiredGuid            string `json:"wiredGuid"`
	WiredPnp             string `json:"wiredPnp"`
	TapGuid              string `json:"tapGuid"`
	TapPnp               string `json:"tapPnp"`
	LANMac               string `json:"lanMac"`
	PrivateMac           string `json:"privateMac"`
	DriverDirectory      string `json:"driverDirectory"`
	ProbeName            string `json:"probeName"`
	ProbeAddress         string `json:"probeAddress"`
	ProbePort            int    `json:"probePort"`
	DisposableLab        bool   `json:"disposableLab"`
	LocalConsole         bool   `json:"localConsole"`
	DedicatedTap         bool   `json:"dedicatedTap"`
	GuestNetworkPrepared bool   `json:"guestNetworkPrepared"`
}

var bridgeGUID = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (p bridgePlan) validate() error {
	if p.Version != 1 || !p.DisposableLab || !p.LocalConsole || !p.DedicatedTap || !p.GuestNetworkPrepared {
		return fmt.Errorf("bridge requires an explicit disposable wired lab, local console, dedicated TAP and prepared guest routes")
	}
	if !bridgeGUID.MatchString(p.WiredGuid) || !bridgeGUID.MatchString(p.TapGuid) || strings.EqualFold(p.WiredGuid, p.TapGuid) {
		return fmt.Errorf("select distinct exact wired and TAP GUIDs")
	}
	for _, v := range []string{p.WiredPnp, p.TapPnp, p.DriverDirectory, p.ProbeName} {
		if v == "" || len(v) > 1024 || strings.ContainsAny(v, "\x00\r\n") {
			return fmt.Errorf("bridge identity or probe is invalid")
		}
	}
	for _, v := range []string{p.LANMac, p.PrivateMac} {
		mac, e := net.ParseMAC(v)
		if e != nil || len(mac) != 6 || len(v) != 17 || !strings.Contains(v, ":") || mac[0]&3 != 2 {
			return fmt.Errorf("bridge MACs must be locally administered unicast Ethernet addresses")
		}
	}
	if strings.EqualFold(p.LANMac, p.PrivateMac) {
		return fmt.Errorf("LAN and private MACs must differ")
	}
	ip := net.ParseIP(p.ProbeAddress)
	if ip == nil || ip.To4() == nil || !ip.IsGlobalUnicast() || ip.IsLoopback() || p.ProbePort < 1 || p.ProbePort > 65535 {
		return fmt.Errorf("bridge requires a separate IPv4 wired TCP probe")
	}
	return nil
}
func loadBridgePlan(path string) (*bridgePlan, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	data, e := io.ReadAll(io.LimitReader(f, 65537))
	if e != nil {
		return nil, e
	}
	if len(data) > 65536 {
		return nil, fmt.Errorf("bridge plan is too large")
	}
	d := json.NewDecoder(bytes.NewReader(bytes.TrimPrefix(data, []byte{239, 187, 191})))
	d.DisallowUnknownFields()
	var p bridgePlan
	if e = d.Decode(&p); e != nil {
		return nil, e
	}
	if e = d.Decode(&struct{}{}); e != io.EOF {
		return nil, fmt.Errorf("bridge plan has trailing data")
	}
	if e = p.validate(); e != nil {
		return nil, e
	}
	return &p, nil
}
func bridgeNetworkArgs(p *bridgePlan, name string, forwards []portForward) []string {
	if p == nil {
		return []string{"-device", "virtio-net-pci,netdev=n0", "-netdev", netdevArg(forwards)}
	}
	// Place LAN first, but keep the private service network and every existing
	// forward. The prepared guest disables private default routes and DNS.
	return []string{"-device", "virtio-net-pci,netdev=lan0,mac=" + strings.ToLower(p.LANMac), "-netdev", "tap,id=lan0,ifname=" + qemuOptionValue(name), "-device", "virtio-net-pci,netdev=n0,mac=" + strings.ToLower(p.PrivateMac), "-netdev", netdevArg(forwards)}
}
