# Opt-in wired LAN bridge

[#166](https://github.com/omacom/try-omarchy-windows/issues/166) remains feature
work. NAT and existing port forwarding are the launcher default. The helpers
in `scripts/network` prepare and recover a bridge in a disposable Windows lab;
they do not add a launcher network preference or automatically install drivers.
`BridgeAccepted` remains false, including after successful host probes.

## Signed adapter path

The [current OpenVPN Windows build](https://github.com/OpenVPN/openvpn-build/blob/073cec5478841a37540cc7c824e4cc8045eb5553/windows-msi/version.m4)
references TAP-Windows6 `9.27.0-I0`, component `tap0901`. Its
[official release](https://github.com/OpenVPN/tap-windows6/releases/tag/9.27.0)
provides `dist.win10.zip`. The [package lock](../scripts/network/tap-windows6.lock.json)
pins the archive and x64 files. Use that package, not a locally built driver.

The package's driver, catalog and device utility have Valid Microsoft signatures
in native Windows checks. Installation and the running kernel service were also
checked in a disposable Windows VM. That VM has no configured Secure Boot and
no running HVCI. Compatibility with those policies enabled remains unverified.
The INF is hash-checked rather than checked for an embedded signature.

Installing the driver and creating a dedicated TAP is a separate, explicit
administrator action. The bridge helper never elevates, downloads or installs a
driver, removes a TAP, or uninstalls a shared VPN driver. Record the new device's
GUID and PNP instance before setup. Do not borrow an existing VPN device.

QEMU opens Windows TAP by its connection name. A future launcher path must
resolve the selected GUID and PNP identity to the current name immediately
before launch. Adapter rename or loss is not authority to select another device.

## Read-only preflight

Download the pinned archive from its official release, verify its archive hash
and extract it. Inspect in PowerShell:

```powershell
scripts/network/bridge-preflight.ps1 -DriverDirectory C:\BridgeLab\dist.win10\amd64
```

The output lists adapter GUIDs and blockers without changing networking. Select
an unused dedicated TAP and connected Ethernet adapter using `-WiredGuid`,
`-TapGuid`, `-DisposableLab`, `-LocalConsole` and `-DedicatedTap`. SSH/RDP sessions,
Wi-Fi, non-x64 Windows, missing/down adapters, missing DHCP/IPv4/default route,
unverified packages, occupied TAP devices, existing bridges and Hyper-V bindings
block setup. Current Windows bridge members use `ms_implat`; the composite
bridge itself uses `ms_bridge`. Inventory checks both rather than assuming an
older bridge driver identity. Unknown inventory or trust failures stop the check.

Use a disposable host or VM with an independent console. A virtual Ethernet
lab can check Windows driver installation, bridge operations and recovery. It
cannot establish physical cable behavior or acceptance on a real Ethernet NIC.
Never change bindings on a remotely accessed Wi-Fi laptop.

## Journaled lab setup

After explicit driver installation, choose a known DNS name and IPv4 TCP peer
reachable through the selected wired network. In an administrator lab console:

```powershell
scripts/network/bridge-lab.ps1 -Action Enable `
  -WiredGuid '<wired-guid>' -TapGuid '<dedicated-tap-guid>' `
  -DriverDirectory C:\BridgeLab\dist.win10\amd64 `
  -ProbeName bridge-peer.example -ProbeAddress 192.0.2.1 -ProbePort 443 `
  -DisposableLab -LocalConsole -DedicatedTap
```

The helper supports wired DHCP without manual IP addresses or persistent static
routes. It verifies the selected TAP's installed signed version, running kernel
service and exact kernel-file hash. It records GUIDs, PNP identities, bindings,
DHCP, DNS, routes and metric settings before mutation. Journals under
`%ProgramData%\TryOmarchyBridgeLab` permit only SYSTEM and Administrators, reject
untrusted owners/reparse points, use durable file replacement and serialize
helper operations with an exclusive lock.

A baseline TCP connection binds to the selected interface's DHCP address. DNS
uses that interface's configured server and must resolve the expected peer.
A separate management NIC cannot satisfy the TCP probe. Identity, driver and
configuration checks run again before creation. A failed final preflight leaves
external changes alone rather than restoring an obsolete baseline.

Windows creates the explicitly selected pair. The helper obtains the actual
bridge GUID from `netsh bridge list` and verifies exactly those members. Host
DHCP, default route, DNS and bound TCP must pass before the journal becomes
`Active`. This checks host connectivity, not guest LAN acceptance.

Disable or recover with the same safety declarations:

```powershell
scripts/network/bridge-lab.ps1 -Action Recover `
  -DisposableLab -LocalConsole -DedicatedTap
```

`Disable` uses the same recovery path. It removes only the journal's verified
bridge, restores selected adapter settings and verifies both configuration and
original host connectivity. Automatic metrics are restored separately because
an explicit metric disables them in Windows. A missing owned TAP is tolerated;
a replacement PNP identity, foreign bridge or changed membership blocks removal.
A missing wired adapter requires reconnecting it before recovery can complete.
Completed cleanup is harmless when repeated, even if the TAP has been removed.
The dedicated TAP and shared driver remain installed for separate owned-device
cleanup.

Failed creation, lost replies or failed host probes trigger scoped recovery.
An interrupted create can be recovered only from its durable intent and exact
selected membership. A timed-out Windows command leaves `RecoveryRequired`:
the network service may still finish after the caller exits, so automatic undo
must not race it. Inspect through the independent console before recovering.
Failed restoration or host probes also keep the journal pending. Do not delete
that journal or enable a new bridge over it.

## Current forwarding blocker

A disposable Windows VM with a separate management NIC can create the selected
TAP/Ethernet bridge and retain host DHCP, DNS and bound TCP connectivity. A
nested QEMU guest emits LAN DHCP requests, but those frames do not reach the
isolated virtual Ethernet peer. Delaying guest startup does not produce a lease.
The guest's separate private NAT NIC and host service remain reachable.

This result does not accept TAP-Windows6 plus the current Windows bridge path
for guest LAN traffic. Establish bidirectional forwarding with packet captures
at the guest TAP and Ethernet peer before adding a normal launcher preference.
A different Windows version or physical NIC still requires its own validation.

## Launcher integration still required

Keep the LAN NIC separate from a private NAT service NIC. Existing guest
integrations use `10.0.2.2`. Guest route configuration must prefer LAN for normal
traffic while preserving the private service route, saved port forwards,
clipboard, clock, Hello, files and approved app launching. Do not expose launcher
services on LAN to make bridging work. Persist distinct guest MACs per
installation and verify them across relaunch.

The normal setting also needs visible administrator cancellation, driver setup,
owned-device cleanup and adapter-loss handling. Never silently rebind to Wi-Fi,
a different Ethernet adapter or another TAP. Failed enable must preserve the
saved NAT/forwarding configuration and verify host recovery before offering NAT.

## Acceptance gates

- Guest LAN DHCP and direct TCP reachability from an independent LAN peer,
  alongside host DHCP/DNS/TCP before setup, while active and after cleanup.
- Failed creation, failed guest/host probes, command timeout, interruption,
  denied driver/admin setup and recovery from the durable journal.
- TAP removal, adapter rename/loss, cable unplug, host/guest restart and repeated
  enable/disable, while preserving unrelated VPN and Hyper-V state.
- Stable guest MACs, private integration channels and NAT/forwarding regression.
- Physical wired Ethernet and signed-driver checks with Secure Boot/HVCI enabled
  on supported Windows versions. A virtual lab does not replace these checks.
