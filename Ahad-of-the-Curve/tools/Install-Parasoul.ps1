param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw 'SkullGirls.exe not found. No changes made.'
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls before installing Parasoul.'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'patches\parasoul-historical-cutscenes-test-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$manifest.id -cne 'parasoul-historical-cutscenes-test-v1' -or
    @($manifest.assets).Count -ne 6){throw 'Unexpected Parasoul production manifest.'}
$bundle=Join-Path $root 'assets\parasoul'
$lua=Join-Path $bundle 'AOTC_Parasoul_Historical.lua'
$luaPin=Join-Path $bundle 'lua-sha256.txt'
$targetConfig=Join-Path $bundle 'TargetPath.txt'
$loaderPin=Join-Path $root 'assets\bigband\loader-sha256.txt'
$loaderTarget=Join-Path $game 'CoreMessaging.dll'
$bigSource=Join-Path $root 'assets\bigband\AOTC_BigBand_2023.lua'
$bigTarget=Join-Path $game 'mods\AOTC_BigBand_2023.lua'
foreach($f in @($lua,$luaPin,$targetConfig,$loaderPin,$bigSource)){
    if(-not(Test-Path -LiteralPath $f -PathType Leaf)){throw "Parasoul production dependency missing: $f"}
}
$expectedLua=(Get-Content -LiteralPath $luaPin -Raw).Trim().ToLowerInvariant()
$expectedLoader=(Get-Content -LiteralPath $loaderPin -Raw).Trim().ToLowerInvariant()
if($expectedLua -notmatch '^[a-f0-9]{64}$' -or $expectedLoader -notmatch '^[a-f0-9]{64}$' -or
    (Get-SGHash $lua) -cne $expectedLua){throw 'Unexpected bundled Parasoul Lua or SkullLoader hash.'}
$targetText=(Get-Content -LiteralPath $targetConfig -Raw -Encoding ASCII).Trim()
if($targetText -cne 'story_art/THs/NPCs/genericsoldier.dds'){
    throw 'Unexpected generic soldier portrait path in Parasoul production.'
}
$configHash=Get-SGHash $targetConfig
$hasBig=Test-Path -LiteralPath $bigTarget -PathType Leaf
$hasLoader=Test-Path -LiteralPath $loaderTarget -PathType Leaf
if($hasBig -ne $hasLoader){throw 'Partial shared SkullLoader installation. No changes made.'}
if($hasBig -and (Get-SGHash $bigTarget) -cne (Get-SGHash $bigSource)){
    throw 'Installed Big Band Lua differs from verified production.'
}
if($hasLoader -and (Get-SGHash $loaderTarget) -cne $expectedLoader){
    throw 'Unexpected shared SkullLoader DLL.'
}
foreach($dll in @('d3d9.dll','dbghelp.dll')){
    if(Test-Path -LiteralPath (Join-Path $game $dll)){throw "Conflicting loader DLL: $dll"}
}
$core=Join-Path $game 'data01\story_art.gfs'
if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw 'Modern story_art.gfs missing.'}
$idx=Get-SGIndex $core
$stream=[IO.File]::OpenRead($core)
$parts=New-Object 'System.Collections.Generic.List[object]'
$parts.Add([pscustomobject]@{
    Source=$lua;Rel='mods/AOTC_Parasoul_Historical.lua';Hash=$expectedLua
})
$names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
try{
    foreach($asset in @($manifest.assets)){
        $name=[string]$asset.file
        if(-not $names.Add($name)){throw "Duplicate Parasoul manifest item: $name"}
        if($asset.sourceType -ceq 'story'){
            if($name -notmatch '^(Intro/(02|07|08)|End/(08|10))\.dxt1\.dds$'){
                throw "Unapproved Parasoul story texture: $name"
            }
            $local=$name.Replace('/','')
            $entry=([string]$manifest.modernPrefix)+$name
        }elseif($asset.sourceType -ceq 'portrait' -and $name -ceq 'NPCs/genericsoldier.dds'){
            $local='GenericSoldier.dds'
            $entry=$targetText
        }else{throw "Unapproved Parasoul source image: $name"}
        $src=Join-Path $bundle $local
        $hash=([string]$asset.historicalSha256).ToLowerInvariant()
        if(-not(Test-Path -LiteralPath $src -PathType Leaf) -or $hash -notmatch '^[a-f0-9]{64}$' -or
            (Get-SGHash $src) -cne $hash -or
            (Get-Item -LiteralPath $src).Length -ne [long]$asset.historicalSize){
            throw "Historical Parasoul asset failed checksum: $local"
        }
        $dds=[IO.File]::ReadAllBytes($src)
        if($dds.Length -lt 128 -or [Text.Encoding]::ASCII.GetString($dds,0,4) -cne 'DDS ' -or
           [Text.Encoding]::ASCII.GetString($dds,84,4) -cne [string]$asset.sourceFourCC -or
           [BitConverter]::ToUInt32($dds,16) -ne [uint32]$asset.sourceWidth -or
           [BitConverter]::ToUInt32($dds,12) -ne [uint32]$asset.sourceHeight){
            throw "Unexpected historical Parasoul DDS structure: $local"
        }
        if(-not $idx.ContainsKey($entry)){throw "Modern game lacks Parasoul target: $entry"}
        [byte[]]$current=Read-SGEntry $stream $idx[$entry]
        if($asset.sourceType -ceq 'story'){
            if((Get-SGByteHash $current) -cne ([string]$asset.currentSha256).ToLowerInvariant() -or
                $current.Length -ne [long]$asset.currentSize){
                throw "Modern Parasoul texture differs from approved game version: $entry"
            }
        }elseif((Get-SGByteHash $current) -ceq $hash){
            throw 'Generic soldier is already restored; unexpected installation state.'
        }
        $parts.Add([pscustomobject]@{
            Source=$src;Rel=('mods/AOTC_Parasoul_Historical/'+$local);Hash=$hash
        })
    }
}finally{$stream.Dispose()}
$parts.Add([pscustomobject]@{
    Source=$targetConfig;Rel='mods/AOTC_Parasoul_Historical/TargetPath.txt';Hash=$configHash
})
if($parts.Count -ne 8 -or $names.Count -ne 6){throw 'Expected eight Parasoul production files.'}
foreach($part in $parts){$part | Add-Member -NotePropertyName Target -NotePropertyValue (Join-Path $game ($part.Rel.Replace('/','\')))}
$existing=@($parts | Where-Object {Test-Path -LiteralPath $_.Target -PathType Leaf})
if($existing.Count -ne 0 -and $existing.Count -ne 8){
    throw 'Partial Parasoul production installation. Nothing changed.'
}
if($existing.Count -eq 8){
    foreach($part in $parts){
        if((Get-SGHash $part.Target) -cne $part.Hash){throw "Unexpected installed Parasoul file: $($part.Target)"}
    }
    if(-not $hasBig){throw 'Isolated Parasoul test detected, not cumulative production. Remove the isolated test first.'}
}
$mods=Join-Path $game 'mods'
if(Test-Path -LiteralPath $mods -PathType Container){
    $allowed=@('AOTC_BigBand_2023.lua','AOTC_Double_2023.lua','AOTC_Beowulf_2023.lua','AOTC_Parasoul_Historical.lua','AOTC_BlackEgret_Combat_Test.lua')
    $other=@(Get-ChildItem -LiteralPath $mods -File -ErrorAction Stop |
        Where-Object {$allowed -notcontains $_.Name})
    if($other.Count -gt 0){throw "Unrecognized mod Lua script: $($other[0].FullName)"}
}
if($ValidateOnly){Write-Host 'Parasoul production preflight passed.';return}
if(-not $hasBig -or -not $hasLoader){throw 'Install cumulative Big Band SkullLoader before Parasoul.'}
if($existing.Count -eq 8){Write-Host 'Parasoul historical art already installed and hash-verified.';return}
$stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$record=Join-Path $game ('Restoration Backups\AOTC-Parasoul-Production-'+$stamp)
$done=New-Object 'System.Collections.Generic.List[object]'
try{
    New-Item -ItemType Directory -Path $record -Force | Out-Null
    foreach($part in $parts){
        if(Test-Path -LiteralPath $part.Target){throw "Parasoul installation target already occupied: $($part.Target)"}
        New-Item -ItemType Directory -Path (Split-Path -Parent $part.Target) -Force | Out-Null
        Copy-Item -LiteralPath $part.Source -Destination $part.Target -ErrorAction Stop
        $done.Add($part)
        if((Get-SGHash $part.Target) -cne $part.Hash){throw "Failed to verify installed Parasoul asset: $($part.Target)"}
    }
    $ledger=@($parts | ForEach-Object {
        [pscustomobject]@{target=$_.Target;sha256=$_.Hash}
    })
    ConvertTo-Json -InputObject $ledger -Depth 4 |
        Set-Content -LiteralPath (Join-Path $record 'installed-files.json') -Encoding UTF8
}catch{
    $failure=$_
    for($i=$done.Count-1;$i -ge 0;$i--){
        $part=$done[$i]
        if((Test-Path -LiteralPath $part.Target -PathType Leaf) -and
            (Get-SGHash $part.Target) -ceq $part.Hash){
            Remove-Item -LiteralPath $part.Target -Force
        }
    }
    throw $failure
}
Write-Host 'Parasoul: original red banner, Egret armbands and 2014 soldier portrait installed.' -ForegroundColor Green
Write-Host "Parasoul production installation ledger: $record"
