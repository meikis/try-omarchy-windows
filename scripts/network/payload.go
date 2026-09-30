// Package networkpayload embeds the reviewed bridge code into the launcher.
// Elevated execution never imports scripts from the user's installation.
package networkpayload

import "embed"

//go:embed NpcapFramePump.cs OwnedBridgeInput.cs HostTcpSegmentation.cs bridge-native.psm1 bridge-preflight.psm1 bridge-datapath.psm1 bridge-transaction.psm1 tap-windows6.lock.json npcap-1.89.lock.json launcher-bridge.ps1 launcher-bridge-transaction.psm1
var Files embed.FS
