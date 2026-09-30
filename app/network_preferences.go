package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Host adapter identities must not travel in a guest backup or portable copy.
// Keep this outside settings.json so older launchers can roll back safely.
const networkPreferencesFilename = "network-preferences.json"
const dualNICCapability = "dual-nic-v1"

type networkPreferences struct {
	SchemaVersion int         `json:"schemaVersion"`
	Mode          string      `json:"mode"`
	Bridge        *bridgePlan `json:"bridge,omitempty"`
}

func (p networkPreferences) validate() error {
	if p.SchemaVersion != 1 || (p.Mode != "nat" && p.Mode != "bridge-lab") {
		return fmt.Errorf("unsupported network preference")
	}
	if p.Mode == "bridge-lab" && p.Bridge == nil {
		return fmt.Errorf("choose an explicit bridge lab plan first")
	}
	if p.Bridge != nil {
		return p.Bridge.validate()
	}
	return nil
}
func loadNetworkPreferences(dir string) (networkPreferences, error) {
	defaults := networkPreferences{SchemaVersion: 1, Mode: "nat"}
	f, err := os.Open(filepath.Join(dir, networkPreferencesFilename))
	if os.IsNotExist(err) {
		return defaults, nil
	}
	if err != nil {
		return defaults, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 65537))
	if err != nil {
		return defaults, err
	}
	if len(data) > 65536 {
		return defaults, fmt.Errorf("network preferences are too large")
	}
	d := json.NewDecoder(bytes.NewReader(bytes.TrimPrefix(data, []byte{239, 187, 191})))
	d.DisallowUnknownFields()
	var p networkPreferences
	if err = d.Decode(&p); err != nil {
		return defaults, err
	}
	if d.Decode(&struct{}{}) != io.EOF {
		return defaults, fmt.Errorf("network preferences contain trailing data")
	}
	return p, p.validate()
}
func saveNetworkPreferences(dir string, p networkPreferences) error {
	if err := p.validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	if err = os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".network-preferences-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(append(data, '\n')); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), filepath.Join(dir, networkPreferencesFilename))
}
func guestAcceptsDualNIC(spec buildSpec) bool {
	return slices.Contains(spec.Runtime.NetworkCapabilities, dualNICCapability)
}
func bridgeGuestCmdline(p *bridgePlan) string {
	if p == nil {
		return ""
	}
	return " tryomarchy.network=" + dualNICCapability + " tryomarchy.lan_mac=" + strings.ToLower(p.LANMac) + " tryomarchy.private_mac=" + strings.ToLower(p.PrivateMac)
}
func requireDualNICGuest(guestDir string) error {
	data, err := os.ReadFile(filepath.Join(guestDir, "build-spec.json"))
	if err != nil {
		return fmt.Errorf("install a guest image with dual-NIC support before enabling the bridge: %w", err)
	}
	var spec buildSpec
	if err = json.Unmarshal(data, &spec); err != nil {
		return err
	}
	if !guestAcceptsDualNIC(spec) {
		return fmt.Errorf("this guest image does not support automatic dual-NIC routing; install a compatible candidate first")
	}
	return nil
}

// Imported plans may change adapter selection, but not this installation's
// existing DHCP identities. NAT retains them for the next explicit opt-in.
func importNetworkPlan(current networkPreferences, plan bridgePlan) networkPreferences {
	if current.Bridge != nil {
		plan.LANMac = current.Bridge.LANMac
		plan.PrivateMac = current.Bridge.PrivateMac
	}
	current.Bridge = &plan
	return current
}
