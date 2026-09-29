# Opt-in wired LAN bridge

[#166](https://github.com/omacom/try-omarchy-windows/issues/166) remains
implementation work. NAT and existing port forwarding are the default. The
read-only preflight below does not install a driver, create a bridge, change
bindings or select networking for the launcher.

## Driver and runtime path

Evaluate OpenVPN's signed TAP-Windows6 x64 package, not a locally built driver.
The [current OpenVPN Windows build](https://github.com/OpenVPN/openvpn-build/blob/073cec5478841a37540cc7c824e4cc8045eb5553/windows-msi/version.m4)
still references `9.27.0-I0` and component `tap0901`. The
[official release](https://github.com/OpenVPN/tap-windows6/releases/tag/9.27.0)
provides `dist.win10.zip`; the repository's
[package lock](../scripts/network/tap-windows6.lock.json) pins the archive and
x64 files. The release is from March 2024. Its age alone does not establish
compatibility with current Windows security settings.

Windows `Get-AuthenticodeSignature` returned `Valid` for the pinned x64
`tap0901.sys`, `tap0901.cat` and `devcon.exe`. The driver and catalog identify
Microsoft Windows Hardware Compatibility Publisher. The INF is checked by
hash, not by an embedded signature. Kernel-policy/catalog membership verification
and installation under the lab's actual Secure Boot/HVCI settings remain
required. Downloading and checking signatures does not prove installation.

The published Windows QEMU advertises the TAP backend. Its Windows backend
opens an adapter by its connection name. Resolve the explicitly selected GUID
to its current name immediately before launch; never select a VPN adapter by
its display label alone. Adapter-open failure must abort this attempt without
changing host networking. Hot detach and `set_link` behavior need runtime
validation before being used for recovery.

Windows 10/11's [netsh bridge interface](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-bridge)
provides create, list and destroy operations. Presence of those commands does
not prove successful binding, DHCP or cleanup on a particular host.

## Read-only preflight

Manually download the pinned archive from its official release, verify the
archive SHA-256 in the lock and extract it into a lab directory. Do not run
`devcon.exe` or any installer. In PowerShell:

```powershell
scripts/network/bridge-preflight.ps1 -DriverDirectory C:\BridgeLab\dist.win10\amd64
```

The result lists adapter GUIDs and blockers. Once a disposable wired host has
local console access and an explicitly approved, dedicated TAP device, assess
the selected pair with `-WiredGuid`, `-TapGuid`, `-DisposableLab`, `-LocalConsole`
and `-DedicatedTap`. Non-x64 hosts, remote SSH/RDP, nonphysical Ethernet, Wi-Fi, Bluetooth,
missing/down adapters, missing DHCP/IPv4/default-route baseline, existing
bridges, occupied TAP devices and Hyper-V/bridge bindings block the lab path.
Unknown inventory or trust errors stop inspection rather than report success.
`CanStartDisposableLab` only describes preflight; `BridgeAccepted` stays false.
Re-run the inventory immediately before any future mutation.

The available physical test host has active Wi-Fi, disconnected wired Ethernet
and no TAP device. It is remotely accessed and contains preserved installations.
No disposable Windows host with connected Ethernet and independent console
recovery is currently available. The devbox has KVM, but no disposable Windows
image or dedicated lab uplink is provisioned there. The existing Windows VM
is preserved user state and is not a disposable networking fixture.

## Setup and recovery contract

Implement and test this transaction in that lab before adding a normal setting:

1. Require explicit user selection and administrator approval. Installing a
   signed driver is a separate visible action. Create a dedicated TAP device;
   never borrow an adapter used by another VPN or remove a shared driver.
2. Persist an operation journal before mutation: selected GUIDs/PNP instance,
   original bindings, IPv4/IPv6/DHCP/DNS configuration, routes, existing bridges
   and the known host connectivity probe. Keep stable, distinct guest MACs per
   installation. Restrict the first implementation to wired DHCP.
3. Create only the selected bridge. Record its actual GUID and membership from
   the resulting inventory, including partial failure. Never destroy an
   unrelated bridge or use global adapter-removal commands during rollback.
4. Verify the host still has its DHCP lease, DNS and default route and can
   complete the original TCP/DNS probes. If setup or those probes fail, undo
   only this operation, restore the recorded settings and verify host recovery
   before offering the unchanged NAT path. An interrupted helper must recover
   from the journal without repeating already completed mutations.
5. Keep host integration private. Current guest services use `10.0.2.2` through
   QEMU user networking. A LAN NIC needs a separate private NAT service NIC,
   guest route configuration that keeps the LAN as the intended default and
   regression checks for clipboard, clock, Hello, files and approved apps.
   Do not expose launcher services on the LAN to make bridging work. Existing
   port forwards keep their saved configuration and documented scope.
6. On adapter loss or rename, stop using the stale device and report the
   failure. Do not rebind to Wi-Fi, another adapter or an unrelated TAP device.
   Verify guest/host recovery, restart and NAT selection in the lab. On disable
   or uninstall, remove only the owned bridge/TAP instance, restore bindings and
   verify host connectivity. Repeated cleanup must be harmless; an absent
   owned device is not authority to remove another device or shared driver.

## Acceptance still required

- Host connectivity before, during and after setup; guest LAN DHCP and direct
  reachability from a second LAN machine; a stable guest MAC across relaunch.
- Administrator cancellation, denied/invalid driver, failed bridge creation,
  failed DHCP/DNS/TCP probes, helper interruption and journal recovery.
- Cable unplug, TAP removal, adapter rename, host/guest restart and repeated
  enable/disable/cleanup, with preserved unrelated VPN and Hyper-V state.
- NAT/forwarding regression checks and all private host integration channels.

Preflight fixture tests and signature checks cover independently verifiable
parts. Bridge creation, live host recovery and LAN acceptance remain untested
until the disposable wired environment exists.
