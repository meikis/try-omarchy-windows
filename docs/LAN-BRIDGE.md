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

Windows creates the selected pair with TAP first and Ethernet second. Wired-first
creation on the lab host reports both members but leaves the TAP bridge protocol
unattached. The helper obtains the actual bridge GUID from `netsh bridge list` and verifies exactly those members. Host
DHCP, default route, DNS and bound TCP must pass. Read-only `pktmon list --json`
must also show the NDIS bridge protocol attached to each exact member's miniport.
An enabled `ms_implat` binding alone is insufficient. Missing, ambiguous or
unavailable component inventory triggers scoped recovery before the journal can
become `Active`. Protocol attachment is a prerequisite, not guest LAN acceptance.

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

## Controlled forwarding and limits

The signed TAP-Windows6 path now forwards IP traffic in a disposable Windows 11
VM with virtual Ethernet and an independent management NIC. A fresh-device
comparison reproduced the missing protocol with wired-first creation and passed
with TAP-first creation. The native backend keeps that order and retains the
protocol-attachment guard. Binding toggles and TAP restarts did not resolve the
wired-first failure.

A nested QEMU guest with distinct LAN and private-service NICs passed:

- LAN DHCP, an explicit DNS A query and guest-to-peer TCP.
- Direct TCP from both Windows and an independent Ethernet peer to the guest's
  own LAN address, without a LAN port forward.
- IPv4 broadcast, outbound multicast and inbound multicast.
- IPv6 neighbor discovery and ICMPv6 using explicit lab addresses. IPv6 router
  advertisement, SLAAC and DHCPv6 are not yet accepted.
- Private host-service access, loopback-only forwarding and a LAN default route
  alongside the connected private service route.
- The same guest MAC, DHCP client identifier and LAN lease across relaunch.

Host DHCP, DNS and source-bound TCP passed before setup, while active and after
cleanup. Repeated setup/cleanup, exact-identity adapter rename and a forced
post-creation probe failure passed with the native helper. Virtual Ethernet
link loss retained `RecoveryRequired`; reconnecting completed recovery. Removing
the owned TAP while bridged also restored host connectivity, and repeated
cleanup passed. An actual Windows VM reboot preserved the owned bridge, its
protocol attachment and host connectivity; recovery after reboot passed. The
independent management NIC's bindings, settings, addresses and routes remained
unchanged.
PowerShell 5.1 and Core run the same preflight, transaction, attachment and
native command-order tests in CI.

This does not establish transparent Ethernet forwarding. Peer captures show
Windows rewriting the source Ethernet MAC and DHCP `chaddr` to the wired MAC,
while retaining the guest's DHCP client identifier. A raw experimental EtherType
`0x88b5` broadcast is present in the guest capture but absent at the Ethernet
peer. Both selected members report compatibility mode disabled. Resolve or
explicitly account for those limitations before offering a true LAN bridge;
do not describe this candidate as preserving the guest MAC on the wire.

The lab uses Windows build 26300, virtual Ethernet and a single guest. It does
not establish behavior on physical Ethernet, supported Windows 10 builds,
Secure Boot/HVCI, DHCP servers that rely on `chaddr`, or multiple guests. NAT
and existing LAN forwarding remain the supported launcher paths.

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
