# Pure offload vectors. No native DLL/device, session or NIC changes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not ('NpcapFramePump' -as [type])) {
    Add-Type -Path @((Join-Path $PSScriptRoot 'NpcapFramePump.cs'),(Join-Path $PSScriptRoot 'HostTcpSegmentation.cs'))
}
$script:checks = 0
function Assert([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }; $script:checks++
}
function Reject([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Assert $failed $Message
}
function Bytes([string]$Hex) {
    [byte[]]$b=New-Object byte[] ($Hex.Length/2)
    for($i=0;$i -lt $b.Length;$i++){$b[$i]=[Convert]::ToByte($Hex.Substring($i*2,2),16)}
    return ,$b
}
function Hash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
# Hashes independently generated with Python struct/hashlib and RFC checksums.
# Covers stacked VLANs, IPv4/TCP options, IPv6 hop-by-hop, 32-bit sequence wrap,
# 16-bit and LSOv2 15-bit IP ID wrap, CWR first and FIN/PSH last, >64K captures.
$vectors=Get-Content (Join-Path $PSScriptRoot 'tcp-segmentation-vectors.json') -Raw | ConvertFrom-Json
foreach($v in $vectors) {
    $syn=Bytes $v.GuestSyn
    [byte[]]$hostFrame=(Bytes $v.HostHeader)+(New-Object byte[] $v.PayloadLength)
    $header=$hostFrame.Length-$v.PayloadLength
    for($i=0;$i -lt $v.PayloadLength;$i++){$hostFrame[$header+$i]=[byte]($i%251)}
    $original=Hash $hostFrame
    $tcp=[HostTcpSegmentation]::new()
    Reject { $tcp.NormalizeHost($hostFrame) } ('Missing handshake accepted: '+$v.Name)
    $tcp.ObserveGuest($syn)
    $result=$tcp.NormalizeHost($hostFrame)
    Assert ($result.Length -eq $v.SegmentHashes.Count) ('Segment count: '+$v.Name)
    for($i=0;$i -lt $result.Length;$i++) {
        Assert ((Hash $result[$i]) -eq $v.SegmentHashes[$i]) ('Segment bytes/checksums: '+$v.Name+'/'+$i)
        Assert ($result[$i].Length -le 1522) ('Oversized segment: '+$v.Name)
    }
    Assert ((Hash $hostFrame) -eq $original) 'Input changed during normalization'
    $again=$tcp.NormalizeHost($hostFrame)
    Assert ((Hash $again[0]) -eq $v.SegmentHashes[0]) 'Retransmission changed'
    $wrong=(Bytes $v.GuestSyn); $wrong[$wrong.Length-24]=0x2f
    $other=[HostTcpSegmentation]::new(); $other.ObserveGuest($wrong)
    Reject { $other.NormalizeHost($hostFrame) } 'Another TCP tuple authorized segmentation'
}
$v=$vectors[0]
$syn=Bytes $v.GuestSyn
[byte[]]$hostFrame=(Bytes $v.HostHeader)+(New-Object byte[] $v.PayloadLength)
$script:tick=[long]0
$timed=[HostTcpSegmentation]::new([Func[long]]{return $script:tick})
$timed.ObserveGuest($syn)
$script:tick=600000
Reject { $timed.NormalizeHost($hostFrame) } 'Expired handshake authorized segmentation'
$timed.ObserveGuest($syn)
$rst=Bytes $v.GuestSyn; $rst[$rst.Length-11]=4
$timed.ObserveGuest($rst)
Reject { $timed.NormalizeHost($hostFrame) } 'Reset connection retained receive MSS'
foreach($flags in @(2,4,32)) {
    $bad=[byte[]]$hostFrame.Clone(); $bad[59]=$flags
    $tcp=[HostTcpSegmentation]::new(); $tcp.ObserveGuest($syn)
    Reject { $tcp.NormalizeHost($bad) } 'Invalid host LSO flags accepted'
}
foreach($option in @(19,29)) {
    $bad=[byte[]]$hostFrame.Clone(); $bad[66]=$option; $bad[67]=10
    $tcp=[HostTcpSegmentation]::new(); $tcp.ObserveGuest($syn)
    Reject { $tcp.NormalizeHost($bad) } 'Authenticated TCP segmentation accepted'
}
$bad=Bytes $v.GuestSyn; $bad[$bad.Length-3]=1
Reject { ([HostTcpSegmentation]::new()).ObserveGuest($bad) } 'Malformed guest MSS accepted'
$bad=Bytes $v.GuestSyn; $bad[$bad.Length-2]=0; $bad[$bad.Length-1]=0
Reject { ([HostTcpSegmentation]::new()).ObserveGuest($bad) } 'Zero guest MSS accepted'
foreach($kind in @(131,137)) {
    $bad=[byte[]]$hostFrame.Clone(); $bad[42]=$kind; $bad[43]=4
    Reject { ([HostTcpSegmentation]::new()).NormalizeHost($bad) } 'IPv4 source routing accepted'
}
$shortTotal=[byte[]]$hostFrame.Clone(); $shortTotal[24]=0; $shortTotal[25]=56
Reject { ([HostTcpSegmentation]::new()).NormalizeHost($shortTotal) } 'Unrecognized trailing host payload was injected'
foreach($kind in @(0xc2,0xc9)) {
    $bad=[byte[]]((Bytes $vectors[2].HostHeader)+(New-Object byte[] $vectors[2].PayloadLength))
    $bad[64]=$kind; $bad[65]=4
    Reject { ([HostTcpSegmentation]::new()).NormalizeHost($bad) } 'IPv6 jumbo/home-address option accepted'
}
# Default MSS when absent, connection separation by VLAN, bounded flow storage,
# and active-connection refresh are separate from the static packet vectors.
$plain=Bytes $v.GuestSyn; $plain[$plain.Length-4]=0
$tcp=[HostTcpSegmentation]::new();$tcp.ObserveGuest($plain)
$segments=$tcp.NormalizeHost($hostFrame)
Assert ($segments[0].Length -eq 22+24+32+520) 'IPv4 default MSS or option allowance incorrect'
$otherVlan=Bytes $v.GuestSyn; $otherVlan[19]=0x12
$tcp=[HostTcpSegmentation]::new();$tcp.ObserveGuest($otherVlan)
Reject { $tcp.NormalizeHost($hostFrame) } 'Different VLAN authorized segmentation'
$tcp=[HostTcpSegmentation]::new()
for($i=0;$i -lt 4096;$i++) {
    $entry=Bytes $v.GuestSyn
    $entry[44]=[byte]($i -shr 8); $entry[45]=[byte]($i -band 255)
    $tcp.ObserveGuest($entry)
}
$extra=Bytes $v.GuestSyn; $extra[44]=0x10; $extra[45]=0
Reject { $tcp.ObserveGuest($extra) } 'Flow storage exceeded its bound'
$script:tick=[long]0
$timed=[HostTcpSegmentation]::new([Func[long]]{return $script:tick})
$timed.ObserveGuest($syn)
$ack=Bytes $v.GuestSyn; $ack[$ack.Length-11]=16
$script:tick=599999; $timed.ObserveGuest($ack)
$script:tick=600001
Assert ($timed.NormalizeHost($hostFrame).Length -gt 1) 'Active guest ACK did not refresh tracking'
$script:tick=1200001
Reject { $timed.NormalizeHost($hostFrame) } 'Inactive connection never expired'
foreach($bad in @((New-Object byte[] 13),(Bytes 'ffffffffffff5254001660018100'),(New-Object byte[] 262145))) {
    Reject { ([HostTcpSegmentation]::new()).ObserveGuest($bad) } 'Invalid guest capture accepted'
}
Reject { ([HostTcpSegmentation]::new()).NormalizeHost((New-Object byte[] 262145)) } 'Unbounded capture accepted'
$raw=Bytes 'ffffffffffff52540016600188b54269646972656374696f6e616c'
$normal=([HostTcpSegmentation]::new()).NormalizeHost($raw)
Assert ($normal.Length -eq 1 -and (Hash $normal[0]) -eq (Hash $raw)) 'Raw Ethernet payload changed'
"$script:checks Npcap segmentation checks passed"
