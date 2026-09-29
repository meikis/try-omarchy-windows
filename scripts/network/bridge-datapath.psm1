Set-StrictMode -Version Latest

function Get-BridgeDataPathAssessment {
    param([object[]]$Groups, [string[]]$AdapterGuids)
    $blockers = [Collections.Generic.List[string]]::new()
    try {
        $guids = @($AdapterGuids | ForEach-Object { ([guid]$_.Trim('{}')).ToString() })
        if ($guids.Count -ne 2 -or $guids[0] -eq $guids[1] -or -not $Groups.Count) {
            throw 'Two distinct members and a component inventory are required.'
        }
        foreach ($guid in $guids) {
            $matches = @()
            foreach ($group in $Groups) {
                foreach ($component in $group.Components) {
                    if ($component.Type -ne 'Miniport') { continue }
                    $identity = @($component.Properties | Where-Object Name -eq 'ifGuid')
                    if ($identity.Count -eq 1 -and ([string]$identity[0].Value).Trim('{}') -eq $guid) {
                        $matches += [pscustomobject]@{Group=$group; Miniport=$component}
                    }
                }
            }
            if ($matches.Count -ne 1) {
                $blockers.Add("member-inventory-ambiguous:$guid")
                continue
            }
            $index = @($matches[0].Miniport.Properties | Where-Object Name -eq 'ifIndex')
            if ($index.Count -ne 1 -or [int]$index[0].Value -le 0) { throw 'Invalid miniport index.' }
            # Enabled binding configuration is not proof that NDIS attached the
            # protocol. Require the actual protocol on this exact miniport.
            $protocols = @($matches[0].Group.Components | Where-Object {
                $_.Type -eq 'Protocol' -and $_.DriverName -eq 'NdisImPlatform.sys' -and
                @($_.Properties | Where-Object {
                    $_.Name -eq 'Miniport ifIndex' -and [int]$_.Value -eq [int]$index[0].Value
                }).Count -eq 1
            })
            if ($protocols.Count -ne 1) { $blockers.Add("bridge-protocol-not-attached:$guid") }
        }
    } catch {
        $blockers.Add('component-inventory-invalid')
    }
    [pscustomobject]@{Attached=($blockers.Count -eq 0); Blockers=@($blockers.ToArray()); BridgeAccepted=$false}
}

Export-ModuleMember -Function Get-BridgeDataPathAssessment
