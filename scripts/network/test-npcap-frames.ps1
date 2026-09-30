# Pure packet and argument checks. Never opens a device or touches a session.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -Path (Join-Path $PSScriptRoot 'NpcapFramePump.cs')
$script:checks = 0
function Bytes([string]$Hex) {
    [byte[]]$data = New-Object byte[] ($Hex.Length / 2)
    for ($i=0; $i -lt $data.Length; $i++) { $data[$i] = [Convert]::ToByte($Hex.Substring($i*2,2),16) }
    return ,$data
}
function Hex([byte[]]$Data) { ([BitConverter]::ToString($Data)).Replace('-','').ToLowerInvariant() }
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }; $script:checks++
}
function Reject([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
foreach ($path in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($path.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) ('PowerShell parse errors: '+$path.Name)
}
# Windows pre-offload SYN and the corresponding hardware-completed wire frame.
$inputHex = '5254001666015254001660010800450000341ef2400080060000c000021ac000021bfb971f920295173a000000008002ffff845c0000020405b40103030801010402'
$wireHex = '5254001666015254001660010800450000341ef240008006579cc000021ac000021bfb971f920295173a000000008002ffffb5e10000020405b40103030801010402'
$frame = Bytes $inputHex
[NpcapFramePump]::CompleteHostChecksums($frame)
Assert ((Hex $frame) -eq $wireHex) 'Captured host SYN did not match the hardware wire checksums'
[NpcapFramePump]::CompleteHostChecksums($frame)
Assert ((Hex $frame) -eq $wireHex) 'Valid host SYN changed on a second pass'
foreach ($tag in @('81000001','88a8002381000011')) {
    $tagged = Bytes ($inputHex.Substring(0,24)+$tag+$inputHex.Substring(24))
    [NpcapFramePump]::CompleteHostChecksums($tagged)
    Assert ((Hex $tagged) -eq ($wireHex.Substring(0,24)+$tag+$wireHex.Substring(24))) 'VLAN bytes or checksums changed incorrectly'
}
foreach ($etherType in @('88b5','0806','88cc')) {
    $raw = Bytes ('ffffffffffff525400166601'+$etherType+'4269646972656374696f6e616c45746865726e6574')
    $original = Hex $raw
    [NpcapFramePump]::CompleteHostChecksums($raw)
    Assert ((Hex $raw) -eq $original) 'Non-IP Ethernet payload was modified'
}
# Independently calculated IPv4 UDP odd-payload vector.
$udp = Bytes 'ffffffffffff52540016600108004500001f1234000040110000c000021ac000021b30390035000b0000616263'
[NpcapFramePump]::CompleteHostChecksums($udp)
Assert ((Hex $udp) -eq 'ffffffffffff52540016600108004500001f123400004011e464c000021ac000021b30390035000b86d1616263') 'IPv4 UDP checksum vector mismatch'
# IPv6 UDP with a three-byte payload and hop-by-hop extension.
$udp6 = Bytes '33330000000152540016600186dd6000000000130040fd000166000000000000000000000026fd000166000000000000000000000027110000000000000030390035000b0000616263'
[NpcapFramePump]::CompleteHostChecksums($udp6)
Assert ((Hex $udp6).EndsWith('30390035000b0ded616263')) 'IPv6 extension UDP checksum vector mismatch'
foreach ($mutate in @(
    {param($f) $f[14]=0x44},
    {param($f) $f[16]=0; $f[17]=0},
    {param($f) $f[16]=0xff; $f[17]=0xff},
    {param($f) $f[20]=0x20},
    {param($f) $f[46]=0x10}
)) {
    $bad = Bytes $inputHex
    & $mutate $bad
    Reject { [NpcapFramePump]::CompleteHostChecksums($bad) } 'Unsupported host packet was accepted'
}
Reject { [NpcapFramePump]::CompleteHostChecksums((New-Object byte[] 13)) } 'Short Ethernet header accepted'
Reject { [NpcapFramePump]::CompleteHostChecksums((Bytes 'ffffffffffff5254001660018100')) } 'Truncated VLAN accepted'
foreach ($mac in @('00:00:00:00:00:00','ff:ff:ff:ff:ff:ff','01:00:00:00:00:01','52:54:00:16:66','52:54:00:16:66:gg','5:54:00:16:66:01')) {
    Reject { [NpcapFramePump]::ParseMac($mac) } ('Invalid MAC accepted: '+$mac)
}
Assert ((Hex ([NpcapFramePump]::ParseMac('52:54:00:16:66:01'))) -eq '525400166601') 'Fixed unicast MAC rejected'
function RejectMessage([scriptblock]$Action,[string]$Expected) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.ToString() }
    Assert ($message.Contains($Expected)) ('Expected rejection: '+$Expected)
}
$wired='00000000-0000-0000-0000-000000000001'
$tap='00000000-0000-0000-0000-000000000002'
$script:guardCalled = $false
$never = [Action]{ $script:guardCalled=$true; throw 'Unexpected guard call' }
RejectMessage { [NpcapFramePump]::Run($wired,$tap,'52:54:00:16:66:01','52:54:00:16:60:01',0,$never) } 'Duration must be'
RejectMessage { [NpcapFramePump]::Run($wired,$tap,'52:54:00:16:66:01','52:54:00:16:60:01',601,$never) } 'Duration must be'
RejectMessage { [NpcapFramePump]::Run($wired,$wired,'52:54:00:16:66:01','52:54:00:16:60:01',1,$never) } 'distinct adapters'
RejectMessage { [NpcapFramePump]::Run($wired,$tap,'52:54:00:16:66:01','52:54:00:16:66:01',1,$never) } 'MACs must differ'
Assert (-not $script:guardCalled) 'Invalid arguments reached the device guard'
RejectMessage { [NpcapFramePump]::Run($wired,$tap,'52:54:00:16:66:01','52:54:00:16:60:01',1,[Action]{throw 'Adapter absent'}) } 'Adapter absent'
"$script:checks Npcap frame checks passed"
