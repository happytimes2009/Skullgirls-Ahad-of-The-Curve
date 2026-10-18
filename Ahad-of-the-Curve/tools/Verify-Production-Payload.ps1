param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$inventory=Join-Path $root 'patches\production-file-sha256.json'
if(-not(Test-Path -LiteralPath $inventory -PathType Leaf)){
    throw 'Production payload inventory is missing. This is NOT a self-contained AOTC release.'
}
$manifest=Get-Content -LiteralPath $inventory -Raw -Encoding UTF8 | ConvertFrom-Json
if([int]$manifest.schema -ne 1 -or
   [string]$manifest.release -cne 'v0.10' -or
   @($manifest.files).Count -lt 90){
    throw 'Invalid/incomplete production payload inventory.'
}
$seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$rootPrefix=$root.TrimEnd('\','/')+'\'
foreach($file in @($manifest.files)){
    $rel=[string]$file.path
    if($rel -ieq 'README.md'){
        throw 'README.md must not be listed as a required production payload.'
    }
    $parts=$rel.Replace('\','/').Split('/')
    if(-not $rel -or $rel.StartsWith('/') -or $rel.StartsWith('\') -or
       $rel.Contains(':') -or $rel.Contains([char]0) -or
       $parts -contains '' -or $parts -contains '.' -or $parts -contains '..' -or
       $rel -ceq 'patches/production-file-sha256.json' -or
       -not $seen.Add($rel)){
        throw "Unsafe or duplicate payload name: $rel"
    }
    $path=[IO.Path]::GetFullPath((Join-Path $root $rel.Replace('/','\')))
    if(-not $path.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){
        throw "Payload file escaped AOTC release folder: $rel"
    }
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
        throw "Release payload missing: $rel"
    }
    $item=Get-Item -LiteralPath $path
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
        throw "Refusing linked payload path: $rel"
    }
    $hash=([string]$file.sha256).ToLowerInvariant()
    if($hash -notmatch '^[0-9a-f]{64}$' -or
       $item.Length -ne [long]$file.bytes -or
       (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash){
        throw "Release payload altered or corrupted: $rel"
    }
}
foreach($needed in @(
    'assets/soviet/AOTC_Soviet_Historical_Test.lua',
    'assets/soviet/hitspark_alt3.snd-wav',
    'patches/soviet-voice-v1.json',
    'tools/Install-Soviet-Voice.ps1',
    'tools/SG-ESGWarning.ps1',
    'assets/combo/AOTC_Combo_Original.lua',
    'assets/combo/en_loc.json',
    'patches/combo-callouts-v1.json',
    'tools/Install-Combo-Callouts.ps1',
    'tools/Reset-AOTC-Targeted.ps1',
    'tools/Verify-Source-Pins.ps1',
    'tools/AOTC.ps1',
    'AOTC.cmd'
)){
    if(-not $seen.Contains($needed)){
        throw "Self-contained Soviet voice component missing from release manifest: $needed"
    }
}
$legacyReadme=Join-Path $root 'README.md'
$actual=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop |
    Where-Object { $_.FullName -ine $legacyReadme })
if($actual.Count -ne $seen.Count+1){
    throw "Release folder contains missing or unexpected files. Inventory: $($seen.Count) plus manifest, disk: $($actual.Count)."
}
foreach($item in $actual){
    $rel=$item.FullName.Substring($rootPrefix.Length).Replace('\','/')
    if($rel -ceq 'patches/production-file-sha256.json'){continue}
    if(-not $seen.Contains($rel)){throw "Unapproved extra file in production: $rel"}
}
foreach($character in @(
    [pscustomobject]@{Directory='bigband';Lua='AOTC_BigBand_2023.lua'},
    [pscustomobject]@{Directory='double';Lua='AOTC_Double_2023.lua'},
    [pscustomobject]@{Directory='beowulf';Lua='AOTC_Beowulf_2023.lua'},
    [pscustomobject]@{Directory='parasoul';Lua='AOTC_Parasoul_Historical.lua'}
)){
    $folder=Join-Path (Join-Path $root 'assets') $character.Directory
    $luaPath=Join-Path $folder $character.Lua
    $pinPath=Join-Path $folder 'lua-sha256.txt'
    $pinned=(Get-Content -LiteralPath $pinPath -Raw -Encoding UTF8).Trim().ToLowerInvariant()
    $actual=(Get-FileHash -LiteralPath $luaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($pinned -notmatch '^[0-9a-f]{64}$' -or $pinned -cne $actual){
        throw "Runtime Lua SHA-256 pin mismatch for $($character.Directory): expected $pinned, actual $actual"
    }
}
$scriptFiles=@(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter '*.ps1' -File -ErrorAction Stop)
foreach($script in $scriptFiles){
    $tokens=$null
    $parseErrors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$parseErrors)
    if(@($parseErrors).Count -gt 0){
        throw ("PowerShell syntax error in "+$script.Name+": "+$parseErrors[0].Message)
    }
}
& (Join-Path $PSScriptRoot 'Verify-Source-Pins.ps1')
Write-Host ("Verified complete AOTC v0.10 runtime: "+$seen.Count+" SHA-256-pinned files.") -ForegroundColor Green
