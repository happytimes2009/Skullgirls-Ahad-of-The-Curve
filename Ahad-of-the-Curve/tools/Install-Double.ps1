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
    throw 'SkullGirls.exe not found. Nothing installed.'
}
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls before restoring Double.'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'patches\double-2023-ending-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$manifest.patchId -cne 'double-2023-ending-v1'){throw 'Unexpected Double restoration manifest.'}
$bundle=Join-Path $root 'assets\double'
$lua=Join-Path $bundle 'AOTC_Double_2023.lua'
$dds=Join-Path $bundle 'End05.dxt1.dds'
$luaPin=Join-Path $bundle 'lua-sha256.txt'
$sharedLoader=Join-Path $game 'CoreMessaging.dll'
$loaderPin=Join-Path $root 'assets\bigband\loader-sha256.txt'
$loaderSource=Join-Path $root 'assets\bigband\CoreMessaging.dll'
$bigLua=Join-Path $game 'mods\AOTC_BigBand_2023.lua'
$bigLuaSource=Join-Path $root 'assets\bigband\AOTC_BigBand_2023.lua'
foreach($file in @($lua,$dds,$luaPin,$loaderPin,$loaderSource,$bigLuaSource)){
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Production Double dependency missing: $file"}
}
$expectedLua=(Get-Content -LiteralPath $luaPin -Raw).Trim().ToLowerInvariant()
$expectedLoader=(Get-Content -LiteralPath $loaderPin -Raw).Trim().ToLowerInvariant()
$expectedDDS=([string]$manifest.historicalSHA256).ToLowerInvariant()
foreach($h in @($expectedLua,$expectedLoader,$expectedDDS)){
    if($h -notmatch '^[0-9a-f]{64}$'){throw 'Invalid pinned production hash.'}
}
if((Get-SGHash $lua) -cne $expectedLua -or
   (Get-SGHash $dds) -cne $expectedDDS -or
   (Get-Item -LiteralPath $dds).Length -ne [long]$manifest.historicalLength -or
   (Get-SGHash $loaderSource) -cne $expectedLoader){
    throw 'A bundled Double or SkullLoader source differs from its approved checksum.'
}
$coreArchive=Join-Path $game 'data01\story_art.gfs'
if(-not(Test-Path -LiteralPath $coreArchive -PathType Leaf)){throw 'Missing original story_art.gfs archive.'}
$index=Get-SGIndex $coreArchive
$target=[string]$manifest.target
if(-not $index.ContainsKey($target)){throw 'Modern Double ending texture not found.'}
$stream=[IO.File]::OpenRead($coreArchive)
try{
    [byte[]]$modern=Read-SGEntry $stream $index[$target]
}finally{$stream.Dispose()}
if((Get-SGByteHash $modern) -cne ([string]$manifest.currentSHA256).ToLowerInvariant() -or
   $modern.Length -ne [int]$manifest.currentLength){
    throw 'Unexpected current Double ending texture. No changes made.'
}
foreach($name in @('d3d9.dll','dbghelp.dll')){
    if(Test-Path -LiteralPath (Join-Path $game $name)){throw "Conflicting proxy DLL exists: $name"}
}
$bigPresent=Test-Path -LiteralPath $bigLua -PathType Leaf
$loaderPresent=Test-Path -LiteralPath $sharedLoader -PathType Leaf
if($bigPresent){
    if((Get-SGHash $bigLua) -cne (Get-SGHash $bigLuaSource)){
        throw 'Existing Big Band mod differs from the production version.'
    }
}
if($loaderPresent -and (Get-SGHash $sharedLoader) -cne $expectedLoader){
    throw 'Different SkullLoader DLL installed. Refusing to replace it.'
}
if($bigPresent -ne $loaderPresent){throw 'Partially installed shared Big Band loader. No changes made.'}
$parts=@(
    [pscustomobject]@{Source=$lua;Target=(Join-Path $game 'mods\AOTC_Double_2023.lua');Hash=$expectedLua},
    [pscustomobject]@{Source=$dds;Target=(Join-Path $game 'mods\AOTC_Double_2023\End05.dxt1.dds');Hash=$expectedDDS}
)
$present=@($parts|Where-Object {Test-Path -LiteralPath $_.Target -PathType Leaf})
if($present.Count -ne 0 -and $present.Count -ne 2){throw 'Partial Double installation. No changes made.'}
if($present.Count -eq 2){
    foreach($p in $parts){
        if((Get-SGHash $p.Target) -cne $p.Hash){
            throw "Conflicting existing Double mod file: $($p.Target)"
        }
    }
    if(-not $bigPresent){throw 'The isolated Double test is still installed. Remove it before using cumulative production.'}
}
$mods=Join-Path $game 'mods'
if(Test-Path -LiteralPath $mods -PathType Container){
    $allowed=@(
        'AOTC_BigBand_2023.lua',
        'AOTC_Double_2023.lua',
        'AOTC_Beowulf_2023.lua'
    )
    $others=@(Get-ChildItem -LiteralPath $mods -File -ErrorAction Stop |
        Where-Object {$allowed -notcontains $_.Name})
    if($others.Count -gt 0){throw "Unrecognized SkullLoader mod exists: $($others[0].FullName)"}
}
if($ValidateOnly){
    Write-Host 'Double production preflight passed.'
    return
}
if(-not $bigPresent -or -not $loaderPresent){
    throw 'The cumulative Big Band loader must be installed before the Double section.'
}
if($present.Count -eq 2){
    Write-Host 'Double original ending already installed and verified.'
    return
}
$timestamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$backup=Join-Path $game ('Restoration Backups\AOTC-Double-Production-'+$timestamp)
$done=New-Object 'System.Collections.Generic.List[object]'
try{
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach($p in $parts){
        New-Item -ItemType Directory -Path (Split-Path $p.Target -Parent) -Force | Out-Null
        if(Test-Path -LiteralPath $p.Target){throw "Double target unexpectedly appeared: $($p.Target)"}
        Copy-Item -LiteralPath $p.Source -Destination $p.Target -ErrorAction Stop
        $done.Add($p)
        if((Get-SGHash $p.Target) -cne $p.Hash){throw "Double copy verification failed: $($p.Target)"}
    }
    $ledger=@($parts|ForEach-Object{[pscustomobject]@{target=$_.Target;sha256=$_.Hash}})
    ConvertTo-Json -InputObject $ledger -Depth 4 |
        Set-Content -LiteralPath (Join-Path $backup 'installed-files.json') -Encoding UTF8
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
Write-Host 'Double 2023 ending added to the shared SkullLoader installation.' -ForegroundColor Green
Write-Host "Double installation record: $backup"
