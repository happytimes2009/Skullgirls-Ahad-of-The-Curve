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
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
    throw 'Close Skullgirls before restoring Beowulf.'
}
$manifest=Get-Content -LiteralPath (Join-Path $root 'patches\beowulf-2023-act5-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$manifest.id -cne 'beowulf-2023-act5-v1' -or @($manifest.artwork).Count -ne 5){
    throw 'Unexpected Beowulf production manifest.'
}
$bundle=Join-Path $root 'assets\beowulf'
$lua=Join-Path $bundle 'AOTC_Beowulf_2023.lua'
$luaPin=Join-Path $bundle 'lua-sha256.txt'
$loaderSource=Join-Path $root 'assets\bigband\CoreMessaging.dll'
$loaderPin=Join-Path $root 'assets\bigband\loader-sha256.txt'
$loaderTarget=Join-Path $game 'CoreMessaging.dll'
$bigSource=Join-Path $root 'assets\bigband\AOTC_BigBand_2023.lua'
$bigTarget=Join-Path $game 'mods\AOTC_BigBand_2023.lua'
foreach($required in @($lua,$luaPin,$loaderSource,$loaderPin,$bigSource)){
    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){
        throw "Missing production Beowulf dependency: $required"
    }
}
$expectedLua=(Get-Content -LiteralPath $luaPin -Raw).Trim().ToLowerInvariant()
$expectedLoader=(Get-Content -LiteralPath $loaderPin -Raw).Trim().ToLowerInvariant()
foreach($h in @($expectedLua,$expectedLoader)){
    if($h -notmatch '^[0-9a-f]{64}$'){throw 'Invalid Beowulf or loader SHA-256 pin.'}
}
if((Get-SGHash $lua) -cne $expectedLua -or
   (Get-SGHash $loaderSource) -cne $expectedLoader){
    throw 'Bundled Beowulf Lua or SkullLoader DLL hash mismatch.'
}
if(Test-Path -LiteralPath $loaderTarget -PathType Leaf){
    if((Get-SGHash $loaderTarget) -cne $expectedLoader){
        throw 'Another SkullLoader DLL is installed. No changes made.'
    }
}
$hasLoader=Test-Path -LiteralPath $loaderTarget -PathType Leaf
$hasBig=Test-Path -LiteralPath $bigTarget -PathType Leaf
if($hasBig -and (Get-SGHash $bigTarget) -cne (Get-SGHash $bigSource)){
    throw 'The installed Big Band Lua differs from production.'
}
if($hasBig -ne $hasLoader){
    throw 'Partial shared SkullLoader installation detected. No changes made.'
}
foreach($name in @('d3d9.dll','dbghelp.dll')){
    if(Test-Path -LiteralPath (Join-Path $game $name)){
        throw "Conflicting DLL proxy: $name"
    }
}
$core=Join-Path $game 'data01\story_art.gfs'
if(-not(Test-Path -LiteralPath $core -PathType Leaf)){
    throw 'Missing original story_art.gfs archive.'
}
$index=Get-SGIndex $core
$stream=[IO.File]::OpenRead($core)
$parts=New-Object 'System.Collections.Generic.List[object]'
$parts.Add([pscustomobject]@{
    Source=$lua
    Target=(Join-Path $game 'mods\AOTC_Beowulf_2023.lua')
    Hash=$expectedLua
})
$expectedNames=@('13.dds','13_1.dds','14.dds','15.dds','16.dds')
try{
    foreach($asset in @($manifest.artwork)){
        $name=[string]$asset.file
        if($expectedNames -notcontains $name){throw "Unrecognized Beowulf image: $name"}
        $src=Join-Path $bundle $name
        if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "Missing original Beowulf DDS: $src"}
        $historical=([string]$asset.historicalSha256).ToLowerInvariant()
        if($historical -notmatch '^[0-9a-f]{64}$' -or
           (Get-SGHash $src) -cne $historical -or
           (Get-Item -LiteralPath $src).Length -ne [long]$asset.historicalSize){
            throw "Bundled Beowulf texture differs from approved source: $name"
        }
        $dds=[IO.File]::ReadAllBytes($src)
        if($dds.Length -lt 128 -or
           [Text.Encoding]::ASCII.GetString($dds,0,4) -cne 'DDS ' -or
           [Text.Encoding]::ASCII.GetString($dds,84,4) -cne 'DXT1' -or
           [BitConverter]::ToUInt32($dds,12) -ne [int]$asset.height -or
           [BitConverter]::ToUInt32($dds,16) -ne [int]$asset.width){
            throw "Beowulf DDS has unexpected format or dimensions: $name"
        }
        $entry=([string]$manifest.modernPrefix)+$name
        if(-not $index.ContainsKey($entry)){
            throw "Expected current Beowulf story texture missing: $entry"
        }
        [byte[]]$current=Read-SGEntry $stream $index[$entry]
        if($current.Length -ne [long]$asset.currentSize -or
           (Get-SGByteHash $current) -cne ([string]$asset.currentSha256).ToLowerInvariant()){
            throw "Modern Beowulf texture does not match supported game version: $name"
        }
        $parts.Add([pscustomobject]@{
            Source=$src
            Target=(Join-Path $game ('mods\AOTC_Beowulf_2023\'+$name))
            Hash=$historical
        })
    }
}finally{$stream.Dispose()}
if($parts.Count -ne 6 -or $expectedNames.Count -ne 5){
    throw 'Expected exactly six Beowulf production files.'
}
$installed=@($parts|Where-Object{Test-Path -LiteralPath $_.Target -PathType Leaf})
if($installed.Count -ne 0 -and $installed.Count -ne 6){
    throw 'Partial Beowulf production installation detected. No changes made.'
}
if($installed.Count -eq 6){
    foreach($p in $parts){
        if((Get-SGHash $p.Target) -cne $p.Hash){
            throw "Conflicting installed Beowulf file: $($p.Target)"
        }
    }
    if(-not $hasBig){
        throw 'Detected isolated Beowulf test, not cumulative production. Use the standalone Beowulf rollback first.'
    }
}
$mods=Join-Path $game 'mods'
if(Test-Path -LiteralPath $mods -PathType Container){
    $allowed=@('AOTC_BigBand_2023.lua','AOTC_Double_2023.lua','AOTC_Beowulf_2023.lua')
    $other=@(Get-ChildItem -LiteralPath $mods -File -ErrorAction Stop |
       Where-Object {$allowed -notcontains $_.Name})
    if($other.Count -gt 0){throw "Unrecognized SkullLoader Lua mod exists: $($other[0].FullName)"}
}
if($ValidateOnly){
    Write-Host 'Beowulf production preflight passed.'
    return
}
if(-not $hasBig -or -not $hasLoader){
    throw 'The production Big Band loader must be installed before Beowulf.'
}
if($installed.Count -eq 6){
    Write-Host 'Beowulf original Act 5 artwork already installed and hash-verified.'
    return
}
$stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$record=Join-Path $game ('Restoration Backups\AOTC-Beowulf-Production-'+$stamp)
$done=New-Object 'System.Collections.Generic.List[object]'
try{
    New-Item -ItemType Directory -Path $record -Force | Out-Null
    foreach($p in $parts){
        if(Test-Path -LiteralPath $p.Target){throw "Target unexpectedly occupied: $($p.Target)"}
        New-Item -ItemType Directory -Path (Split-Path -Parent $p.Target) -Force | Out-Null
        Copy-Item -LiteralPath $p.Source -Destination $p.Target -ErrorAction Stop
        $done.Add($p)
        if((Get-SGHash $p.Target) -cne $p.Hash){
            throw "Copy verification failed for Beowulf image: $($p.Target)"
        }
    }
    $ledger=@($parts | ForEach-Object{
        [pscustomobject]@{target=$_.Target;sha256=$_.Hash}
    })
    ConvertTo-Json -InputObject $ledger -Depth 4 |
        Set-Content -LiteralPath (Join-Path $record 'installed-files.json') -Encoding UTF8
}catch{
    $failure=$_
    for($i=$done.Count-1;$i -ge 0;$i--){
        $p=$done[$i]
        if((Test-Path -LiteralPath $p.Target -PathType Leaf) -and
           (Get-SGHash $p.Target) -ceq $p.Hash){
            Remove-Item -LiteralPath $p.Target -Force
        }
    }
    throw $failure
}
Write-Host 'Beowulf Act 5 artwork installed through shared SkullLoader.' -ForegroundColor Green
Write-Host "Beowulf installation record: $record"
