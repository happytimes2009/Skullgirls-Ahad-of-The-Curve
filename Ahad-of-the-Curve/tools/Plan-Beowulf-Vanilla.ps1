$beowulfManifest=Get-Content -LiteralPath (Join-Path $root 'patches\beowulf-2023-act5-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$beowulfNames=@('13.dds','13_1.dds','14.dds','15.dds','16.dds')
if([string]$beowulfManifest.id -cne 'beowulf-2023-act5-v1' -or @($beowulfManifest.artwork).Count -ne 5){
    throw 'Unexpected Beowulf reset manifest.'
}
$beowulfBundle=Join-Path $root 'assets\beowulf'
$beowulfLuaHash=(Get-Content -LiteralPath (Join-Path $beowulfBundle 'lua-sha256.txt') -Raw).Trim().ToLowerInvariant()
$beowulfParts=New-Object 'System.Collections.Generic.List[object]'
$beowulfParts.Add([pscustomobject]@{Rel='mods/AOTC_Beowulf_2023.lua';Hash=$beowulfLuaHash})
foreach($asset in @($beowulfManifest.artwork)){
    $name=[string]$asset.file
    if($beowulfNames -notcontains $name){throw "Unrecognized Beowulf reset DDS: $name"}
    $beowulfParts.Add([pscustomobject]@{
        Rel=('mods/AOTC_Beowulf_2023/'+$name)
        Hash=([string]$asset.historicalSha256).ToLowerInvariant()
    })
}
if($beowulfParts.Count -ne 6){throw 'Unexpected Beowulf reset file count.'}
foreach($part in $beowulfParts){
    if($part.Hash -notmatch '^[0-9a-f]{64}$'){throw "Invalid Beowulf reset hash: $($part.Rel)"}
}
$beowulfExisting=@($beowulfParts | Where-Object {
    Test-Path -LiteralPath (Path-For $game $_.Rel) -PathType Leaf
})
if($beowulfExisting.Count -ne 0 -and $beowulfExisting.Count -ne 6){
    throw 'Partial Beowulf production installation. No changes made.'
}
$beowulfRecord=$null
if($beowulfExisting.Count -eq 6){
    if($existing.Count -ne 5){
        throw 'Isolated Beowulf test detected. Use tools/Remove-Beowulf-SkullLoader-Test.ps1, not cumulative reset.'
    }
    foreach($part in $beowulfParts){
        $target=Path-For $game $part.Rel
        if((Hash $target) -cne $part.Hash){throw "Unknown Beowulf mod content: $target"}
    }
    $beowulfRecords=@(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Beowulf-Production-*' |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach($candidate in $beowulfRecords){
        $ledger=Join-Path $candidate.FullName 'installed-files.json'
        if(-not(Test-Path -LiteralPath $ledger -PathType Leaf) -or
           (Test-Path -LiteralPath (Join-Path $candidate.FullName 'UNINSTALLED.txt'))){continue}
        $parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ledger -Raw -Encoding UTF8)
        $beowulfLedgerRows=@($parsed | ForEach-Object {$_})
        if($beowulfLedgerRows.Count -ne 6){continue}
        $allMatched=$true
        foreach($part in $beowulfParts){
            $target=Path-For $game $part.Rel
            $matching=@($beowulfLedgerRows | Where-Object {
                ([string]$_.target) -ieq $target -and
                ([string]$_.sha256).ToLowerInvariant() -ceq $part.Hash
            })
            if($matching.Count -ne 1){$allMatched=$false;break}
        }
        if($allMatched){$beowulfRecord=$candidate.FullName;break}
    }
    if(-not $beowulfRecord){
        throw 'No matching active Beowulf production ledger. No changes made.'
    }
    foreach($part in $beowulfParts){
        Plan-Move (Path-For $game $part.Rel) ('RemovedBeowulf/'+$part.Rel)
    }
}
