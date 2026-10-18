param(
    [string]$GamePath,
    [string]$LoaderDllPath,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$manifest=Get-Content -LiteralPath (Join-Path $root 'patches\bigband-2023-intro-v1.json') -Raw | ConvertFrom-Json
$bundle=Join-Path $root 'assets\bigband\'
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"'))
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){throw 'Close Skullgirls before restoring Big Band.'}
if(-not (Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){throw 'SkullGirls.exe not found.'}
foreach($name in @('core.gfs','story_art.gfs')){
    if(-not (Test-Path -LiteralPath (Join-Path $game ('data01\'+$name)) -PathType Leaf)){throw "Missing game archive: $name"}
}
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
$coreFile=Join-Path $game 'data01\core.gfs'
$index=Get-SGIndex $coreFile
$entryName=[string]$manifest.oldScript.target
if(-not $index.ContainsKey($entryName)){throw 'Incompatible modern game: BigBandIntro.ini missing.'}
$stream=[IO.File]::OpenRead($coreFile)
try {[byte[]]$current=Read-SGEntry $stream $index[$entryName]}
finally {$stream.Dispose()}
if((Get-SGByteHash $current) -cne ([string]$manifest.oldScript.modernSHA256).ToLowerInvariant()){
    throw 'Unsupported current Big Band script version. No mod files changed.'
}
$modsDir=Join-Path $game 'mods'
if(Test-Path -LiteralPath $modsDir -PathType Container){
    $foreign=@(Get-ChildItem -LiteralPath $modsDir -Filter '*.lua' -File |
        Where-Object { $_.Name -notin @('AOTC_BigBand_2023.lua','AOTC_Double_2023.lua','AOTC_Beowulf_2023.lua','AOTC_Parasoul_Historical.lua','AOTC_BlackEgret_Combat_Test.lua') })
    if($foreign.Count -gt 0){throw "Existing SkullLoader mods detected: $($foreign.Name -join ', '). No changes made."}
}
$files=@(
    @{Source=(Join-Path $bundle 'AOTC_BigBand_2023.lua');Target=(Join-Path $game 'mods\AOTC_BigBand_2023.lua')},
    @{Source=(Join-Path $bundle 'BigBandIntro.ini');Target=(Join-Path $game 'mods\AOTC_BigBand_2023\BigBandIntro.ini');Expected=[string]$manifest.oldScript.packagedSHA256},
    @{Source=(Join-Path $bundle '03_1.dds');Target=(Join-Path $game 'mods\AOTC_BigBand_2023\03_1.dds');Expected=[string]$manifest.artwork[0].historicalSHA256},
    @{Source=(Join-Path $bundle '03_2.dds');Target=(Join-Path $game 'mods\AOTC_BigBand_2023\03_2.dds');Expected=[string]$manifest.artwork[1].historicalSHA256}
)
$loaderSource=Join-Path $bundle 'CoreMessaging.dll'
$loaderTarget=Join-Path $game 'CoreMessaging.dll'
if($LoaderDllPath){$loaderSource=[IO.Path]::GetFullPath($LoaderDllPath.Trim().Trim('"'))}
if(-not (Test-Path -LiteralPath $loaderSource -PathType Leaf)){throw "Required SkullLoader CoreMessaging.dll is absent: $loaderSource"}
$expectedLoader=(Get-Content -LiteralPath (Join-Path $bundle 'loader-sha256.txt') -Raw).Trim().ToLowerInvariant()
if($expectedLoader -notmatch '^[0-9a-f]{64}$'){throw 'Invalid pinned SkullLoader hash.'}
$files+=@{Source=$loaderSource;Target=$loaderTarget;Expected=$expectedLoader}
$luaExpected=(Get-Content -LiteralPath (Join-Path $bundle 'lua-sha256.txt') -Raw).Trim().ToLowerInvariant()
$files[0].Expected=$luaExpected
foreach($f in $files){
    if(-not(Test-Path -LiteralPath $f.Source -PathType Leaf)){throw "Missing production asset $($f.Source)"}
    $hash=(Get-FileHash -LiteralPath $f.Source -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -cne ([string]$f.Expected).ToLowerInvariant()){throw "Source SHA-256 mismatch: $($f.Source)"}
}
foreach($name in @('d3d9.dll','dbghelp.dll')){
    if(Test-Path -LiteralPath (Join-Path $game $name)){throw "Another proxy DLL exists: $name. No changes made."}
}
$statuses=@()
foreach($f in $files){
    if(Test-Path -LiteralPath $f.Target){
        if(-not(Test-Path -LiteralPath $f.Target -PathType Leaf)){throw "Unexpected target directory: $($f.Target)"}
        $hash=(Get-FileHash -LiteralPath $f.Target -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -cne ([string]$f.Expected).ToLowerInvariant()){throw "Conflicting existing file: $($f.Target). No changes made."}
        $statuses+= 'present'
    } else {$statuses+= 'missing'}
}
if(($statuses -contains 'present') -and ($statuses -contains 'missing')){
    throw 'Partial or mixed SkullLoader installation detected. Refusing to overwrite or complete it automatically.'
}
if($ValidateOnly){Write-Host 'Big Band production preflight passed.';return}
if($statuses -notcontains 'missing'){Write-Host 'Big Band files already installed and hash-verified.';return}
$stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$backup=Join-Path $game ('Restoration Backups\AOTC-BigBand-Production-'+$stamp)
$installed=New-Object 'System.Collections.Generic.List[string]'
try {
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach($f in $files){
        New-Item -ItemType Directory -Path (Split-Path $f.Target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $f.Source -Destination $f.Target -ErrorAction Stop
        $installed.Add([string]$f.Target)
        $check=(Get-FileHash -LiteralPath $f.Target -Algorithm SHA256).Hash.ToLowerInvariant()
        if($check -cne ([string]$f.Expected).ToLowerInvariant()){throw "Copy verification failed: $($f.Target)"}
    }
    $ledger=@($files | ForEach-Object {
        [pscustomobject]@{target=[string]$_.Target;sha256=([string]$_.Expected).ToLowerInvariant()}
    })
    ConvertTo-Json -InputObject $ledger -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'installed-files.json') -Encoding UTF8
} catch {
    $failure=$_
    foreach($path in $installed){
        $item=$files | Where-Object { $_.Target -ceq $path } | Select-Object -First 1
        if((Test-Path -LiteralPath $path -PathType Leaf) -and
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq ([string]$item.Expected).ToLowerInvariant()){
            Remove-Item -LiteralPath $path -Force
        }
    }
    throw $failure
}
Write-Host 'Big Band restored using SkullLoader. Original data01 archives untouched.'
Write-Host "Installation record: $backup"
