param([string]$GamePath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'SG-GfsLibrary.ps1')
if(-not $GamePath){$GamePath=Read-Host 'Path to the Skullgirls installation'}
$game=[IO.Path]::GetFullPath($GamePath.Trim().Trim('"')).TrimEnd('\','/')
if(Get-Process -Name SkullGirls -ErrorAction SilentlyContinue){
    throw 'Close Skullgirls before validating derived archives.'
}
if(-not(Test-Path -LiteralPath (Join-Path $game 'SkullGirls.exe') -PathType Leaf)){
    throw 'SkullGirls.exe not found.'
}
$manifest=Get-Content -LiteralPath (Join-Path $root 'patches\egret-2023-combat-v1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if([string]$manifest.id -cne 'aotc-egret-65-v1' -or
   @($manifest.files).Count -ne 3 -or @($manifest.derivedEntries).Count -ne 2){
    throw 'Invalid Egret manifest.'
}
function Check-Entry([string]$Archive,[object]$Spec) {
    $idx=Get-SGIndex $Archive
    $key=[string]$Spec.entry
    if(-not $idx.ContainsKey($key)){throw "Missing GFS entry: $key"}
    $entry=$idx[$key]
    if([long]$entry.Size -ne [long]$Spec.bytes){throw "Unexpected GFS entry length: $key"}
    $s=[IO.File]::OpenRead($Archive)
    $h=[Security.Cryptography.SHA256]::Create()
    try {
        [void]$s.Seek([long]$entry.Offset,[IO.SeekOrigin]::Begin)
        [byte[]]$block=[byte[]]::new(1048576)
        [long]$left=[long]$entry.Size
        while($left -gt 0){
            $n=$s.Read($block,0,[int][Math]::Min($left,[long]$block.Length))
            if($n -le 0){throw "Truncated GFS data: $key"}
            [void]$h.TransformBlock($block,0,$n,$block,0)
            $left-=$n
        }
        [void]$h.TransformFinalBlock([byte[]]::new(0),0,0)
        $actual=([BitConverter]::ToString($h.Hash)).Replace('-','').ToLowerInvariant()
        if($actual -cne ([string]$Spec.sha256).ToLowerInvariant()){
            throw "Wrong GFS checksum: $Archive -> $key"
        }
    }finally{$h.Dispose();$s.Dispose()}
}
foreach($asset in @($manifest.files)){
    $installed=Join-Path $game ([string]$asset.target).Replace('/','\')
    $sha=([string]$asset.sha256).ToLowerInvariant()
    if(-not(Test-Path -LiteralPath $installed -PathType Leaf) -or
       (Get-Item -LiteralPath $installed).Length -ne [long]$asset.bytes -or
       (Get-SGHash $installed) -cne $sha){
        throw "Egret production mod missing/mismatched: $installed"
    }
}
$backups=Join-Path $game 'Restoration Backups'
$valid=0
foreach($dir in @(Get-ChildItem -LiteralPath $backups -Directory -Filter 'AOTC-Egret-Production-*' -ErrorAction Stop)){
    $p=Join-Path $dir.FullName 'installed-files.json'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf) -or
       (Test-Path -LiteralPath (Join-Path $dir.FullName 'UNINSTALLED.txt'))){continue}
    $parsed=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $p -Raw -Encoding UTF8)
    $rows=@($parsed | ForEach-Object { $_ })
    if($rows.Count -ne 3){
        Write-Warning ("Egret ledger {0}: expected 3 entries, got {1}." -f $dir.Name,$rows.Count)
        continue
    }
    $right=$true
    foreach($asset in @($manifest.files)){
        $target=Join-Path $game ([string]$asset.target).Replace('/','\')
        if(@($rows | Where-Object {
            ([string]$_.target) -ieq $target -and
            ([string]$_.sha256).ToLowerInvariant() -ceq ([string]$asset.sha256).ToLowerInvariant()
        }).Count -ne 1){$right=$false;break}
    }
    if($right){$valid++}
    else{Write-Warning ("Egret ledger {0}: entries do not match the pinned installation targets and SHA-256." -f $dir.Name)}
}
if($valid -ne 1){throw "Egret production ledger verification: expected one matching active record, found $valid. No game files were modified."}
foreach($pair in @(
    [pscustomobject]@{Folder='data01';Entries=@($manifest.modernEntries)},
    [pscustomobject]@{Folder='data02';Entries=@($manifest.derivedEntries)}
)){
    foreach($spec in $pair.Entries){
        $archive=Join-Path $game ($pair.Folder+'\'+[string]$spec.archive)
        if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){
            throw "Character GFS not generated: $archive"
        }
        Check-Entry $archive $spec
        Write-Host ("VERIFIED: "+$pair.Folder+" / "+[string]$spec.archive+" / "+[string]$spec.entry) -ForegroundColor Green
    }
}
Write-Host 'All 65-frame Egret production payload hashes, ledger, and data01/data02 GFS entries verified.' -ForegroundColor Green
Write-Host 'Visual checks are still required for animation appearance.'
