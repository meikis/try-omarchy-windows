package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func validBridgePlan() bridgePlan {
	return bridgePlan{Version: 1, WiredGuid: "fbcf0905-41e4-498a-b086-7f7771f57184", WiredPnp: `PCI\OWNED`, TapGuid: "14349899-ada4-4135-b6ae-6acd66845ee2", TapPnp: `ROOT\NET\0000`, LANMac: "52:54:00:16:66:01", PrivateMac: "52:54:00:16:66:02", DriverDirectory: `C:\BridgeLab\driver`, ProbeName: "bridge-peer.test", ProbeAddress: "192.0.2.1", ProbePort: 8080, DisposableLab: true, LocalConsole: true, DedicatedTap: true, GuestNetworkPrepared: true}
}
func TestBridgePlanRejectsUnsafeSelection(t *testing.T) {
	cases := map[string]func(*bridgePlan){"version": func(p *bridgePlan) { p.Version = 2 }, "remote": func(p *bridgePlan) { p.LocalConsole = false }, "physical": func(p *bridgePlan) { p.DisposableLab = false }, "borrowed": func(p *bridgePlan) { p.DedicatedTap = false }, "unprepared": func(p *bridgePlan) { p.GuestNetworkPrepared = false }, "same-adapter": func(p *bridgePlan) { p.TapGuid = p.WiredGuid }, "alias": func(p *bridgePlan) { p.WiredGuid = "Ethernet" }, "missing-pnp": func(p *bridgePlan) { p.TapPnp = "" }, "multicast": func(p *bridgePlan) { p.LANMac = "53:54:00:16:66:01" }, "same-mac": func(p *bridgePlan) { p.PrivateMac = p.LANMac }, "global-mac": func(p *bridgePlan) { p.LANMac = "00:54:00:16:66:01" }, "loopback-probe": func(p *bridgePlan) { p.ProbeAddress = "127.0.0.1" }, "ipv6-probe": func(p *bridgePlan) { p.ProbeAddress = "::1" }, "port": func(p *bridgePlan) { p.ProbePort = 0 }}
	if e := validBridgePlan().validate(); e != nil {
		t.Fatal(e)
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			p := validBridgePlan()
			change(&p)
			if p.validate() == nil {
				t.Fatal("accepted unsafe plan")
			}
		})
	}
}
func TestBridgePlanFileValidation(t *testing.T) {
	p := validBridgePlan()
	data, _ := json.Marshal(p)
	path := filepath.Join(t.TempDir(), "plan.json")
	for _, bad := range []string{string(data) + " {}", strings.Replace(string(data), `"version":1`, `"unknown":1`, 1), strings.Repeat("x", 65537)} {
		os.WriteFile(path, []byte(bad), 0600)
		if _, e := loadBridgePlan(path); e == nil {
			t.Fatal("accepted invalid file")
		}
	}
	os.WriteFile(path, append([]byte{239, 187, 191}, data...), 0600)
	got, e := loadBridgePlan(path)
	if e != nil || !reflect.DeepEqual(*got, p) {
		t.Fatalf("BOM plan: %v %v", got, e)
	}
}
func TestBridgeKeepsPrivateServicesAndForwards(t *testing.T) {
	var forwards forwardList
	if e := forwards.Set("tcp:18092:8082"); e != nil {
		t.Fatal(e)
	}
	nat := bridgeNetworkArgs(nil, "", forwards)
	want := []string{"-device", "virtio-net-pci,netdev=n0", "-netdev", netdevArg(forwards)}
	if !reflect.DeepEqual(nat, want) {
		t.Fatal(nat)
	}
	p := validBridgePlan()
	args := bridgeNetworkArgs(&p, "Owned, TAP", forwards)
	if args[1] != "virtio-net-pci,netdev=lan0,mac="+p.LANMac || args[3] != "tap,id=lan0,ifname=Owned,, TAP" || args[5] != "virtio-net-pci,netdev=n0,mac="+p.PrivateMac || args[7] != nat[3] {
		t.Fatal(args)
	}
	if !strings.Contains(args[7], "hostfwd=tcp:127.0.0.1:18092-:8082") {
		t.Fatal("forward escaped private NAT", args)
	}
}
