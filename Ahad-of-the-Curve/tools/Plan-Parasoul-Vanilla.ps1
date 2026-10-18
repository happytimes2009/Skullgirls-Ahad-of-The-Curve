$parasoulManifest=Get-Content -LiteralPath (Join-Path $root 'patches\parasoul-historical-cutscenes-test-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$parasoulManifest.id -cne 'parasoul-historical-cutscenes-test-v1' -or
    @($parasoulManifest.assets).Count -ne 6){
    throw 'Unrecognized Parasoul production reset manifest.'
}
$parasoulBundle=Join-Path $root 'assets\parasoul'
$parasoulLuaHash=(Get-Content -LiteralPath (Join-Path $parasoulBundle 'lua-sha256.txt') -Raw).Trim().ToLowerInvariant()
$parasoulConfigHash=Hash (Join-Path $parasoulBundle 'TargetPath.txt')
$parasoulParts=New-Object 'System.Collections.Generic.List[object]'
$parasoulParts.Add([pscustomobject]@{
    Rel='mods/AOTC_Parasoul_Historical.lua';Hash=$parasoulLuaHash
})
$expectedStory=@('Intro/02.dxt1.dds','Intro/07.dxt1.dds','Intro/08.dxt1.dds','End/08.dxt1.dds','End/10.dxt1.dds')
$names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($asset in @($parasoulManifest.assets)){
    $file=[string]$asset.file
    if(-not $names.Add($file)){throw "Duplicate Parasoul reset manifest file: $file"}
    if($expectedStory -contains $file -and $asset.sourceType -ceq 'story'){
        $local=$file.Replace('/','')
    }elseif($file -ceq 'NPCs/genericsoldier.dds' -and $asset.sourceType -ceq 'portrait'){
        $local='GenericSoldier.dds'
    }else{
        throw "Unknown Parasoul reset image: $file"
    }
    $parasoulParts.Add([pscustomobject]@{
        Rel=('mods/AOTC_Parasoul_Historical/'+$local)
        Hash=([string]$asset.historicalSha256).ToLowerInvariant()
    })
}
$parasoulParts.Add([pscustomobject]@{
    Rel='mods/AOTC_Parasoul_Historical/TargetPath.txt';Hash=$parasoulConfigHash
})
if($parasoulParts.Count -ne 8 -or $names.Count -ne 6){throw 'Expected eight Parasoul production files.'}
foreach($part in $parasoulParts){
    if($part.Hash -notmatch '^[a-f0-9]{64}$'){throw "Invalid Parasoul reset checksum: $($part.Rel)"}
}
$parasoulExisting=@($parasoulParts | Where-Object {
    Test-Path -LiteralPath (Path-For $game $_.Rel) -PathType Leaf
})
if($parasoulExisting.Count -ne 0 -and $parasoulExisting.Count -ne 8){
    throw 'Partial Parasoul production installation. Nothing changed.'
}
$parasoulRecord=$null
if($parasoulExisting.Count -eq 8){
    if($existing.Count -ne 5){
        throw 'Isolated Parasoul test detected. Use tools/Remove-Parasoul-SkullLoader-Test.ps1, not cumulative reset.'
    }
    foreach($part in $parasoulParts){
        $target=Path-For $game $part.Rel
        if((Hash $target) -cne $part.Hash){throw "Unknown Parasoul mod contents: $target"}
    }
    $records=@(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Parasoul-Production-*' |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach($candidate in $records){
        $path=Join-Path $candidate.FullName 'installed-files.json'
        if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or
           (Test-Path -LiteralPath (Join-Path $candidate.FullName 'UNINSTALLED.txt'))){continue}
        $parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
        $rows=@($parsed | ForEach-Object {$_})
        if($rows.Count -ne 8){continue}
        $matches=$true
        foreach($part in $parasoulParts){
            $target=Path-For $game $part.Rel
            $match=@($rows|Where-Object{
                ([string]$_.target) -ieq $target -and
                ([string]$_.sha256).ToLowerInvariant() -ceq $part.Hash
            })
            if($match.Count -ne 1){$matches=$false;break}
        }
        if($matches){$parasoulRecord=$candidate.FullName;break}
    }
    if(-not $parasoulRecord){
        throw 'No matching active Parasoul production installation ledger. Nothing changed.'
    }
    foreach($part in $parasoulParts){
        Plan-Move (Path-For $game $part.Rel) ('RemovedParasoul/'+$part.Rel)
    }
}
