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

QEMU opens Windows TAP by its connection name. The experimental launcher path
resolves the selected GUID and PNP identity to the current name before launch.
Adapter rename or loss is not authority to select another device.

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

## Npcap forwarding experiment

The native Windows bridge's MAC translation and raw EtherType limit are separate
from the TAP attachment failure. A disposable lab now also has a user-mode
forwarding path using manually installed [Npcap 1.89](https://npcap.com/).
Its running driver has a valid Microsoft signature. The
[pinned installed files](../scripts/network/npcap-1.89.lock.json) include the
kernel driver and signed Nmap DLLs. The helper verifies those files and the
running service before loading from the system Npcap directory.

Npcap is a separate dependency. Its [license](https://npcap.com/guide/#npcap-license)
allows limited end-user installations and prohibits redistribution without
permission. No installer, driver or DLL is bundled here. The helper never
downloads, installs, upgrades or silently configures Npcap. This experiment
does not establish a redistribution or product licensing decision.

The dedicated TAP must have a saved binding baseline and IPv4/IPv6 already
unbound by an explicit administrator lab action. Start a diskless QEMU fixture
with that TAP, a fixed guest MAC and a separate private NAT service NIC. Keep
an independent management adapter and local console available. Do not create a
native Windows bridge at the same time. Then use a fresh administrator
PowerShell process:

```powershell
powershell.exe -NoProfile -File scripts/network/npcap-lab.ps1 `
  -WiredGuid '<wired-guid>' -WiredPnp '<wired-pnp>' `
  -TapGuid '<owned-tap-guid>' -TapPnp '<owned-tap-pnp>' `
  -GuestMac '52:54:00:16:66:01' `
  -DriverDirectory C:\BridgeLab\dist.win10\amd64 `
  -QemuProcessId <fixture-pid> -QemuExecutable C:\BridgeLab\qemu-system-x86_64w.exe `
  -ProbeName bridge-peer.example -ProbeAddress 192.0.2.1 -ProbePort 443 `
  -Seconds 60 -DisposableLab -LocalConsole -DedicatedTap
```

Require Npcap's administrator-only option, without wireless capture or WinPcap
compatibility. Exact GUID/PNP, wired DHCP/DNS/TCP, pinned TAP driver, running
QEMU, its selected TAP and guest MAC, existing-bridge restrictions and binding
checks gate startup. A per-TAP mutex rejects another helper. Link loss,
identity/binding changes or QEMU exit stop forwarding. The duration is bounded
to 600 seconds. Native handles close after workers stop; an unresponsive worker
terminates the lab process instead of closing a handle under it. Process exit
releases capture handles. This helper changes no bindings, DHCP, DNS, routes,
firewall or offload settings, and has no automatic adapter or NAT fallback.
After it exits, stop the owned fixture and restore the saved dedicated-TAP
bindings or remove that exact owned device. Do not uninstall a shared driver.

The pump forwards only the fixed guest's source frames and peer frames addressed
to that guest or to broadcast/multicast. It preserves Ethernet MACs. Per-handle
receive injection delivers guest frames to Windows without a system-wide
Npcap registry change. Windows host captures can contain unfinished hardware
checksums. The pump completes IPv4, TCP, UDP and ICMP checksums on captured host
frames before sending them through TAP. Peer and guest raw Ethernet payloads
are not rewritten. Packet tests include a captured pre-offload SYN and its
hardware-completed wire vector, IPv4/IPv6 UDP, VLAN preservation, malformed
frames and startup arguments. Both PowerShell dialects run these checks in CI.

Captured host TCP frames larger than 1500 IP bytes are split into complete
Ethernet frames. The pump observes the guest SYN or SYN-ACK receive MSS and
accounts for IP/TCP options and IPv6 extensions. Each segment stays within the
advertised receive limit and the standard Ethernet MTU. Sequence numbers,
lengths, checksums and IP IDs are regenerated; FIN/PSH stay on the last segment
and CWR on the first. VLAN bytes and TCP options are preserved. LSOv2 zero-length
headers and captures above 64 KiB have packet-vector coverage. The pcap API
does not expose the NDIS offload MSS, so missing or expired handshakes stop the
helper with a reconnect message. Tracking is bounded to 4096 connections and
expires after ten inactive minutes. Authenticated TCP segmentation is rejected.
See [Microsoft's LSO contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/offloading-the-segmentation-of-large-tcp-packets)
and [RFC 6691](https://www.rfc-editor.org/rfc/rfc6691.html).

The native helper passed unchanged guest Ethernet MAC and DHCP `chaddr`, a
bidirectional experimental EtherType `0x88b5` exchange, LAN DHCP/DNS/TCP, direct
Windows and peer TCP, IPv4 broadcast/multicast, explicit-address IPv6 ping and
private services. Exact-GUID adapter rename preserved forwarding. Virtual
Ethernet loss stopped the helper and retained independent management access;
reconnection and a fresh helper run recovered forwarding. These are controlled
virtual-Ethernet results.

The prior helper timed out on a 13,194-byte captured Windows TCP frame. The
segmentation candidate passes 1 MiB and 2 MiB direct Windows-to-guest round trips
over IPv4 and IPv6 with matching payload hashes. The virtual adapter reports
LSO disabled; these results do not prove a physical NIC's hardware LSO path.

This is a bounded single-guest lab helper, not the launcher bridge feature.
Hardware-specific offload behavior, fragmented host traffic, IPv6 routing/fragment/IPsec
headers, throughput, VLAN wire behavior, sleep and broader adapter/version
coverage remain unaccepted. Unsupported captured host packets stop the helper
rather than changing the NIC's offload configuration. Physical wired Ethernet,
Secure Boot/HVCI, Windows 10, administrator cancellation and normal guest
integration still need validation. `BridgeAccepted` remains false. NAT and
existing forwarding remain the launcher defaults.

## Normal guest and Settings work

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

## Experimental launcher ownership

The launcher can now own the Npcap helper in an explicitly declared disposable
Windows lab. This is a development option, not a supported network preference.
It requires the separately installed, pinned TAP and Npcap dependencies, an
unused dedicated TAP, wired DHCP and an independent local recovery console.
Driver installation remains manual. Npcap binaries are not bundled.

Save an installation-local JSON plan with `version: 1`, the exact `wiredGuid`,
`wiredPnp`, `tapGuid` and `tapPnp`, distinct locally administered `lanMac` and
`privateMac`, `driverDirectory`, `probeName`, `probeAddress` and `probePort`.
Retain the MACs and plan across boots. Set `disposableLab`, `localConsole`,
`dedicatedTap` and `guestNetworkPrepared` only after satisfying those conditions.
The guest must already configure both NICs by MAC: LAN DHCP provides the default
route and DNS; the private NIC keeps its connected `10.0.2.0/24` route without a
private default route or private DNS. Ordinary released guests have not been
accepted with this routing configuration.

Start only that candidate installation:

```powershell
TryOmarchy.exe -start -dir C:\BridgeCandidate -bridge-lab-plan C:\BridgeCandidate\bridge.json
```

A separate launcher broker requests Windows permission. It executes the helper
embedded in the candidate binary, extracted under administrator/SYSTEM-only
permissions, rather than loading elevated code from the installation or plan.
The broker does not elevate QEMU. Its authenticated loopback connection checks
the parent process and completes a handshake before preparation. Cancelling
permission leaves the VM stopped and does not prepare the TAP.

Preparation changes the exact dedicated TAP's IPv4/IPv6 and dependent Microsoft
client, server and NetBIOS bindings. Windows can change these dependencies when
[IP bindings change](https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapterbinding?view=windowsserver2025-ps). Recovery verifies the complete saved binding inventory. The wired
adapter's bindings, addressing and offload settings are not changed. A protected,
durable journal records the original TAP bindings before changes. Capture opens
before QEMU starts. QEMU gets the selected TAP's current connection name and a
separate private NAT NIC with the existing forwards. The broker verifies QEMU's
PID, creation time, executable and selected dual-network command line. Another
launcher operation or lab frame pump cannot take the same TAP.

The helper has no periodic lab-duration restart. Explicit stop, parent connection
loss and QEMU exit release capture handles and recover owned TAP bindings.
Adapter loss, changed identity/bindings or packet failure stops forwarding.
The launcher stops that lab VM rather than silently switching networks. Failed
cleanup or failed host connectivity keeps `RecoveryRequired` and blocks another
start. Recover through the independent console after reconnecting the selected
wired adapter:

```powershell
TryOmarchy.exe -bridge-lab-plan C:\BridgeCandidate\bridge.json -bridge-lab-recover
```

Recovery does not need Npcap running, destroy a Windows bridge, remove a device,
uninstall a shared driver or select another adapter. It tolerates removal of the
owned TAP and refuses replacement identities or unrelated TAP binding edits.

In the disposable Windows VM, launcher-owned forwarding passes guest DHCP/DNS,
direct host TCP, private host services and loopback forwarding. Direct TCP
payloads of 1 byte, 1 MiB and 2 MiB return unchanged. Duplicate setup is refused;
explicit stop, repeated cleanup, QEMU exit and actual parent-process exit recover
the TAP. Virtual Ethernet loss stops capture and retains recovery until the
selected adapter reconnects. A replacement PNP identity is refused before setup.
These checks use a prepared diskless fixture, not the ordinary released guest.

NAT, port forwarding and the normal launcher menu remain the release defaults.
Physical Ethernet, Windows 10, hardware offload, Secure Boot/HVCI, IPv6 address
configuration, guest migration and a supported Settings preference remain
acceptance work. This option must not be used on a remotely accessed Wi-Fi host.
