$egretManifest=Get-Content -LiteralPath (Join-Path $root 'patches\egret-2023-combat-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$egretManifest.id -cne 'aotc-egret-65-v1' -or
   @($egretManifest.files).Count -ne 3){
    throw 'Unrecognized production Egret reset manifest.'
}
$egretParts=New-Object 'System.Collections.Generic.List[object]'
foreach($asset in @($egretManifest.files)){
    $rel=[string]$asset.target
    if($rel -notin @(
        'mods/AOTC_BlackEgret_Combat_Test.lua',
        'mods/AOTC_BlackEgret_Combat_Test/parasoul.art',
        'mods/AOTC_BlackEgret_Combat_Test/parasoul.foit')){
        throw "Unexpected Egret reset target $rel"
    }
    $sha=([string]$asset.sha256).ToLowerInvariant()
    if($sha -notmatch '^[a-f0-9]{64}$'){throw 'Unpinned Egret reset file'}
    $egretParts.Add([pscustomobject]@{Rel=$rel;Hash=$sha;Bytes=[long]$asset.bytes})
}
if($egretParts.Count -ne 3){throw 'Expected three Egret mod files.'}
$egretExisting=@($egretParts | Where-Object {
    Test-Path -LiteralPath (Path-For $game $_.Rel) -PathType Leaf
})
if($egretExisting.Count -ne 0 -and $egretExisting.Count -ne 3){
    throw 'Partial Egret installation; refusing to reset.'
}
$egretRecord=$null
if($egretExisting.Count -eq 3){
    if($existing.Count -ne 5){
        throw 'Isolated Egret test present without cumulative shared loader. Use Run-Egret-Expanded-Test.cmd for rollback.'
    }
    foreach($part in $egretParts){
        $target=Path-For $game $part.Rel
        if((Hash $target) -cne $part.Hash -or
           (Get-Item -LiteralPath $target).Length -ne $part.Bytes){
            throw "Unexpected Egret mod contents: $target"
        }
    }
    $matches=New-Object 'System.Collections.Generic.List[string]'
    foreach($candidate in @(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Egret-Production-*' |
        Sort-Object LastWriteTimeUtc -Descending)){
        $ledger=Join-Path $candidate.FullName 'installed-files.json'
        if(-not(Test-Path -LiteralPath $ledger -PathType Leaf) -or
           (Test-Path -LiteralPath (Join-Path $candidate.FullName 'UNINSTALLED.txt'))){continue}
        $parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ledger -Raw -Encoding UTF8)
        $records=@($parsed | ForEach-Object {$_})
        if($records.Count -ne 3){continue}
        $valid=$true
        foreach($part in $egretParts){
            $target=Path-For $game $part.Rel
            if(@($records | Where-Object {
                ([string]$_.target) -ieq $target -and
                ([string]$_.sha256).ToLowerInvariant() -ceq $part.Hash
            }).Count -ne 1){$valid=$false;break}
        }
        if($valid){$matches.Add($candidate.FullName)}
    }
    if($matches.Count -ne 1){
        throw 'Expected exactly one matching active Egret production ledger.'
    }
    $egretRecord=$matches[0]
    foreach($part in $egretParts){
        Plan-Move (Path-For $game $part.Rel) ('RemovedEgret/'+$part.Rel)
    }
}
