package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestNetworkPreferencesDefaultAndStableIdentity(t *testing.T) {
	dir := t.TempDir()
	p, err := loadNetworkPreferences(dir)
	if err != nil || p.Mode != "nat" || p.Bridge != nil {
		t.Fatalf("%+v %v", p, err)
	}
	plan := validBridgePlan()
	p = importNetworkPlan(p, plan)
	p.Mode = "bridge-lab"
	if err = saveNetworkPreferences(dir, p); err != nil {
		t.Fatal(err)
	}
	got, err := loadNetworkPreferences(dir)
	if err != nil || !reflect.DeepEqual(got, p) {
		t.Fatalf("%+v %v", got, err)
	}
	got.Mode = "nat"
	if err = saveNetworkPreferences(dir, got); err != nil {
		t.Fatal(err)
	}
	other := plan
	other.LANMac = "52:54:00:00:00:03"
	other.PrivateMac = "52:54:00:00:00:04"
	other.TapPnp = "replacement"
	got = importNetworkPlan(got, other)
	if got.Bridge.LANMac != plan.LANMac || got.Bridge.PrivateMac != plan.PrivateMac || got.Bridge.TapPnp != "replacement" {
		t.Fatal(got)
	}
	if backupNameAllowed(networkPreferencesFilename) {
		t.Fatal("host adapter identities entered guest backups")
	}
}
func TestNetworkPreferencesRejectsDamagedAndUnsafeFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, networkPreferencesFilename)
	p := networkPreferences{1, "bridge-lab", nil}
	if saveNetworkPreferences(dir, p) == nil {
		t.Fatal("bridge without explicit plan")
	}
	p.Bridge = new(bridgePlan)
	*p.Bridge = validBridgePlan()
	data, _ := json.Marshal(p)
	for _, s := range []string{string(data) + " {}", strings.Replace(string(data), `"schemaVersion":1`, `"schemaVersion":2`, 1), strings.Replace(string(data), `"mode":"bridge-lab"`, `"mode":"automatic"`, 1), strings.Replace(string(data), `"schemaVersion":1`, `"unrecognized":1`, 1), strings.Repeat("x", 65537)} {
		os.WriteFile(path, []byte(s), 0600)
		if _, err := loadNetworkPreferences(dir); err == nil {
			t.Fatal("accepted damaged network preferences")
		}
	}
	os.WriteFile(path, append([]byte{239, 187, 191}, data...), 0600)
	if _, err := loadNetworkPreferences(dir); err != nil {
		t.Fatal(err)
	}
}
func TestBridgeGuestCapabilityGateAndBootSelection(t *testing.T) {
	var spec buildSpec
	if guestAcceptsDualNIC(spec) {
		t.Fatal("old image accepted")
	}
	spec.Runtime.NetworkCapabilities = []string{dualNICCapability}
	if !guestAcceptsDualNIC(spec) {
		t.Fatal("candidate rejected")
	}
	if bridgeGuestCmdline(nil) != "" {
		t.Fatal("NAT cmdline changed")
	}
	p := validBridgePlan()
	words := bridgeGuestCmdline(&p)
	if words != " tryomarchy.network=dual-nic-v1 tryomarchy.lan_mac="+p.LANMac+" tryomarchy.private_mac="+p.PrivateMac {
		t.Fatal(words)
	}
	dir := t.TempDir()
	if requireDualNICGuest(dir) == nil {
		t.Fatal("missing guest accepted")
	}
	data, _ := json.Marshal(spec)
	os.WriteFile(filepath.Join(dir, "build-spec.json"), data, 0600)
	if err := requireDualNICGuest(dir); err != nil {
		t.Fatal(err)
	}
	spec.Runtime.NetworkCapabilities = nil
	data, _ = json.Marshal(spec)
	os.WriteFile(filepath.Join(dir, "build-spec.json"), data, 0600)
	if requireDualNICGuest(dir) == nil {
		t.Fatal("old guest accepted")
	}
}

func TestNetworkPreferencesDoNotFollowGuestRestore(t *testing.T) {
	dir, archive := backupFixture(t)
	plan := validBridgePlan()
	prefs := networkPreferences{1, "bridge-lab", &plan}
	if err := saveNetworkPreferences(dir, prefs); err != nil {
		t.Fatal(err)
	}
	if err := writeVMBackup(dir, archive); err != nil {
		t.Fatal(err)
	}
	restored := filepath.Join(filepath.Dir(dir), "restored")
	if err := restoreVMBackup(archive, restored); err != nil {
		t.Fatal(err)
	}
	got, err := loadNetworkPreferences(restored)
	if err != nil || got.Mode != "nat" || got.Bridge != nil {
		t.Fatalf("restored host bindings: %+v %v", got, err)
	}
	got, err = loadNetworkPreferences(dir)
	if err != nil || !reflect.DeepEqual(got, prefs) {
		t.Fatal("backup changed the original network choice", got, err)
	}
}
